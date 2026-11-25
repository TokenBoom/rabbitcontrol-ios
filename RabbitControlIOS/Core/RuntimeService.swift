import Foundation
import UIKit
import RabbitControlCore

/// 有状态运行时桥接:设备证书 + 信令 + 一键连接。
/// 与 AuthService(无状态 HTTP 账号管理)分工:本服务负责建立/维护
/// 信令长连接,并把「9 位设备码 → 远控会话」链路压缩为一次调用。
@Observable
final class RuntimeService {
    static let shared = RuntimeService()

    private(set) var initialized = false
    private(set) var signalRunning = false
    private(set) var deviceID: String?
    private(set) var lastError: String?

    private init() {}

    // MARK: - 初始化与信令生命周期

    private let queue = DispatchQueue(label: "rabbitcontrol.auth.runtime", qos: .userInitiated)
    private var generation = 0

    func sync(_ session: AuthService.Session?, target: AuthService.ServerTarget, rebuild: Bool = false) {
        guard !AuthService.uiTestingMock else { return }
        generation += 1
        let revision = generation
        if rebuild { initialized = false; signalRunning = false; deviceID = nil }
        guard var dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("runtime", isDirectory: true) else { return }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try dir.setResourceValues(values)
        } catch { lastError = "无法准备设备身份存储"; return }
        var config = target.payload
        config["data_dir"] = dir.path
        config["external_auth"] = true
        let initJSON = rebuild || !initialized ? Self.jsonString(config) : nil
        let tokenJSON: String? = session.flatMap { s in
            guard let user = s.userID, let expiry = s.expiresAt, expiry > Date.now.timeIntervalSince1970 + 180,
                  s.matches(target) else { return nil }
            return Self.jsonString(["user_id": user, "email": s.email, "display_name": s.displayName,
                "must_change_password": s.mustChangePassword ?? false, "access_token": s.accessToken,
                "refresh_token": "", "access_expires_at_unix_sec": UInt64(expiry),
                "server_host": target.host, "api_port": target.effectiveAPIPort])
        }
        let startJSON = signalRunning && initJSON == nil ? nil : Self.jsonString(["hostname": UIDevice.current.name, "os": "ios"])
        queue.async {
            var ready = true
            var error: String?
            var id: String?
            if let initJSON { let r = Self.callSyncJSON(initJSON, rc_runtime_init); ready = r?["device_pubkey_hex"] is String }
            if ready, let tokenJSON {
                let adopted = Self.callSyncJSON(tokenJSON, rc_runtime_set_session)
                if adopted?["ok"] as? Bool != true { error = "信令登录状态不可用" }
                else if let startJSON {
                    let r = Self.callSyncJSON(startJSON, rc_signal_start)
                    id = r?["device_id"] as? String
                    if id == nil { error = r?["error"] as? String ?? "信令启动失败" }
                }
            }
            Task { @MainActor [ready, id, error] in
                guard revision == self.generation else { return }
                self.initialized = ready
                self.lastError = ready ? error : "设备身份初始化失败"
                if startJSON != nil { self.deviceID = id; self.signalRunning = id != nil }
            }
        }
    }

    func logout() {
        generation += 1
        initialized = false; signalRunning = false; deviceID = nil; lastError = nil
        queue.async { _ = Self.callSync(rc_signal_stop); _ = Self.callSync(rc_runtime_logout) }
    }

    // MARK: - 一键连接

    struct ConnectResult {
        let sessionID: UInt64
        let ownerConnection: Bool
    }

    /// 通过信令连接账号设备。阻塞在后台线程完成,调用方无需关心线程。
    /// - Parameters:
    ///   - targetID: 9 位设备码
    ///   - lanDirectAddr: 局域网直连地址(加速,可选)
    static func connect(targetID: String,
                        password: String? = nil,
                        watchOnly: Bool = false,
                        lanDirectAddr: String? = nil) async throws -> ConnectResult {
        let prefs = PrefsStore.shared
        var dict: [String: Any] = [
            "target_id": targetID,
            "watch_only": watchOnly,
            // 求分辨率超出被控端能力时 host 会静默不出流(v0.1.13 实测),1280x720 是安全下限;
            // 实际流分辨率由被控端按自身屏幕协商返回。
            "width": 1280,
            "height": 720,
            "fps": prefs.effectiveFps,
            "bitrate_bps": prefs.effectiveBitrateBps,
        ]
        if let password, !password.isEmpty { dict["password"] = password }
        if let lanDirectAddr { dict["lan_direct_addr"] = lanDirectAddr }
        guard let payload = jsonString(dict) else {
            throw AuthService.AuthError.badResponse
        }
        let raw = await Task.detached(priority: .userInitiated) {
            payload.withCString { ptr in Self.callSync { rc_runtime_connect(ptr) } }
        }.value
        guard let raw, let resp = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else {
            throw AuthService.AuthError.noResponse
        }
        if let err = resp["error"] as? String {
            throw AuthService.AuthError.server(err)
        }
        guard let sid = resp["session_id"] as? NSNumber else {
            throw AuthService.AuthError.badResponse
        }
        return ConnectResult(sessionID: sid.uint64Value,
                             ownerConnection: resp["owner_connection"] as? Bool ?? false)
    }

    // MARK: - FFI 辅助(与 SessionService 同构)

    nonisolated static func jsonString(_ dict: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    nonisolated static func callSync(_ f: () -> UnsafeMutablePointer<CChar>?) -> String? {
        guard let ptr = f() else { return nil }
        defer { rc_string_free(ptr) }
        return String(cString: ptr)
    }

    nonisolated static func callSyncJSON(_ payload: String,
                                         _ f: (UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?) -> [String: Any]? {
        payload.withCString { cstr in
            guard let ptr = f(cstr) else { return nil }
            defer { rc_string_free(ptr) }
            let s = String(cString: ptr)
            guard let data = s.data(using: .utf8) else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
    }
}
