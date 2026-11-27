import Foundation
import RabbitControlCore
import UIKit

/// 认证服务:对接 rabbitcontrol-server,管理登录会话与账号设备列表。
///
/// FFI 调用全部为阻塞式,一律经 `Task.detached` 在后台线程执行。
/// UI 登录令牌仅写入本机钥匙串；错误统一优先解码 `rc-mobile-ffi` 返回的 `ui_error`。
@Observable
final class AuthService {
    static let shared = AuthService()

    struct ServerTarget: Codable, Hashable {
        var host: String
        var useHTTPS: Bool
        /// TOFU 信任的 CA PEM(probe 时抓取);HTTPS 模式下校验用。
        var caCertPem: String?
        var caFingerprintSha256: String?
        var apiPort: UInt16?
        var signalPort: UInt16?
        var relayPort: UInt16?
        var effectiveAPIPort: UInt16 { apiPort ?? 21118 }
        var effectiveSignalPort: UInt16 { signalPort ?? 21116 }
        var effectiveRelayPort: UInt16 { relayPort ?? 21117 }
        var serverKey: String { "\(host):\(effectiveAPIPort):\(useHTTPS)" }
        var payload: [String: Any] {
            var data: [String: Any] = ["server_host": host, "api_port": effectiveAPIPort, "use_https": useHTTPS]
            data["ca_cert_pem"] = caCertPem
            return data
        }
        var runtimePayload: [String: Any] {
            var data = payload
            data["signal_port"] = effectiveSignalPort
            data["relay_port"] = effectiveRelayPort
            if let caFingerprintSha256, !caFingerprintSha256.isEmpty {
                data["ca_fingerprint_sha256"] = caFingerprintSha256
            }
            return data
        }

        init(
            host: String,
            useHTTPS: Bool,
            caCertPem: String? = nil,
            caFingerprintSha256: String? = nil,
            apiPort: UInt16? = nil,
            signalPort: UInt16? = nil,
            relayPort: UInt16? = nil
        ) {
            self.host = host
            self.useHTTPS = useHTTPS
            self.caCertPem = caCertPem
            self.caFingerprintSha256 = caFingerprintSha256
            self.apiPort = apiPort
            self.signalPort = signalPort
            self.relayPort = relayPort
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
        var name: String?
        var target: ServerTarget
        var email: String?
        var id: String { "\(target.host):\(target.effectiveAPIPort):\(target.useHTTPS)" }
        var displayName: String {
            let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? target.host : trimmed
        }
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

    func rememberServer(_ target: ServerTarget, email: String? = nil, name: String? = nil) {
        var list = savedServers
        let existing = list.first(where: { $0.target == target })
        let entry = SavedServer(
            name: name ?? existing?.name,
            target: target,
            email: email ?? existing?.email
        )
        list.removeAll { $0.target == target }
        list.insert(entry, at: 0)
        savedServers = Array(list.prefix(12))
        persistServers()
    }

    func saveServer(name: String?, target: ServerTarget, replacing old: SavedServer? = nil) {
        var list = savedServers
        let existingEmail = old?.email ?? list.first(where: { $0.target == target })?.email
        if let old { list.removeAll { $0.id == old.id } }
        list.removeAll { $0.target == target }
        let cleanName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let entry = SavedServer(name: (cleanName?.isEmpty == false) ? cleanName : nil, target: target, email: existingEmail)
        list.insert(entry, at: 0)
        savedServers = Array(list.prefix(12))
        persistServers()
        if let old, old.target == serverTarget, !isLoggedIn {
            serverTarget = target
        }
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
    private(set) var devicesUiError: RCUiError?
    /// 各服务器最近探测到的 `allow_registration` 开关（未探测时默认 `true` 不误伤首次展示）。
    private(set) var allowRegistrationByServer: [String: Bool] = [:]
    var devicesError: String? {
        devicesUiError.map { $0.message.isEmpty ? $0.title : $0.message }
    }
    private(set) var loadingDevices = false
    private var refreshRequest: UUID?
    private var refreshTask: Task<Void, Never>?
    private var inFlightTokenRefresh: Task<Bool, Never>?
    private let keychain = SessionKeychain()
    private(set) var previews: [String: UIImage] = [:]

    func rememberPreview(_ image: UIImage, deviceID: String) {
        guard session != nil, devices.contains(where: { $0.id == deviceID }) else { return }
        previews[deviceID] = image
    }

    var isLoggedIn: Bool { session != nil }
    /// 首次登录强制改密门禁：为 `true` 时阻塞进入主界面与发起连接。
    var requiresPasswordChange: Bool { session?.mustChangePassword == true }

    func isRegistrationAllowed(for target: ServerTarget? = nil) -> Bool {
        let key = (target ?? serverTarget).serverKey
        return allowRegistrationByServer[key] ?? true
    }

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
                    allowRemoteControl: true,
                    disabled: false, online: device.online, inSession: false,
                    wolCapable: !device.online && device.id == "gaming"
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
            devicesUiError = RCUiErrorCodec.fromError(error, fallbackCode: RCErrorCodes.platformIosKeychainError)
        }
    }

    // MARK: - 登录 / 注册

    /// 登录(同步绑定本机设备)。失败抛出携带 `RCUiError` 的 `AuthError`。
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
        guard serverTarget == requested else {
            throw AuthError.structured(CoreClient.resolveUiError(code: RCErrorCodes.authSuperseded))
        }
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
        if let uiErr = RCUiErrorCodec.extractEnvelopeError(from: obj) {
            throw AuthError.structured(uiErr)
        }
        guard let access = obj["access_token"] as? String,
              let refresh = obj["refresh_token"] as? String else {
            throw AuthError.badResponse
        }
        guard loginTarget == serverTarget else {
            throw AuthError.structured(CoreClient.resolveUiError(code: RCErrorCodes.authSuperseded))
        }
        let user = obj["user"] as? [String: Any]
        guard let userID = user?["id"] as? String else { throw AuthError.badResponse }
        let displayName = user?["display_name"] as? String ?? ""
        let mustChangePwd = user?["must_change_password"] as? Bool
        let newSession = Session(
            accessToken: access,
            refreshToken: refresh,
            email: email,
            displayName: displayName,
            serverHost: serverTarget.host,
            useHTTPS: serverTarget.useHTTPS,
            userID: userID, expiresAt: Self.expiry(in: obj),
            mustChangePassword: mustChangePwd, apiPort: loginTarget.effectiveAPIPort
        )
        do {
            try keychain.store(JSONEncoder().encode(newSession))
        } catch {
            throw AuthError.structured(RCUiErrorCodec.fromError(error, fallbackCode: RCErrorCodes.platformIosKeychainError))
        }
        previews.removeAll()
        session = newSession
        rememberServer(serverTarget, email: email)
        if mustChangePwd != true {
            RuntimeService.shared.sync(newSession, target: loginTarget, rebuild: true)
            await refreshDevices()
        }
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
        inFlightTokenRefresh?.cancel()
        inFlightTokenRefresh = nil
        refreshRequest = nil
        loadingDevices = false
        RuntimeService.shared.logout()
        AppLockStore.shared.resetOnLogout()
        session = nil
        devices = []
        previews.removeAll()
        devicesUiError = nil
        UserDefaults.standard.removeObject(forKey: "auth.session")
        do {
            try keychain.remove()
        } catch {
            devicesUiError = RCUiErrorCodec.fromError(error, fallbackCode: RCErrorCodes.platformIosKeychainError)
        }
    }

    // MARK: - 设备列表

    func refreshDevices() async {
        guard !Self.uiTestingMock, !loadingDevices, session != nil else { return }
        let request = UUID()
        refreshRequest = request
        loadingDevices = true
        defer { if refreshRequest == request { loadingDevices = false; refreshRequest = nil } }
        if let session, (session.expiresAt ?? 0) < Date.now.timeIntervalSince1970 + 210 {
            guard await refreshTokens() else {
                if devicesUiError == nil {
                    devicesUiError = CoreClient.resolveUiError(code: RCErrorCodes.authReloginRequired)
                }
                return
            }
        }
        await loadDevices(canRefreshToken: true)
        RuntimeService.shared.refreshSignalMetadata()
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
        guard let raw, let data = raw.data(using: .utf8) else {
            devicesUiError = CoreClient.resolveUiError(code: RCErrorCodes.networkUnreachable)
            return
        }

        if let arr = try? JSONDecoder().decode([AccountDevice].self, from: data) {
            devices = arr
            let ids = Set(arr.map(\.id))
            previews = previews.filter { ids.contains($0.key) }
            devicesUiError = nil
        } else if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let uiErr = RCUiErrorCodec.extractEnvelopeError(from: obj) {
            let isExpiredToken = uiErr.code == RCErrorCodes.authTokenExpired || uiErr.code == RCErrorCodes.authUnauthorized
            if canRefreshToken, isExpiredToken, await refreshTokens() {
                await loadDevices(canRefreshToken: false)
            } else if self.session?.accessToken == session.accessToken {
                devicesUiError = uiErr
                if uiErr.presentation == .modal {
                    RCErrorCenter.shared.present(uiErr)
                }
            }
        } else {
            devicesUiError = CoreClient.resolveUiError(code: RCErrorCodes.validationInvalidJson, detail: "设备列表格式错误")
        }
    }

    /// 用 refresh token 轮换访问令牌（单飞互斥合并并发调用，防止重放吊销整族会话）。
    @discardableResult
    func refreshTokens() async -> Bool {
        if let existing = inFlightTokenRefresh {
            return await existing.value
        }
        let task = Task<Bool, Never> { @MainActor [weak self] in
            guard let self else { return false }
            defer { self.inFlightTokenRefresh = nil }
            return await self.performTokenRefreshLocked()
        }
        inFlightTokenRefresh = task
        return await task.value
    }

    private func performTokenRefreshLocked() async -> Bool {
        guard let session else { return false }
        var payload = serverTarget.payload
        payload["refresh_token"] = session.refreshToken
        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: jsonData, encoding: .utf8) else { return false }
        let raw = await Task.detached(priority: .userInitiated) {
            Self.withRustString(json.withCString { rc_auth_refresh($0) })
        }.value
        guard let raw, let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        if let uiErr = RCUiErrorCodec.extractEnvelopeError(from: obj) {
            guard self.session?.refreshToken == session.refreshToken else { return false }
            devicesUiError = uiErr
            if uiErr.presentation == .modal {
                RCErrorCenter.shared.present(uiErr)
            }
            return false
        }
        guard let access = obj["access_token"] as? String,
              let refresh = obj["refresh_token"] as? String else { return false }
        guard self.session?.refreshToken == session.refreshToken else { return false }
        var updated = session
        updated.accessToken = access
        updated.refreshToken = refresh
        updated.expiresAt = Self.expiry(in: obj)
        let user = obj["user"] as? [String: Any]
        updated.userID = user?["id"] as? String ?? updated.userID
        updated.mustChangePassword = user?["must_change_password"] as? Bool ?? updated.mustChangePassword
        do {
            try keychain.store(JSONEncoder().encode(updated))
        } catch {
            devicesUiError = RCUiErrorCodec.fromError(error, fallbackCode: RCErrorCodes.platformIosKeychainError)
            return false
        }
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
        CoreClient.withRustString(ptr)
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

    private static func envelopeUiError(in raw: String?) -> RCUiError? {
        RCUiErrorCodec.extractEnvelopeError(fromRawJSON: raw)
    }

    /// 探测服务器连通性,返回耗时毫秒或结构化错误。
    /// 明文探测失败时自动升级 HTTPS 重试(TLS 服务端会直接断开明文连接)。
    func probeServer(_ candidate: ServerTarget) async -> Result<(target: ServerTarget, latency: Int), AuthError> {
        var target = candidate
        var raw = await callFFI("probe", target.payload)
        if Self.envelopeUiError(in: raw) != nil, !target.useHTTPS {
            var upgraded = target
            upgraded.useHTTPS = true
            let retry = await callFFI("probe", upgraded.payload)
            if retry != nil, Self.envelopeUiError(in: retry) == nil {
                target = upgraded
                raw = retry
            }
        }
        if let uiErr = Self.envelopeUiError(in: raw) {
            return .failure(.structured(uiErr))
        }
        guard let raw, let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let latency = obj["latency_ms"] as? Int else {
            return .failure(.noResponse)
        }
        if let allowReg = obj["allow_registration"] as? Bool {
            allowRegistrationByServer[candidate.serverKey] = allowReg
            allowRegistrationByServer[target.serverKey] = allowReg
        }
        // TOFU:抓取服务端 CA 与指纹供后续 HTTPS/信令 TLS 校验
        if let bundle = obj["ca_bundle"] as? [String: Any],
           let pem = bundle["ca_cert_pem"] as? String {
            if let known = candidate.caCertPem, known != pem {
                return .failure(.structured(CoreClient.resolveUiError(code: RCErrorCodes.pkiCaFingerprintMismatch)))
            }
            target.caCertPem = pem
            if let fp = bundle["fingerprint_sha256"] as? String, !fp.isEmpty {
                target.caFingerprintSha256 = fp
            }
        }
        if target.caFingerprintSha256 == nil,
           let leafFp = obj["tls_leaf_fingerprint_sha256"] as? String, !leafFp.isEmpty {
            target.caFingerprintSha256 = leafFp
        }
        return .success((target, latency))
    }

    /// 修改密码;成功后用新令牌更新会话，若处于首次强制改密态则自动解锁并拉起运行时与设备列表。
    func changePassword(current: String, new: String) async throws {
        guard let session else { throw AuthError.notLoggedIn }
        let wasForceChange = session.mustChangePassword == true
        var payload = serverTarget.payload
        payload["access_token"] = session.accessToken
        payload["current_password"] = current
        payload["new_password"] = new
        let raw = await callFFI("change_password", payload)
        if let uiErr = Self.envelopeUiError(in: raw) { throw AuthError.structured(uiErr) }
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
        do {
            try keychain.store(JSONEncoder().encode(updated))
        } catch {
            throw AuthError.structured(RCUiErrorCodec.fromError(error, fallbackCode: RCErrorCodes.platformIosKeychainError))
        }
        self.session = updated
        RuntimeService.shared.sync(updated, target: serverTarget, rebuild: wasForceChange)
        if wasForceChange {
            await refreshDevices()
        }
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
        if let uiErr = Self.envelopeUiError(in: raw) { throw AuthError.structured(uiErr) }
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
        if let uiErr = Self.envelopeUiError(in: raw) { throw AuthError.structured(uiErr) }
        await refreshDevices()
    }

    nonisolated enum AuthError: LocalizedError, Equatable, Sendable {
        case notLoggedIn
        case noResponse
        case badResponse
        case server(String)
        case structured(RCUiError)

        var uiError: RCUiError {
            switch self {
            case .notLoggedIn:
                CoreClient.resolveUiError(code: RCErrorCodes.authUnauthorized)
            case .noResponse:
                CoreClient.resolveUiError(code: RCErrorCodes.serviceRuntimeNotInitialized, detail: "核心库无响应")
            case .badResponse:
                CoreClient.resolveUiError(code: RCErrorCodes.validationInvalidJson, detail: "响应格式错误")
            case .server(let message):
                CoreClient.resolveUiError(code: RCErrorCodes.commonUnknown, detail: message)
            case .structured(let err):
                err
            }
        }

        var errorDescription: String? {
            let ui = uiError
            let msg = ui.message.trimmingCharacters(in: .whitespacesAndNewlines)
            return msg.isEmpty ? ui.title : msg
        }

        var recoverySuggestion: String? {
            let sug = uiError.suggestion.trimmingCharacters(in: .whitespacesAndNewlines)
            return sug.isEmpty ? nil : sug
        }
    }
}

/// 账号设备,字段与 core `MyDeviceInfo` 一致。
struct AccountDevice: Codable, Identifiable, Hashable {
    let deviceID: String
    let formattedID: String
    let hostname: String
    let os: String
    let appVersion: String
    let arch: String
    let alias: String
    let allowRemoteAssist: Bool
    let allowRemoteControl: Bool
    let disabled: Bool
    let online: Bool
    let inSession: Bool
    let wolCapable: Bool
    let boundAt: String?
    let lastSeenAt: String?

    var id: String { deviceID }

    /// 基线 §3.1：设备离线时自动清除 `inSession` 占位状态。
    var effectiveInSession: Bool { online && inSession }

    /// 展示名:别名优先,其次主机名。
    var displayName: String {
        if !alias.isEmpty { return alias }
        if !hostname.isEmpty { return hostname }
        return formattedID
    }

    /// 基线 §3.1 `canShowInSidebar`：仅展示 `allowRemoteControl == true` 且非本机 iOS 的同账号受控设备。
    func canShowInSidebar(ownDeviceID: String?) -> Bool {
        guard allowRemoteControl else { return false }
        if os.lowercased() == "ios" { return false }
        if let own = ownDeviceID?.replacingOccurrences(of: " ", with: ""),
           !own.isEmpty,
           deviceID.replacingOccurrences(of: " ", with: "") == own {
            return false
        }
        return true
    }

    /// 基线 §3.1 稳定排序：在线置顶、离线沉底，组内按 `last_seen_at DESC, device_id ASC` 排序。
    nonisolated static func sortForSidebar(_ list: [AccountDevice]) -> [AccountDevice] {
        list.sorted { lhs, rhs in
            if lhs.online != rhs.online {
                return lhs.online && !rhs.online
            }
            let lSeen = lhs.lastSeenAt ?? ""
            let rSeen = rhs.lastSeenAt ?? ""
            if lSeen != rSeen {
                return lSeen > rSeen
            }
            return lhs.deviceID < rhs.deviceID
        }
    }

    init(
        deviceID: String,
        formattedID: String,
        hostname: String,
        os: String,
        appVersion: String = "",
        arch: String = "",
        alias: String,
        allowRemoteAssist: Bool,
        allowRemoteControl: Bool = true,
        disabled: Bool,
        online: Bool,
        inSession: Bool,
        wolCapable: Bool = false,
        boundAt: String? = nil,
        lastSeenAt: String? = nil
    ) {
        self.deviceID = deviceID
        self.formattedID = formattedID
        self.hostname = hostname
        self.os = os
        self.appVersion = appVersion
        self.arch = arch
        self.alias = alias
        self.allowRemoteAssist = allowRemoteAssist
        self.allowRemoteControl = allowRemoteControl
        self.disabled = disabled
        self.online = online
        self.inSession = inSession
        self.wolCapable = wolCapable
        self.boundAt = boundAt
        self.lastSeenAt = lastSeenAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        deviceID = try c.decode(String.self, forKey: .deviceID)
        formattedID = try c.decodeIfPresent(String.self, forKey: .formattedID) ?? deviceID
        hostname = try c.decodeIfPresent(String.self, forKey: .hostname) ?? ""
        os = try c.decodeIfPresent(String.self, forKey: .os) ?? ""
        appVersion = try c.decodeIfPresent(String.self, forKey: .appVersion) ?? ""
        arch = try c.decodeIfPresent(String.self, forKey: .arch) ?? ""
        alias = try c.decodeIfPresent(String.self, forKey: .alias) ?? ""
        allowRemoteAssist = try c.decodeIfPresent(Bool.self, forKey: .allowRemoteAssist) ?? false
        let fallbackControl = os.lowercased() != "ios" && os.lowercased() != "android"
        allowRemoteControl = try c.decodeIfPresent(Bool.self, forKey: .allowRemoteControl) ?? fallbackControl
        disabled = try c.decodeIfPresent(Bool.self, forKey: .disabled) ?? false
        online = try c.decodeIfPresent(Bool.self, forKey: .online) ?? false
        inSession = try c.decodeIfPresent(Bool.self, forKey: .inSession) ?? false
        wolCapable = try c.decodeIfPresent(Bool.self, forKey: .wolCapable) ?? false
        boundAt = try c.decodeIfPresent(String.self, forKey: .boundAt)
        lastSeenAt = try c.decodeIfPresent(String.self, forKey: .lastSeenAt)
    }

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case formattedID = "formatted_id"
        case hostname
        case os
        case appVersion = "app_version"
        case arch
        case alias
        case allowRemoteAssist = "allow_remote_assist"
        case allowRemoteControl = "allow_remote_control"
        case disabled
        case online
        case inSession = "in_session"
        case wolCapable = "wol_capable"
        case boundAt = "bound_at"
        case lastSeenAt = "last_seen_at"
    }
}
