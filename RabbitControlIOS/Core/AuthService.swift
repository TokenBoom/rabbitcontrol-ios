import Foundation
import RabbitControlCore
import UIKit

/// 认证服务:对接 rabbitcontrol-server,管理登录会话与账号设备列表。
///
/// FFI 调用全部为阻塞式,一律经 `Task.detached` 在后台线程执行。
/// 会话持久化在 UserDefaults(后续应迁移 Keychain,标注 TODO)。
@Observable
final class AuthService {
    static let shared = AuthService()

    struct ServerTarget: Codable, Hashable {
        var host: String
        var useHTTPS: Bool
        /// TOFU 信任的 CA PEM(probe 时抓取);HTTPS 模式下校验用。
        var caCertPem: String?

        init(host: String, useHTTPS: Bool, caCertPem: String? = nil) {
            self.host = host
            self.useHTTPS = useHTTPS
            self.caCertPem = caCertPem
        }

        static let local = ServerTarget(host: "127.0.0.1", useHTTPS: false)
    }

    struct Session: Codable {
        var accessToken: String
        var refreshToken: String
        var email: String
        var displayName: String
        var serverHost: String
        var useHTTPS: Bool
    }

    /// 当前服务器配置;持久化于 UserDefaults,默认本机调试实例。
    var serverTarget: ServerTarget {
        didSet {
            if let data = try? JSONEncoder().encode(serverTarget) {
                UserDefaults.standard.set(data, forKey: "auth.serverTarget")
            }
        }
    }

    private(set) var session: Session?
    private(set) var devices: [AccountDevice] = []
    private(set) var devicesError: String?
    private var refreshTask: Task<Void, Never>?

    var isLoggedIn: Bool { session != nil }

    /// UI 测试注入模式:无真实服务端时,以 mock 会话与 mock 设备驱动界面回归。
    static let uiTestingMock = ProcessInfo.processInfo.arguments.contains("-uiTestingMockAuth")

    private init() {
        if let data = UserDefaults.standard.data(forKey: "auth.serverTarget"),
           let saved = try? JSONDecoder().decode(ServerTarget.self, from: data) {
            serverTarget = saved
        } else {
            serverTarget = .local
        }
        if Self.uiTestingMock {
            session = Session(
                accessToken: "mock", refreshToken: "mock",
                email: "uitest@example.com", displayName: "UI 测试",
                serverHost: "127.0.0.1", useHTTPS: false
            )
            devices = MockData.devices.map { device in
                AccountDevice(
                    deviceID: device.id, formattedID: device.id,
                    hostname: device.name, os: device.kind.rawValue,
                    alias: device.name, allowRemoteAssist: true,
                    disabled: false, online: device.online, inSession: false
                )
            }
            return
        }
        if let data = UserDefaults.standard.data(forKey: "auth.session"),
           let saved = try? JSONDecoder().decode(Session.self, from: data) {
            session = saved
        }
    }

    // MARK: - 登录 / 注册

    /// 登录(同步绑定本机设备)。失败抛出服务器返回的错误文案。
    func login(email: String, password: String) async throws {
        try await authCall(isRegister: false, email: email, password: password)
        bridgeRuntimeLogin(email: email, password: password)
    }

    func register(email: String, password: String) async throws {
        try await authCall(isRegister: true, email: email, password: password)
        bridgeRuntimeLogin(email: email, password: password)
    }

    /// 登录成功后把同一凭据喂给 runtime 会话体系(信令/免密连接依赖它)。
    private func bridgeRuntimeLogin(email: String, password: String) {
        Task.detached {
            await RuntimeService.shared.login(email: email, password: password)
        }
    }

    private func authCall(
        isRegister: Bool,
        email: String,
        password: String
    ) async throws {
        var payload = serverPayload()
        payload["email"] = email
        payload["password"] = password
        payload["hostname"] = UIDevice.current.name
        payload["os"] = "ios"
        let json = String(data: try JSONSerialization.data(withJSONObject: payload), encoding: .utf8)!
        let raw = await Task.detached(priority: .userInitiated) {
            Self.withRustString(json.withCString {
                isRegister ? rc_auth_register($0) : rc_auth_login($0)
            })
        }.value
        guard let raw else { throw AuthError.noResponse }
        guard let data = raw.data(using: .utf8),
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AuthError.badResponse
        }
        if let error = obj["error"] as? String {
            throw AuthError.server(error)
        }
        guard let access = obj["access_token"] as? String,
              let refresh = obj["refresh_token"] as? String else {
            throw AuthError.badResponse
        }
        let displayName = (obj["user"] as? [String: Any])?["display_name"] as? String ?? ""
        let newSession = Session(
            accessToken: access,
            refreshToken: refresh,
            email: email,
            displayName: displayName,
            serverHost: serverTarget.host,
            useHTTPS: serverTarget.useHTTPS
        )
        await MainActor.run {
            session = newSession
            persist()
        }
        await refreshDevices()
    }

    func logout() {
        RuntimeService.shared.logout()
        session = nil
        devices = []
        UserDefaults.standard.removeObject(forKey: "auth.session")
    }

    // MARK: - 设备列表

    func refreshDevices() async {
        if Self.uiTestingMock { return }
        guard let session else { return }
        var payload = serverPayload()
        payload["access_token"] = session.accessToken
        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: jsonData, encoding: .utf8) else { return }
        let raw = await Task.detached(priority: .userInitiated) {
            Self.withRustString(json.withCString { rc_auth_list_devices($0) })
        }.value
        guard let raw, let data = raw.data(using: .utf8) else { return }

        if let arr = try? JSONDecoder().decode([AccountDevice].self, from: data) {
            await MainActor.run {
                devices = arr
                devicesError = nil
            }
        } else if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let error = obj["error"] as? String {
            if error.contains("token_expired"), await refreshTokens() {
                await refreshDevices()
            } else {
                await MainActor.run { devicesError = error }
            }
        }
    }

    /// 用 refresh token 轮换访问令牌,成功返回 true 并持久化新会话。
    @discardableResult
    private func refreshTokens() async -> Bool {
        guard let session else { return false }
        var payload = serverPayload()
        payload["refresh_token"] = session.refreshToken
        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: jsonData, encoding: .utf8) else { return false }
        let raw = await Task.detached(priority: .userInitiated) {
            Self.withRustString(json.withCString { rc_auth_refresh($0) })
        }.value
        guard let raw, let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = obj["access_token"] as? String,
              let refresh = obj["refresh_token"] as? String else { return false }
        var updated = session
        updated.accessToken = access
        updated.refreshToken = refresh
        self.session = updated
        persist()
        return true
    }

    func startAutoRefresh() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshDevices()
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    // MARK: - 内部

    private func persist() {
        if let session, let data = try? JSONEncoder().encode(session) {
            UserDefaults.standard.set(data, forKey: "auth.session")
        }
    }

    nonisolated private static func withRustString(_ ptr: UnsafeMutablePointer<CChar>?) -> String? {
        guard let ptr else { return nil }
        defer { rc_string_free(ptr) }
        return String(cString: ptr)
    }

    /// 通用 FFI JSON 调用(后台线程),返回原始响应字符串。
    private func callFFI(
        _ function: String,
        _ payload: [String: Any]
    ) async -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return await Task.detached(priority: .userInitiated) {
            Self.withRustString(json.withCString { ptr -> UnsafeMutablePointer<CChar>? in
                switch function {
                case "probe": rc_server_probe(ptr)
                case "change_password": rc_auth_change_password(ptr)
                case "rename": rc_auth_rename_device(ptr)
                case "remove": rc_auth_remove_device(ptr)
                default: nil
                }
            })
        }.value
    }

    private func serverPayload() -> [String: Any] {
        var p: [String: Any] = ["server_host": serverTarget.host, "use_https": serverTarget.useHTTPS]
        if let ca = serverTarget.caCertPem { p["ca_cert_pem"] = ca }
        return p
    }

    private static func errorMessage(in raw: String?) -> String? {
        guard let raw, let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = obj["error"] as? String else { return nil }
        return error
    }

    /// 探测服务器连通性,返回耗时毫秒或错误。
    func probeServer() async -> Result<Int, AuthError> {
        let raw = await callFFI("probe", serverPayload())
        if let error = Self.errorMessage(in: raw) { return .failure(.server(error)) }
        guard let raw, let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let latency = obj["latency_ms"] as? Int else {
            return .failure(.noResponse)
        }
        // TOFU:抓取服务端 CA 供后续 HTTPS/信令 TLS 校验
        if let bundle = obj["ca_bundle"] as? [String: Any],
           let pem = bundle["ca_cert_pem"] as? String {
            serverTarget.caCertPem = pem
        }
        return .success(latency)
    }

    /// 修改密码;成功后用新令牌更新会话。
    func changePassword(current: String, new: String) async throws {
        guard let session else { throw AuthError.notLoggedIn }
        var payload = serverPayload()
        payload["access_token"] = session.accessToken
        payload["current_password"] = current
        payload["new_password"] = new
        let raw = await callFFI("change_password", payload)
        if let error = Self.errorMessage(in: raw) { throw AuthError.server(error) }
        guard let raw, let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = obj["access_token"] as? String,
              let refresh = obj["refresh_token"] as? String else {
            throw AuthError.badResponse
        }
        var updated = session
        updated.accessToken = access
        updated.refreshToken = refresh
        self.session = updated
        persist()
    }

    /// 重命名设备别名。
    func renameDevice(deviceID: String, alias: String) async throws {
        guard let session else { throw AuthError.notLoggedIn }
        var payload = serverPayload()
        payload["access_token"] = session.accessToken
        payload["device_id"] = deviceID
        payload["alias"] = alias
        let raw = await callFFI("rename", payload)
        if let error = Self.errorMessage(in: raw) { throw AuthError.server(error) }
        await refreshDevices()
    }

    /// 解绑并移除设备。
    func removeDevice(deviceID: String) async throws {
        guard let session else { throw AuthError.notLoggedIn }
        var payload = serverPayload()
        payload["access_token"] = session.accessToken
        payload["device_id"] = deviceID
        let raw = await callFFI("remove", payload)
        if let error = Self.errorMessage(in: raw) { throw AuthError.server(error) }
        await refreshDevices()
    }

    enum AuthError: LocalizedError {
        case notLoggedIn
    case noResponse
        case badResponse
        case server(String)

        var errorDescription: String? {
            switch self {
            case .notLoggedIn: "未登录"
            case .noResponse: "核心库无响应"
            case .badResponse: "响应格式错误"
            case .server(let message): message
            }
        }
    }
}

/// 账号设备,字段与 core `MyDeviceInfo` 一致。
struct AccountDevice: Codable, Identifiable, Hashable {
    let deviceID: String
    let formattedID: String
    let hostname: String
    let os: String
    let alias: String
    let allowRemoteAssist: Bool
    let disabled: Bool
    let online: Bool
    let inSession: Bool

    var id: String { deviceID }

    /// 展示名:别名优先,其次主机名。
    var displayName: String {
        if !alias.isEmpty { return alias }
        if !hostname.isEmpty { return hostname }
        return formattedID
    }

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case formattedID = "formatted_id"
        case hostname
        case os
        case alias
        case allowRemoteAssist = "allow_remote_assist"
        case disabled
        case online
        case inSession = "in_session"
    }
}
