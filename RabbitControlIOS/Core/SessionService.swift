import AVFAudio
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
    static let shared = SessionService()

    private(set) var sessionID: UInt64?
    private(set) var state: SessionState = .idle
    private(set) var peerWatchOnly = false
    private(set) var mutuallyAuthenticated: Bool?
    private(set) var audioMuted = false
    private var playbackActive = false
    private(set) var clipboardEnabled = false
    private(set) var receivedText: String?
    private(set) var display: DisplayConfig?
    struct DisplayConfig: Decodable {
        struct Preset: Decodable, Hashable {
            let width, height: Int
            let label: String
        }
        let width, height, fps, maxFps: Int
        let presets: [Preset]
    }
    private(set) var hud: [String: Any]?
    private var pollTask: Task<Void, Never>?

    var isConnected: Bool {
        guard case .negotiated = state else { return false }
        return sessionID != nil
    }

    // MARK: - 生命周期

    /// 收养已由运行时(信令)建立的会话,接管轮询与输入。
    func adopt(sessionID id: UInt64, watchOnly: Bool) {
        close()
        peerWatchOnly = watchOnly
        sessionID = id
        state = .connecting(phase: "endpoint_creating")
        startPolling()
    }

    /// 直连打开会话(LAN 或手动输入地址)。
    func open(connectAddr: String, password: String?, watchOnly: Bool) {
        close()
        peerWatchOnly = watchOnly
        var payload: [String: Any] = [
            "connect_addr": connectAddr,
            "watch_only": watchOnly,
            "fps": PrefsStore.shared.effectiveFps,
            "bitrate_bps": PrefsStore.shared.effectiveBitrateBps,
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
        releasePressedInput()
        setPlaybackActive(false)
        pollTask?.cancel()
        pollTask = nil
        if let id = sessionID, let payload = Self.jsonString(["session_id": id]) {
            inputQueue.async { _ = Self.callSyncJSON(rc_session_close, payload) }
        }
        sessionID = nil
        state = .idle
        peerWatchOnly = false
        mutuallyAuthenticated = nil
        audioMuted = false
        clearClipboard()
        display = nil
        hud = nil
    }

    static func releaseSession(_ id: UInt64) {
        guard let json = jsonString(["session_id": id]) else { return }
        Task.detached(priority: .userInitiated) { _ = callSyncJSON(rc_session_close, json) }
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
        guard !Task.isCancelled, id == sessionID, let raw,
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
        if case .ended = state { setPlaybackActive(false); pollTask?.cancel() }
        if clipboardEnabled {
            if !isConnected || peerWatchOnly { clearClipboard() }
            else if let ptr = rc_apple_clipboard_take() {
                defer { rc_string_free(ptr) }
                receivedText = try? JSONDecoder().decode(String.self, from: Data(String(cString: ptr).utf8))
            }
        }
    }

    /// 协商后的视频尺寸(aspect-fit 布局/输入映射用);未协商为 0。
    var width: Int {
        if case .negotiated(let w, _, _, _, _) = state { return w }
        return 0
    }

    var height: Int {
        if case .negotiated(_, let h, _, _, _) = state { return h }
        return 0
    }

    private func applyUpdate(_ update: [String: Any]) {
        guard let kind = update["kind"] as? String else { return }
        let data = update["data"] as? [String: Any]
        switch kind {
        case "connecting":
            state = .connecting(phase: data?["phase"] as? String ?? "")
        case "negotiated":
            peerWatchOnly = peerWatchOnly || data?["watch_only"] as? Bool == true
            if !InteractionPrefs.shared.audioEnabledDefault && !audioMuted {
                audioMuted = true
                sendCommand(["type": "set_audio_muted", "muted": true])
            }
            setPlaybackActive(!audioMuted)
            if InteractionPrefs.shared.clipboardEnabledDefault && !peerWatchOnly && !clipboardEnabled {
                setClipboardEnabled(true)
            }
            mutuallyAuthenticated = data?["mtls_active"] as? Bool
            state = .negotiated(
                width: data?["width"] as? Int ?? 0,
                height: data?["height"] as? Int ?? 0,
                fps: data?["fps"] as? Int ?? 0,
                backend: data?["backend"] as? String ?? "",
                transport: data?["transport"] as? String ?? ""
            )
        case "hud":
            hud = data
        case "display_config":
            if let data, let bytes = try? JSONSerialization.data(withJSONObject: data) {
                let decoder = JSONDecoder()
                decoder.keyDecodingStrategy = .convertFromSnakeCase
                display = try? decoder.decode(DisplayConfig.self, from: bytes)
            }
        case "session_switching":
            state = .switching(reason: data?["reason"] as? String ?? "切换中…")
        case "ended":
            state = .ended(reason: data?["reason"] as? String ?? "")
        default:
            break
        }
    }

    private let inputQueue = DispatchQueue(label: "rabbitcontrol.session.input", qos: .userInteractive)
    private var pressedButtons = Set<String>()
    private var pressedKeys = Set<UInt16>()

    func releasePressedInput() {
        for button in pressedButtons { sendInput(["kind": "mouse_button", "button": button, "pressed": false]) }
        for key in pressedKeys { sendInput(["kind": "key", "scancode": key, "pressed": false]) }
        pressedButtons.removeAll()
        pressedKeys.removeAll()
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
        guard isConnected, !peerWatchOnly else { return }
        if pressed { pressedButtons.insert(button) } else { pressedButtons.remove(button) }
        sendInput(["kind": "mouse_button", "button": button, "pressed": pressed])
    }

    func sendWheel(delta: Int, horizontal: Bool = false) {
        sendInput(["kind": "mouse_wheel", "delta": delta, "horizontal": horizontal])
    }

    func sendKey(scancode: UInt16, pressed: Bool, modifiers: UInt8 = 0) {
        guard isConnected, !peerWatchOnly else { return }
        if pressed { pressedKeys.insert(scancode) } else { pressedKeys.remove(scancode) }
        sendInput(["kind": "key", "scancode": scancode, "pressed": pressed, "modifiers": modifiers])
    }

    private func sendInput(_ fields: [String: Any]) {
        guard isConnected, !peerWatchOnly, let id = sessionID else { return }
        var payload = fields
        payload["session_id"] = id
        guard let json = Self.jsonString(payload) else { return }
        inputQueue.async {
            _ = Self.callSyncJSON(rc_session_input, json)
        }
    }

    func tapKey(_ key: UInt16, modifiers: [UInt16]) {
        for code in modifiers { sendKey(scancode: code, pressed: true) }
        sendKey(scancode: key, pressed: true)
        sendKey(scancode: key, pressed: false)
        for code in modifiers.reversed() { sendKey(scancode: code, pressed: false) }
    }

    private func sendCommand(_ command: [String: Any]) {
        guard let id = sessionID else { return }
        let payload: [String: Any] = ["session_id": id, "command": command]
        guard let json = Self.jsonString(payload) else { return }
        inputQueue.async {
            _ = Self.callSyncJSON(rc_session_command, json)
        }
    }

    func disconnect() {
        sendCommand(["type": "disconnect"])
    }

    /// 请求远端立即刷新关键帧(画面花屏/卡住时恢复)。
    func requestIDR() {
        sendCommand(["type": "request_idr"])
    }

    func setBitrate(_ bps: Int) {
        guard isConnected, !peerWatchOnly else { return }
        sendCommand(["type": "set_bitrate", "bps": bps])
    }

    func lockRemoteScreen() {
        guard isConnected, !peerWatchOnly else { return }
        sendCommand(["type": "lock_remote_screen"])
    }

    func setAudioMuted(_ muted: Bool) {
        guard isConnected else { return }
        audioMuted = muted
        setPlaybackActive(!muted)
        sendCommand(["type": "set_audio_muted", "muted": muted])
    }

    /// App 切回前台时重新激活音频会话(防止后台被系统打断后无声)。
    func resumeAudioIfNeeded() {
        guard isConnected, !audioMuted else { return }
        playbackActive = false
        setPlaybackActive(true)
    }

    private func setPlaybackActive(_ active: Bool) {
        guard playbackActive != active else { return }
        let audio = AVAudioSession.sharedInstance()
        do {
            if active {
                try audio.setCategory(.playback, options: [.mixWithOthers])
                try audio.setActive(true)
            } else {
                try audio.setActive(false, options: [.notifyOthersOnDeactivation])
            }
            playbackActive = active
        } catch {
            playbackActive = false
        }
    }

    func setStream(width: Int = 0, height: Int = 0, fps: Int = 0) {
        guard isConnected, !peerWatchOnly, let display else { return }
        let targetW = width > 0 ? width : display.width
        let targetH = height > 0 ? height : display.height
        let targetFps = fps > 0 ? fps : display.fps
        let resValid = (width == 0 && height == 0)
            || (width == display.width && height == display.height)
            || display.presets.contains { $0.width == width && $0.height == height }
        guard resValid, (0...max(0, display.maxFps)).contains(fps) else { return }
        sendCommand(["type": "set_stream_params", "width": targetW, "height": targetH, "fps": targetFps])
        // 乐观更新本地选中状态，并保持音频通道处于激活/非静音态
        self.display = DisplayConfig(width: targetW, height: targetH, fps: targetFps,
                                     maxFps: display.maxFps, presets: display.presets)
        if !audioMuted {
            setPlaybackActive(true)
            sendCommand(["type": "set_audio_muted", "muted": false])
        }
    }

    private func clearClipboard() {
        clipboardEnabled = false
        receivedText = nil
        rc_apple_clipboard_reset()
    }

    func setClipboardEnabled(_ enabled: Bool) {
        guard isConnected, !peerWatchOnly else { return }
        clearClipboard()
        clipboardEnabled = enabled
        sendCommand(["type": "set_clipboard_enabled", "enabled": enabled])
    }

    func sendClipboard(_ text: String) -> Bool {
        guard isConnected, !peerWatchOnly, clipboardEnabled, text.utf8.count <= 65535,
              let data = try? JSONEncoder().encode(text),
              let json = String(data: data, encoding: .utf8) else { return false }
        return json.withCString { rc_apple_clipboard_send($0) == 1 }
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
