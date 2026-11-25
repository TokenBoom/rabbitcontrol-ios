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

    private(set) var session: Session?
    private(set) var devices: [AccountDevice] = []
    private(set) var devicesError: String?
    private var refreshTask: Task<Void, Never>?

    var isLoggedIn: Bool { session != nil }

    /// UI 测试注入模式:无真实服务端时,以 mock 会话与 mock 设备驱动界面回归。
    static let uiTestingMock = ProcessInfo.processInfo.arguments.contains("-uiTestingMockAuth")

    private init() {
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
    }

    func register(email: String, password: String) async throws {
        try await authCall(isRegister: true, email: email, password: password)
    }

    private func authCall(
        isRegister: Bool,
        email: String,
        password: String
    ) async throws {
        let target = ServerTarget.local
        let payload: [String: Any] = [
            "server_host": target.host,
            "use_https": target.useHTTPS,
            "email": email,
            "password": password,
            "hostname": UIDevice.current.name,
            "os": "ios",
        ]
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
            serverHost: target.host,
            useHTTPS: target.useHTTPS
        )
        await MainActor.run {
            session = newSession
            persist()
        }
        await refreshDevices()
    }

    func logout() {
        session = nil
        devices = []
        UserDefaults.standard.removeObject(forKey: "auth.session")
    }

    // MARK: - 设备列表

    func refreshDevices() async {
        if Self.uiTestingMock { return }
        guard let session else { return }
        let payload: [String: Any] = [
            "server_host": session.serverHost,
            "use_https": session.useHTTPS,
            "access_token": session.accessToken,
        ]
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
            await MainActor.run { devicesError = error }
        }
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

    enum AuthError: LocalizedError {
        case noResponse
        case badResponse
        case server(String)

        var errorDescription: String? {
            switch self {
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
