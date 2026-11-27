import Foundation
import RabbitControlCore

/// 出站网络代理配置管理（对应 core #5 `ProxyConfig` 与 `rc_proxy_set_config_json`）。
///
/// 安全约束：
/// - `mode` / `protocol` / `host` / `port` / `username` 存 `UserDefaults`；
/// - 代理认证 `password` 仅存系统钥匙串（`SessionKeychain`），绝不写入 `UserDefaults` 或日志。
@Observable
final class ProxyConfigStore {
    static let shared = ProxyConfigStore()

    nonisolated enum Mode: String, CaseIterable, Codable, Identifiable, Sendable {
        case none = "none"
        case system = "system"
        case manual = "manual"

        var id: String { rawValue }

        var label: String {
            switch self {
            case .none: "直连（不使用代理）"
            case .system: "跟随系统代理"
            case .manual: "手动配置代理"
            }
        }

        var shortLabel: String {
            switch self {
            case .none: "直连"
            case .system: "系统代理"
            case .manual: "手动代理"
            }
        }
    }

    nonisolated enum ProxyProtocol: String, CaseIterable, Codable, Identifiable, Sendable {
        case http = "http"
        case socks5 = "socks5"

        var id: String { rawValue }

        var label: String {
            switch self {
            case .http: "HTTP CONNECT"
            case .socks5: "SOCKS5"
            }
        }
    }

    nonisolated struct Config: Equatable, Sendable, CustomDebugStringConvertible {
        var mode: Mode = .none
        var proxyProtocol: ProxyProtocol = .http
        var host: String = ""
        var port: UInt16 = 7890
        var username: String = ""
        var password: String = ""

        var debugDescription: String {
            let masked = password.isEmpty ? "" : "<redacted>"
            return "ProxyConfig(mode: \(mode.rawValue), protocol: \(proxyProtocol.rawValue), host: \(host), port: \(port), username: \(username), password: \(masked))"
        }

        var summaryText: String {
            switch mode {
            case .none:
                return "直连"
            case .system:
                return "系统代理"
            case .manual:
                let cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleanHost.isEmpty else { return proxyProtocol.rawValue.uppercased() }
                return "\(proxyProtocol.rawValue.uppercased()) \(cleanHost):\(port)"
            }
        }

        /// 生成与 core `ProxyConfig`（camelCase）严格对齐的 JSON 载荷。
        func toFFIPayload() -> [String: Any] {
            let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedUser = username.trimmingCharacters(in: .whitespacesAndNewlines)
            var dict: [String: Any] = [
                "mode": mode.rawValue,
                "host": mode == .manual ? trimmedHost : "",
                "port": mode == .manual ? Int(port) : 0,
            ]
            if mode == .manual {
                dict["protocol"] = proxyProtocol.rawValue
                if !trimmedUser.isEmpty {
                    dict["username"] = trimmedUser
                }
                if !password.isEmpty {
                    dict["password"] = password
                }
            }
            return dict
        }

        func toJSONString() -> String? {
            guard let data = try? JSONSerialization.data(withJSONObject: toFFIPayload()) else {
                return nil
            }
            return String(data: data, encoding: .utf8)
        }
    }

    private(set) var config: Config
    private let defaults: UserDefaults
    private let passwordKeychain: SessionKeychain

    init(
        defaults: UserDefaults = .standard,
        keychainService: String = "com.rabbitcontrol.ios.proxy"
    ) {
        self.defaults = defaults
        self.passwordKeychain = SessionKeychain(service: keychainService)
        self.config = Self.loadPersisted(defaults: defaults, keychain: self.passwordKeychain)
    }

    /// App 启动时（`rc_runtime_init` 前）静默下发已持久化的出站代理配置。
    func applyPersistedOnStartup() {
        guard !AuthService.uiTestingMock else { return }
        // 默认直连无需额外唤醒，非直连时同步注入核心层全局代理槽位
        guard config.mode != .none else { return }
        _ = Self.applyToCoreSync(config)
    }

    /// 校验并应用新的出站代理配置；成功时持久化（密码写钥匙串），失败抛出结构化 `RCUiErrorFailure`。
    func apply(_ draft: Config) async throws {
        if AuthService.uiTestingMock {
            try persist(draft)
            config = draft
            return
        }
        let uiError = await Task.detached(priority: .userInitiated) {
            Self.applyToCoreSync(draft)
        }.value
        if let uiError {
            throw RCUiErrorFailure(uiError: uiError)
        }
        try persist(draft)
        config = draft
    }

    nonisolated static func applyToCoreSync(_ candidate: Config) -> RCUiError? {
        guard let json = candidate.toJSONString() else {
            return CoreClient.resolveUiError(code: RCErrorCodes.validationInvalidJson)
        }
        let raw = json.withCString { ptr in
            CoreClient.withRustString(rc_proxy_set_config_json(ptr))
        }
        guard let raw,
              let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return CoreClient.resolveUiError(code: RCErrorCodes.serviceRuntimeNotInitialized)
        }
        if obj["ok"] as? Bool == true {
            return nil
        }
        return RCUiErrorCodec.extractEnvelopeError(
            from: obj,
            fallbackCode: RCErrorCodes.validationInvalidConfig
        ) ?? CoreClient.resolveUiError(code: RCErrorCodes.validationInvalidConfig)
    }

    private func persist(_ newConfig: Config) throws {
        let cleanHost = newConfig.host.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanUser = newConfig.username.trimmingCharacters(in: .whitespacesAndNewlines)
        defaults.set(newConfig.mode.rawValue, forKey: "proxy.mode")
        defaults.set(newConfig.proxyProtocol.rawValue, forKey: "proxy.protocol")
        defaults.set(cleanHost, forKey: "proxy.host")
        defaults.set(Int(newConfig.port), forKey: "proxy.port")
        defaults.set(cleanUser, forKey: "proxy.username")
        if newConfig.mode == .manual, !newConfig.password.isEmpty {
            try passwordKeychain.store(Data(newConfig.password.utf8))
        } else {
            try? passwordKeychain.remove()
        }
    }

    private static func loadPersisted(defaults: UserDefaults, keychain: SessionKeychain) -> Config {
        let mode = Mode(rawValue: defaults.string(forKey: "proxy.mode") ?? "") ?? .none
        let proto = ProxyProtocol(rawValue: defaults.string(forKey: "proxy.protocol") ?? "") ?? .http
        let host = defaults.string(forKey: "proxy.host") ?? ""
        let rawPort = defaults.object(forKey: "proxy.port") as? Int ?? 7890
        let port = UInt16((1...65535).contains(rawPort) ? rawPort : 7890)
        let username = defaults.string(forKey: "proxy.username") ?? ""
        let password: String
        if let pwdData = try? keychain.load(), let str = String(data: pwdData, encoding: .utf8) {
            password = str
        } else {
            password = ""
        }
        return Config(
            mode: mode,
            proxyProtocol: proto,
            host: host,
            port: port,
            username: username,
            password: password
        )
    }
}
