import Foundation
import RabbitControlCore
import UIKit

/// 认证服务:对接 rabbitcontrol-server,管理登录会话与账号设备列表。
///
/// FFI 调用全部为阻塞式,一律经 `Task.detached` 在后台线程执行。
/// UI 登录令牌仅写入本机钥匙串。
@Observable
final class AuthService {
    static let shared = AuthService()

    struct ServerTarget: Codable, Hashable {
        var host: String
        var useHTTPS: Bool
        /// TOFU 信任的 CA PEM(probe 时抓取);HTTPS 模式下校验用。
        var caCertPem: String?
        var apiPort: UInt16?
        var effectiveAPIPort: UInt16 { apiPort ?? 21118 }
        var payload: [String: Any] {
            var data: [String: Any] = ["server_host": host, "api_port": effectiveAPIPort, "use_https": useHTTPS]
            data["ca_cert_pem"] = caCertPem
            return data
        }

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
        var userID: String?
        var expiresAt: TimeInterval?
        var mustChangePassword: Bool?
        var apiPort: UInt16?
        func matches(_ target: ServerTarget) -> Bool {
            serverHost == target.host && useHTTPS == target.useHTTPS && (apiPort ?? 21118) == target.effectiveAPIPort
        }
    }

    struct SavedServer: Codable, Hashable, Identifiable {
        var target: ServerTarget
        var email: String?
        var id: String { "\(target.host):\(target.effectiveAPIPort):\(target.useHTTPS)" }
    }

    /// 当前服务器配置;持久化于 UserDefaults,默认本机调试实例。
    var serverTarget: ServerTarget {
        didSet {
            if let data = try? JSONEncoder().encode(serverTarget) {
                UserDefaults.standard.set(data, forKey: "auth.serverTarget")
            }
        }
    }

    /// 已保存的常用服务器(含各自最近登录邮箱),UserDefaults 持久化。
    private(set) var savedServers: [SavedServer] = []

    func rememberServer(_ target: ServerTarget, email: String? = nil) {
        var list = savedServers
        let entry = SavedServer(target: target, email: email ?? list.first(where: { $0.target == target })?.email)
        list.removeAll { $0.target == target }
        list.insert(entry, at: 0)
        savedServers = Array(list.prefix(8))
        persistServers()
    }

    func removeSavedServer(_ server: SavedServer) {
        savedServers.removeAll { $0 == server }
        persistServers()
    }

    /// 切换到已保存服务器;若已登录且不属于该服务器则登出。
    func switchToServer(_ server: SavedServer) {
        guard server.target != serverTarget else { return }
        if isLoggedIn { logout() }
        serverTarget = server.target
    }

    /// 当前服务器最近登录的邮箱,用于登录页预填。
    var rememberedEmail: String? {
        savedServers.first(where: { $0.target == serverTarget })?.email
    }

    private func persistServers() {
        if let data = try? JSONEncoder().encode(savedServers) {
            UserDefaults.standard.set(data, forKey: "auth.savedServers")
        }
    }

    private(set) var session: Session?
    private(set) var devices: [AccountDevice] = []
    private(set) var devicesError: String?
    private(set) var loadingDevices = false
    private var refreshRequest: UUID?
    private var refreshTask: Task<Void, Never>?
    private let keychain = SessionKeychain()
    private(set) var previews: [String: UIImage] = [:]

    func rememberPreview(_ image: UIImage, deviceID: String) {
        guard session != nil, devices.contains(where: { $0.id == deviceID }) else { return }
        previews[deviceID] = image
    }

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
        if let data = UserDefaults.standard.data(forKey: "auth.savedServers"),
           let list = try? JSONDecoder().decode([SavedServer].self, from: data) {
            savedServers = list
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
        let defaults = UserDefaults.standard
        do {
            var data = try keychain.load()
            if data == nil, let old = defaults.data(forKey: "auth.session") {
                _ = try JSONDecoder().decode(Session.self, from: old)
                try keychain.store(old)
                data = old
            }
            defaults.removeObject(forKey: "auth.session")
            if let data {
                let saved = try JSONDecoder().decode(Session.self, from: data)
                if saved.matches(serverTarget) { session = saved }
            }
        } catch {
            devicesError = "无法读取钥匙串，请解锁设备后重试。"
        }
    }

    // MARK: - 登录 / 注册

    /// 登录(同步绑定本机设备)。失败抛出服务器返回的错误文案。
    func login(email: String, password: String) async throws {
        try await authCall(isRegister: false, email: email, password: password)
    }

    func register(email: String, password: String) async throws {
        try await authCall(isRegister: true, email: email, password: password)
    }

    private func authCall(
        isRegister: Bool,
        email: String,
        password: String
    ) async throws {
        // 先探测:TLS 服务端对明文连接会直接断开,probe 内会自动升级 HTTPS 并锚定 CA
        let requested = serverTarget
        let probe = await probeServer(requested)
        guard serverTarget == requested else { throw AuthError.server("服务器设置已更改，请重新登录。") }
        serverTarget = try probe.get().target
        let loginTarget = serverTarget
        var payload = serverTarget.payload
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
        guard loginTarget == serverTarget else { throw AuthError.server("服务器设置已更改，请重新登录。") }
        let user = obj["user"] as? [String: Any]
        guard let userID = user?["id"] as? String else { throw AuthError.badResponse }
        let displayName = user?["display_name"] as? String ?? ""
        let newSession = Session(
            accessToken: access,
            refreshToken: refresh,
            email: email,
            displayName: displayName,
            serverHost: serverTarget.host,
            useHTTPS: serverTarget.useHTTPS,
            userID: userID, expiresAt: Self.expiry(in: obj),
            mustChangePassword: user?["must_change_password"] as? Bool, apiPort: loginTarget.effectiveAPIPort
        )
        try keychain.store(JSONEncoder().encode(newSession))
        previews.removeAll()
        session = newSession
        rememberServer(serverTarget, email: email)
        RuntimeService.shared.sync(newSession, target: loginTarget, rebuild: true)
        await refreshDevices()
    }

    func logout() {
        if !Self.uiTestingMock, let session, session.matches(serverTarget) {
            var payload = serverTarget.payload
            payload["access_token"] = session.accessToken
            payload["refresh_token"] = session.refreshToken
            if let json = RuntimeService.jsonString(payload) {
                Task.detached(priority: .utility) { _ = RuntimeService.callSyncJSON(json, rc_auth_logout) }
            }
        }
        SessionService.shared.close()
        refreshTask?.cancel()
        refreshTask = nil
        refreshRequest = nil
        loadingDevices = false
        RuntimeService.shared.logout()
        session = nil
        devices = []
        previews.removeAll()
        devicesError = nil
        UserDefaults.standard.removeObject(forKey: "auth.session")
        do { try keychain.remove() } catch { devicesError = "未能清除钥匙串，请解锁设备后重试。" }
    }

    // MARK: - 设备列表

    func refreshDevices() async {
        guard !Self.uiTestingMock, !loadingDevices, session != nil else { return }
        let request = UUID()
        refreshRequest = request
        loadingDevices = true
        defer { if refreshRequest == request { loadingDevices = false; refreshRequest = nil } }
        if let session, (session.expiresAt ?? 0) < Date.now.timeIntervalSince1970 + 210 {
            guard await refreshTokens() else { devicesError = "登录状态无法刷新，请检查网络或重新登录。"; return }
        }
        await loadDevices(canRefreshToken: true)
    }

    private func loadDevices(canRefreshToken: Bool) async {
        guard let session else { return }
        var payload = serverTarget.payload
        payload["access_token"] = session.accessToken
        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: jsonData, encoding: .utf8) else { return }
        let raw = await Task.detached(priority: .userInitiated) {
            Self.withRustString(json.withCString { rc_auth_list_devices($0) })
        }.value
        guard self.session?.accessToken == session.accessToken else { return }
        guard let raw, let data = raw.data(using: .utf8) else { devicesError = "服务器无响应"; return }

        if let arr = try? JSONDecoder().decode([AccountDevice].self, from: data) {
            devices = arr
            let ids = Set(arr.map(\.id))
            previews = previews.filter { ids.contains($0.key) }
            devicesError = nil
        } else if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let error = obj["error"] as? String {
            if canRefreshToken, error.contains("token_expired"), await refreshTokens() {
                await loadDevices(canRefreshToken: false)
            } else if self.session?.accessToken == session.accessToken {
                devicesError = error
            }
        } else { devicesError = "设备列表格式错误" }
    }

    /// 用 refresh token 轮换访问令牌,成功返回 true 并持久化新会话。
    @discardableResult
    func refreshTokens() async -> Bool {
        guard let session else { return false }
        var payload = serverTarget.payload
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
        guard self.session?.refreshToken == session.refreshToken else { return false }
        var updated = session
        updated.accessToken = access
        updated.refreshToken = refresh
        updated.expiresAt = Self.expiry(in: obj)
        let user = obj["user"] as? [String: Any]
        updated.userID = user?["id"] as? String ?? updated.userID
        updated.mustChangePassword = user?["must_change_password"] as? Bool ?? updated.mustChangePassword
        do { try keychain.store(JSONEncoder().encode(updated)) } catch { return false }
        self.session = updated
        RuntimeService.shared.sync(updated, target: serverTarget)
        return true
    }

    private static func expiry(in response: [String: Any]) -> TimeInterval {
        Date.now.timeIntervalSince1970 + ((response["expires_in_sec"] as? NSNumber)?.doubleValue ?? 0)
    }

    func startAutoRefresh() {
        guard !Self.uiTestingMock, isLoggedIn, refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshDevices()
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    // MARK: - 内部

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

    private static func errorMessage(in raw: String?) -> String? {
        guard let raw, let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = obj["error"] as? String else { return nil }
        return error
    }

    /// 探测服务器连通性,返回耗时毫秒或错误。
    /// 明文探测失败时自动升级 HTTPS 重试(TLS 服务端会直接断开明文连接)。
    func probeServer(_ candidate: ServerTarget) async -> Result<(target: ServerTarget, latency: Int), AuthError> {
        var target = candidate
        var raw = await callFFI("probe", target.payload)
        if Self.errorMessage(in: raw) != nil, !target.useHTTPS {
            var upgraded = target
            upgraded.useHTTPS = true
            let retry = await callFFI("probe", upgraded.payload)
            if retry != nil, Self.errorMessage(in: retry) == nil {
                target = upgraded
                raw = retry
            }
        }
        if let error = Self.errorMessage(in: raw) { return .failure(.server(error)) }
        guard let raw, let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let latency = obj["latency_ms"] as? Int else {
            return .failure(.noResponse)
        }
        // TOFU:抓取服务端 CA 供后续 HTTPS/信令 TLS 校验
        if let bundle = obj["ca_bundle"] as? [String: Any],
           let pem = bundle["ca_cert_pem"] as? String {
            if let known = candidate.caCertPem, known != pem {
                return .failure(.server("服务器 CA 已更换，未继续登录。请先核实新证书。"))
            }
            target.caCertPem = pem
        }
        return .success((target, latency))
    }

    /// 修改密码;成功后用新令牌更新会话。
    func changePassword(current: String, new: String) async throws {
        guard let session else { throw AuthError.notLoggedIn }
        var payload = serverTarget.payload
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
        updated.expiresAt = Self.expiry(in: obj)
        updated.mustChangePassword = false
        guard self.session?.refreshToken == session.refreshToken else { throw AuthError.notLoggedIn }
        try keychain.store(JSONEncoder().encode(updated))
        self.session = updated
        RuntimeService.shared.sync(updated, target: serverTarget)
    }

    /// 重命名设备别名。
    func renameDevice(deviceID: String, alias: String) async throws {
        guard let session else { throw AuthError.notLoggedIn }
        var payload = serverTarget.payload
        payload["access_token"] = session.accessToken
        payload["device_id"] = deviceID
        payload["alias"] = alias
        let raw = await callFFI("rename", payload)
        guard let raw else { throw AuthError.noResponse }
        if let error = Self.errorMessage(in: raw) { throw AuthError.server(error) }
        await refreshDevices()
    }

    /// 解绑并移除设备。
    func removeDevice(deviceID: String) async throws {
        guard let session else { throw AuthError.notLoggedIn }
        var payload = serverTarget.payload
        payload["access_token"] = session.accessToken
        payload["device_id"] = deviceID
        let raw = await callFFI("remove", payload)
        guard let raw else { throw AuthError.noResponse }
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
