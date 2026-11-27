import Darwin
import Foundation
import RabbitControlCore
import UIKit

/// 有状态运行时桥接:设备证书 + 信令 + Wake-on-LAN + 一键连接。
/// 与 AuthService(无状态 HTTP 账号管理)分工:本服务负责建立/维护
/// 信令长连接,并把「9 位设备码 → 远控会话」链路压缩为一次调用。
@Observable
final class RuntimeService {
    static let shared = RuntimeService()

    private(set) var initialized = false
    private(set) var signalRunning = false
    private(set) var deviceID: String?
    private(set) var lastUiError: RCUiError?
    var lastError: String? {
        lastUiError.map { $0.message.isEmpty ? $0.title : $0.message }
    }
    /// 信令实时同步的同账号设备 Wake-on-LAN 能力快照（键为 9 位去空格设备码）。
    private(set) var wolCapableByDeviceID: [String: Bool] = [:]

    private init() {}

    // MARK: - 初始化与信令生命周期

    private let queue = DispatchQueue(label: "rabbitcontrol.auth.runtime", qos: .userInitiated)
    private var generation = 0

    func sync(_ session: AuthService.Session?, target: AuthService.ServerTarget, rebuild: Bool = false) {
        guard !AuthService.uiTestingMock else { return }
        generation += 1
        let revision = generation
        if rebuild {
            initialized = false
            signalRunning = false
            deviceID = nil
            wolCapableByDeviceID = [:]
        }
        guard var dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("runtime", isDirectory: true) else { return }
        do {
            try FileManager.default.createDirectory(
                at: dir,
                withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
            )
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try dir.setResourceValues(values)
        } catch {
            lastUiError = RCUiErrorCodec.fromError(error, fallbackCode: RCErrorCodes.pkiError)
            return
        }
        var config = target.runtimePayload
        config["data_dir"] = dir.path
        config["external_auth"] = true
        let initJSON = rebuild || !initialized ? Self.jsonString(config) : nil
        let tokenJSON: String? = session.flatMap { s in
            guard let user = s.userID,
                  let expiry = s.expiresAt,
                  expiry > Date.now.timeIntervalSince1970 + 180,
                  s.matches(target) else { return nil }
            return Self.jsonString([
                "user_id": user,
                "email": s.email,
                "display_name": s.displayName,
                "must_change_password": s.mustChangePassword ?? false,
                "access_token": s.accessToken,
                "refresh_token": "",
                "access_expires_at_unix_sec": UInt64(expiry),
                "server_host": target.host,
                "api_port": target.effectiveAPIPort,
            ])
        }
        let startJSON = signalRunning && initJSON == nil ? nil : Self.jsonString([
            "hostname": UIDevice.current.name,
            "os": "ios",
            "lan_addrs": Self.localLANIPv4Addresses(),
        ])
        queue.async {
            var ready = true
            var uiError: RCUiError?
            var id: String?
            if let initJSON {
                let r = Self.callSyncJSON(initJSON, rc_runtime_init)
                ready = r?["device_pubkey_hex"] is String
                if !ready {
                    uiError = r.flatMap { RCUiErrorCodec.extractEnvelopeError(from: $0, fallbackCode: RCErrorCodes.pkiError) }
                        ?? CoreClient.resolveUiError(code: RCErrorCodes.pkiError, detail: "设备身份初始化失败")
                }
            }
            if ready, let tokenJSON {
                let adopted = Self.callSyncJSON(tokenJSON, rc_runtime_set_session)
                if adopted?["ok"] as? Bool != true {
                    uiError = adopted.flatMap { RCUiErrorCodec.extractEnvelopeError(from: $0, fallbackCode: RCErrorCodes.authReloginRequired) }
                        ?? CoreClient.resolveUiError(code: RCErrorCodes.authReloginRequired)
                } else if let startJSON {
                    let r = Self.callSyncJSON(startJSON, rc_signal_start)
                    id = r?["device_id"] as? String
                    if id == nil {
                        uiError = r.flatMap { RCUiErrorCodec.extractEnvelopeError(from: $0, fallbackCode: RCErrorCodes.signalRegisterFailed) }
                            ?? CoreClient.resolveUiError(code: RCErrorCodes.signalRegisterFailed)
                    }
                }
            }
            let wolSnapshot = id != nil ? Self.fetchWolCapableSnapshotSync() : [:]
            Task { @MainActor [ready, id, uiError, wolSnapshot] in
                guard revision == self.generation else { return }
                self.initialized = ready
                self.lastUiError = uiError
                if startJSON != nil {
                    self.deviceID = id
                    self.signalRunning = id != nil
                }
                if !wolSnapshot.isEmpty {
                    self.wolCapableByDeviceID = wolSnapshot
                }
            }
        }
    }

    /// 切网后携带最新局域网 IPv4 列表重建信令会话，加速同网段 P2P 路由更新。
    func handleNetworkChange() {
        guard !AuthService.uiTestingMock,
              let session = AuthService.shared.session,
              !AuthService.shared.requiresPasswordChange else { return }
        signalRunning = false
        sync(session, target: AuthService.shared.serverTarget, rebuild: false)
    }

    /// 刷新信令连接健康快照（`ServerStatusSnapshot` camelCase `uiError`）与同账号设备 WoL 能力缓存。
    func refreshSignalMetadata() {
        guard !AuthService.uiTestingMock, initialized else { return }
        let revision = generation
        queue.async {
            let statusObj = Self.callSyncJSON("{}", rc_signal_status)
            let wolMap = Self.fetchWolCapableSnapshotSync()
            let parsedStatus = Self.interpretSignalStatus(statusObj)
            Task { @MainActor [wolMap, parsedStatus] in
                guard revision == self.generation else { return }
                self.wolCapableByDeviceID = wolMap
                if let connected = parsedStatus.connected {
                    self.signalRunning = connected
                }
                if let uiErr = parsedStatus.uiError {
                    self.lastUiError = uiErr
                } else if parsedStatus.connected == true {
                    self.lastUiError = nil
                }
            }
        }
    }

    /// 解析 `rc_signal_status` 返回值：
    /// - 成功时为 `ServerStatusSnapshot`（camelCase 字段：`signalState` / `uiError`）；
    /// - 失败时为统一 FFI 错误信封（snake_case `ui_error`）。
    nonisolated static func interpretSignalStatus(_ obj: [String: Any]?) -> (connected: Bool?, uiError: RCUiError?) {
        guard let obj else { return (nil, nil) }
        if obj["error"] != nil && obj["signalState"] == nil {
            let err = RCUiErrorCodec.extractEnvelopeError(
                from: obj,
                preferCamelCase: false,
                fallbackCode: RCErrorCodes.signalNotStarted
            )
            return (false, err)
        }
        let signalState = (obj["signalState"] as? String)?.lowercased()
        let isOnline: Bool? = signalState.map { $0 == "online" || $0 == "connected" || $0 == "registered" }
        let snapError = RCUiErrorCodec.decode(from: obj["uiError"] as? [String: Any])
        return (isOnline, snapError)
    }

    func isWolCapable(_ account: AccountDevice) -> Bool {
        let normalized = account.deviceID.replacingOccurrences(of: " ", with: "")
        if let live = wolCapableByDeviceID[normalized] {
            return live
        }
        return account.wolCapable
    }

    func logout() {
        generation += 1
        initialized = false
        signalRunning = false
        deviceID = nil
        lastUiError = nil
        wolCapableByDeviceID = [:]
        queue.async {
            _ = Self.callSync(rc_signal_stop)
            _ = Self.callSync(rc_runtime_logout)
        }
    }

    // MARK: - Wake-on-LAN 远程开机

    nonisolated struct WolAck: Equatable, Sendable {
        let targetDeviceID: String
        let ok: Bool
        let method: String
        let code: String?
        let message: String
    }

    /// 向服务端请求唤醒离线同账号设备（阻塞在后台线程完成）。
    /// - 成功收到 `ok == true` 返回 `WolAck`；
    /// - 收到 `ok == false`（camelCase `uiError`）或 FFI 本地信封错误（snake_case `ui_error`）抛出 `RCUiErrorFailure`。
    static func requestWakeOnLAN(targetID: String, timeoutMs: UInt32 = 10_000) async throws -> WolAck {
        let cleanID = targetID.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = await Task.detached(priority: .userInitiated) {
            cleanID.withCString { ptr in
                Self.callSync { rc_signal_request_wol(ptr, timeoutMs) }
            }
        }.value
        return try decodeWolResponse(raw)
    }

    nonisolated static func decodeWolResponse(_ raw: String?) throws -> WolAck {
        guard let raw,
              let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RCUiErrorFailure(
                uiError: CoreClient.resolveUiError(code: RCErrorCodes.serviceRuntimeNotInitialized, detail: "核心库无响应")
            )
        }
        // 本地 FFI 错误信封（未初始化 / 信令未启动 / 超时断线）：snake_case `ui_error`
        if obj["ok"] == nil, let envelopeErr = RCUiErrorCodec.extractEnvelopeError(
            from: obj,
            preferCamelCase: false,
            fallbackCode: RCErrorCodes.wolSendFailed
        ) {
            throw RCUiErrorFailure(uiError: envelopeErr)
        }
        let ok = obj["ok"] as? Bool ?? false
        let targetDeviceID = obj["targetDeviceId"] as? String ?? ""
        let method = obj["method"] as? String ?? "none"
        let code = obj["code"] as? String
        let message = obj["message"] as? String ?? ""
        if ok {
            return WolAck(targetDeviceID: targetDeviceID, ok: true, method: method, code: code, message: message)
        }
        // 服务端返回唤醒失败：优先解码 camelCase `uiError`
        let uiErr = RCUiErrorCodec.decode(from: obj["uiError"] as? [String: Any])
            ?? CoreClient.resolveUiError(
                code: code ?? RCErrorCodes.wolSendFailed,
                detail: message.isEmpty ? nil : message
            )
        throw RCUiErrorFailure(uiError: uiErr)
    }

    nonisolated private static func fetchWolCapableSnapshotSync() -> [String: Bool] {
        guard let raw = callSync(rc_signal_wol_capable_snapshot_json),
              let data = raw.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Bool] else {
            return [:]
        }
        return dict
    }

    // MARK: - 一键连接

    struct ConnectResult {
        let sessionID: UInt64
        let ownerConnection: Bool
    }

    /// 校验出站代理与连接路由模式是否冲突（基线 §4.5：启用代理时选择 `P2pOnly` 明确返回 `proxy.config_conflict`）。
    static func validateProxyAndConnectionMode(_ mode: ConnectionMode) throws {
        if ProxyConfigStore.shared.config.mode != .none, mode == .p2pOnly {
            throw AuthService.AuthError.structured(
                CoreClient.resolveUiError(code: RCErrorCodes.proxyConfigConflict)
            )
        }
    }

    /// 通过信令连接账号设备或伙伴设备。阻塞在后台线程完成,调用方无需关心线程。
    /// - Parameters:
    ///   - targetID: 9 位设备码
    ///   - lanDirectAddr: 局域网直连地址(加速,可选)
    ///   - connectionMode: 显式指定连接模式(默认取 `PrefsStore.shared.connectionMode`)
    ///   - toolsOnly: 纯工具无头模式标记
    static func connect(
        targetID: String,
        password: String? = nil,
        watchOnly: Bool = false,
        lanDirectAddr: String? = nil,
        connectionMode: ConnectionMode? = nil,
        toolsOnly: Bool = false
    ) async throws -> ConnectResult {
        do {
            try AppLockStore.shared.requireUnlocked()
        } catch {
            throw AuthService.AuthError.structured(RCUiErrorCodec.fromError(error))
        }
        if AuthService.shared.requiresPasswordChange {
            throw AuthService.AuthError.structured(
                CoreClient.resolveUiError(code: RCErrorCodes.authPasswordChangeRequired)
            )
        }
        let prefs = PrefsStore.shared
        let effectiveMode = connectionMode ?? prefs.connectionMode
        try validateProxyAndConnectionMode(effectiveMode)

        var dict: [String: Any] = [
            "target_id": targetID,
            "watch_only": watchOnly,
            // 不硬编码低分辨率，交由被控端按自身当前屏幕协商
            "fps": prefs.effectiveFps,
            "bitrate_bps": prefs.effectiveBitrateBps,
            "connection_mode": effectiveMode.rawValue,
            "force_relay": effectiveMode == .tcpRelay,
            "tools_only": toolsOnly,
            "encrypt_connection": prefs.encryptConnection,
        ]
        if let password, !password.isEmpty { dict["password"] = password }
        if effectiveMode != .tcpRelay,
           ProxyConfigStore.shared.config.mode == .none,
           let lanDirectAddr {
            dict["lan_direct_addr"] = lanDirectAddr
        }
        guard let payload = jsonString(dict) else {
            throw AuthService.AuthError.badResponse
        }
        let raw = await Task.detached(priority: .userInitiated) {
            payload.withCString { ptr in Self.callSync { rc_runtime_connect(ptr) } }
        }.value
        guard let raw, let resp = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else {
            throw AuthService.AuthError.noResponse
        }
        if let uiErr = RCUiErrorCodec.extractEnvelopeError(from: resp) {
            throw AuthService.AuthError.structured(uiErr)
        }
        guard let sid = resp["session_id"] as? NSNumber else {
            throw AuthService.AuthError.badResponse
        }
        return ConnectResult(
            sessionID: sid.uint64Value,
            ownerConnection: resp["owner_connection"] as? Bool ?? false
        )
    }

    // MARK: - FFI 辅助(与 SessionService 同构)

    /// 采集本机活跃局域网接口(Wi-Fi / 有线 / 桥接)的 IPv4 地址,排除回环、链路本地、蜂窝与隧道虚拟网卡。
    nonisolated static func isEligibleLANInterface(name: String, ipv4: String) -> Bool {
        let allowedPrefixes = ["en", "bridge"]
        guard allowedPrefixes.contains(where: { name.hasPrefix($0) }) else { return false }
        guard !ipv4.isEmpty,
              !ipv4.hasPrefix("127."),
              !ipv4.hasPrefix("169.254."),
              ipv4 != "0.0.0.0" else {
            return false
        }
        return true
    }

    nonisolated static func localLANIPv4Addresses() -> [String] {
        var firstAddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&firstAddr) == 0, let head = firstAddr else { return [] }
        defer { freeifaddrs(head) }

        var results: [String] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = head
        while let entry = cursor?.pointee {
            defer { cursor = entry.ifa_next }
            let flags = Int32(entry.ifa_flags)
            guard (flags & IFF_UP) != 0,
                  (flags & IFF_LOOPBACK) == 0,
                  let addr = entry.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET) else {
                continue
            }
            let name = String(cString: entry.ifa_name)
            var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(
                addr,
                socklen_t(addr.pointee.sa_len),
                &hostBuffer,
                socklen_t(hostBuffer.count),
                nil,
                0,
                NI_NUMERICHOST
            ) == 0 else {
                continue
            }
            let ip = String(
                decoding: hostBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
                as: UTF8.self
            )
            if isEligibleLANInterface(name: name, ipv4: ip), !results.contains(ip) {
                results.append(ip)
            }
        }
        return results
    }

    nonisolated static func jsonString(_ dict: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    nonisolated static func callSync(_ f: () -> UnsafeMutablePointer<CChar>?) -> String? {
        CoreClient.withRustString(f())
    }

    nonisolated static func callSyncJSON(
        _ payload: String,
        _ f: (UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?
    ) -> [String: Any]? {
        payload.withCString { cstr in
            guard let s = CoreClient.withRustString(f(cstr)),
                  let data = s.data(using: .utf8) else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
    }
}
