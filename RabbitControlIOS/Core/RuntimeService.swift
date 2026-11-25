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

    /// 幂等初始化。serverHost 与 AuthService 的服务器配置保持一致。
    func boot(serverHost: String, useHTTPS: Bool) {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("runtime", isDirectory: true) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let payload = Self.jsonString([
            "server_host": serverHost,
            "use_https": useHTTPS,
            "data_dir": dir.path,
        ])
        guard let payload else { return }
        if let resp = Self.callSyncJSON(payload, rc_runtime_init),
           resp["error"] == nil {
            initialized = true
        } else {
            lastError = "运行时初始化失败"
        }
    }

    /// 登录后调用:绑定设备 + 签发证书 + 拉起信令。
    func startSignal() {
        guard initialized, !signalRunning else { return }
        let host = UIDevice.current.name
        guard let payload = Self.jsonString(["hostname": host, "os": "ios"]) else { return }
        if let resp = Self.callSyncJSON(payload, rc_signal_start) {
            if let err = resp["error"] as? String {
                lastError = err
                return
            }
            deviceID = resp["device_id"] as? String
            signalRunning = true
            lastError = nil
        }
    }

    func stopSignal() {
        guard signalRunning else { return }
        _ = Self.callSync(rc_signal_stop)
        signalRunning = false
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
        var dict: [String: Any] = [
            "target_id": targetID,
            "watch_only": watchOnly,
        ]
        if let password, !password.isEmpty { dict["password"] = password }
        if let lanDirectAddr { dict["lan_direct_addr"] = lanDirectAddr }
        guard let payload = jsonString(dict) else {
            throw AuthService.AuthError.badResponse
        }
        guard let resp = callSyncJSON(payload, rc_runtime_connect) else {
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
