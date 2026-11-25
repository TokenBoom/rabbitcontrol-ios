import Foundation
import RabbitControlCore

/// 会话状态(对齐 core `SessionUpdate` 的 kind 标签)。
enum SessionState: Equatable {
    case idle
    case connecting(phase: String)
    case negotiated(width: Int, height: Int, fps: Int, backend: String, transport: String)
    case switching(reason: String)
    case ended(reason: String)

    var displayText: String {
        switch self {
        case .idle: "未连接"
        case .connecting(let phase):
            switch phase {
            case "endpoint_creating": "正在初始化…"
            case "connecting": "正在连接…"
            case "awaiting_welcome": "等待对端应答…"
            case "first_frame_pending": "等待首帧…"
            default: "连接中…"
            }
        case .negotiated: "已连接"
        case .switching(let reason): reason
        case .ended(let reason): "已断开:\(reason)"
        }
    }
}

/// 远控会话服务:包装 core 会话 FFI,负责状态轮询与输入发送。
@Observable
final class SessionService {
    private(set) var sessionID: UInt64?
    private(set) var state: SessionState = .idle
    private(set) var hud: [String: Any]?
    private var pollTask: Task<Void, Never>?

    var isActive: Bool { sessionID != nil && state != .idle }

    // MARK: - 生命周期

    /// 直连打开会话(LAN 或手动输入地址)。
    func open(connectAddr: String, password: String?, watchOnly: Bool) {
        close()
        var payload: [String: Any] = [
            "connect_addr": connectAddr,
            "watch_only": watchOnly,
            "fps": 30,
            "bitrate_bps": 8_000_000,
        ]
        if let password, !password.isEmpty {
            payload["password"] = password
        }
        guard let raw = Self.callSync(rc_session_open, payload),
              let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            state = .ended(reason: "核心库无响应")
            return
        }
        if let error = obj["error"] as? String {
            state = .ended(reason: error)
            return
        }
        guard let id = obj["session_id"] as? UInt64 else {
            state = .ended(reason: "响应格式错误")
            return
        }
        sessionID = id
        state = .connecting(phase: "endpoint_creating")
        startPolling()
    }

    func close() {
        pollTask?.cancel()
        pollTask = nil
        if let id = sessionID {
            let payload: [String: Any] = ["session_id": id]
            if let json = Self.jsonString(payload) {
                Task.detached(priority: .userInitiated) {
                    _ = Self.callSyncJSON(rc_session_close, json)
                }
            }
        }
        sessionID = nil
        state = .idle
        hud = nil
    }

    // MARK: - 轮询

    private func startPolling() {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollOnce()
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private func pollOnce() async {
        guard let id = sessionID else { return }
        let payload: [String: Any] = ["session_id": id]
        guard let pollJSON = Self.jsonString(payload) else { return }
        let raw = await Task.detached(priority: .utility) {
            Self.callSyncJSON(rc_session_poll, pollJSON)
        }.value
        guard let raw,
              let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let updates = obj["updates"] as? [[String: Any]] else { return }

        for update in updates {
            applyUpdate(update)
        }
        if obj["running"] as? Bool == false, case .ended = state {
            // 已结束状态保持不变
        } else if obj["running"] as? Bool == false {
            state = .ended(reason: "会话线程退出")
        }
    }

    private func applyUpdate(_ update: [String: Any]) {
        guard let kind = update["kind"] as? String else { return }
        let data = update["data"] as? [String: Any]
        switch kind {
        case "connecting":
            state = .connecting(phase: data?["phase"] as? String ?? "")
        case "negotiated":
            state = .negotiated(
                width: data?["width"] as? Int ?? 0,
                height: data?["height"] as? Int ?? 0,
                fps: data?["fps"] as? Int ?? 0,
                backend: data?["backend"] as? String ?? "",
                transport: data?["transport"] as? String ?? ""
            )
        case "hud":
            hud = data
        case "session_switching":
            state = .switching(reason: data?["reason"] as? String ?? "切换中…")
        case "ended":
            state = .ended(reason: data?["reason"] as? String ?? "")
        default:
            break
        }
    }

    // MARK: - 输入与指令

    /// 发送指针移动(视图坐标按远端画面归一化到 0...65535)。
    func sendMouseMove(nx: Double, ny: Double) {
        sendInput([
            "kind": "mouse_move",
            "x": UInt16(max(0, min(1, nx)) * 65535),
            "y": UInt16(max(0, min(1, ny)) * 65535),
        ])
    }

    func sendMouseButton(button: String, pressed: Bool) {
        sendInput(["kind": "mouse_button", "button": button, "pressed": pressed])
    }

    func sendWheel(delta: Int, horizontal: Bool = false) {
        sendInput(["kind": "mouse_wheel", "delta": delta, "horizontal": horizontal])
    }

    func sendKey(scancode: UInt16, pressed: Bool, modifiers: UInt8 = 0) {
        sendInput(["kind": "key", "scancode": scancode, "pressed": pressed, "modifiers": modifiers])
    }

    private func sendInput(_ fields: [String: Any]) {
        guard let id = sessionID else { return }
        var payload = fields
        payload["session_id"] = id
        guard let json = Self.jsonString(payload) else { return }
        Task.detached(priority: .userInitiated) {
            _ = Self.callSyncJSON(rc_session_input, json)
        }
    }

    func sendCommand(_ command: [String: Any]) {
        guard let id = sessionID else { return }
        let payload: [String: Any] = ["session_id": id, "command": command]
        guard let json = Self.jsonString(payload) else { return }
        Task.detached(priority: .userInitiated) {
            _ = Self.callSyncJSON(rc_session_command, json)
        }
    }

    func disconnect() {
        sendCommand(["type": "disconnect"])
    }

    func setBitrate(_ bps: Int) {
        sendCommand(["type": "set_bitrate", "bps": bps])
    }

    func lockRemoteScreen() {
        sendCommand(["type": "lock_remote_screen"])
    }

    func setAudioMuted(_ muted: Bool) {
        sendCommand(["type": "set_audio_muted", "muted": muted])
    }

    // MARK: - FFI 同步调用(调用方负责线程上下文)

    nonisolated private static func jsonString(_ payload: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    nonisolated private static func callSync(
        _ function: (UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?,
        _ payload: [String: Any]
    ) -> String? {
        guard let json = jsonString(payload) else { return nil }
        return callSyncJSON(function, json)
    }

    nonisolated private static func callSyncJSON(
        _ function: (UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?,
        _ json: String
    ) -> String? {
        guard let ptr = json.withCString({ function($0) }) else { return nil }
        defer { rc_string_free(ptr) }
        return String(cString: ptr)
    }
}
