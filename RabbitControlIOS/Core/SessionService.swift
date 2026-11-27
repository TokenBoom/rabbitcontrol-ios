import AVFAudio
import Foundation
import RabbitControlCore
import UIKit

/// 会话状态(对齐 core `SessionUpdate` 的 kind 标签)。
enum SessionState: Equatable {
    case idle
    case connecting(phase: String)
    case negotiated(width: Int, height: Int, fps: Int, backend: String, transport: String)
    case reconnecting(attempt: Int, maxAttempts: Int, reason: String)
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
        case .reconnecting(let attempt, let maxAttempts, _):
            "正在重连 (\(attempt)/\(max(attempt, maxAttempts)))…"
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
    private(set) var targetDeviceID: String?
    private(set) var state: SessionState = .idle
    private(set) var peerWatchOnly = false
    private(set) var localWatchOnly = false
    /// 当前会话是否处于只读观看态（对端强制观看或控制端会话内开启观看模式）。
    var effectiveWatchOnly: Bool { peerWatchOnly || localWatchOnly }
    private(set) var mediaPaused = false
    private(set) var stillRefinementEnabled = PrefsStore.shared.stillRefinementEnabled
    private(set) var mutuallyAuthenticated: Bool?
    private(set) var peerCertFingerprint: String?
    private(set) var audioMuted = false
    private var playbackActive = false
    private(set) var clipboardEnabled = false
    private(set) var receivedText: String?
    private(set) var display: DisplayConfig?
    private(set) var displaysState: DisplaysState?
    private(set) var privacyState: PrivacyState?
    private(set) var hostMuteState: HostMuteState?
    private(set) var hostInfo: RemoteHostInfo?
    private(set) var remoteUpdateStatus: RemoteUpdateProgress?
    private(set) var hostScreenLocked = false
    private(set) var hostCaptureSuspended = false
    private(set) var mouseMode = "smart"
    private(set) var terminalLockState: TerminalLockState?
    private(set) var lastTerminalUnlockResult: TerminalUnlockResult?
    private(set) var virtualDisplayError: String?
    private(set) var toolPermissions: ToolPermissions = .allAllowed
    private(set) var endedUiError: RCUiError?
    private(set) var endedRecoverable = false
    private(set) var lastToolDeniedError: RCUiError?

    nonisolated struct TerminalLockState: Equatable, Sendable {
        let required: Bool
        let unlocked: Bool
        let username: String?
        let retryAfterSecs: UInt32

        static func decode(from dict: [String: Any]) -> TerminalLockState {
            TerminalLockState(
                required: dict["required"] as? Bool ?? false,
                unlocked: dict["unlocked"] as? Bool ?? true,
                username: dict["username"] as? String,
                retryAfterSecs: (dict["retry_after_secs"] as? NSNumber ?? dict["retryAfterSecs"] as? NSNumber)?.uint32Value ?? 0
            )
        }
    }

    nonisolated struct TerminalUnlockResult: Equatable, Sendable {
        let ok: Bool
        let error: String?
        let retryAfterSecs: UInt32

        static func decode(from dict: [String: Any]) -> TerminalUnlockResult {
            TerminalUnlockResult(
                ok: dict["ok"] as? Bool ?? false,
                error: dict["error"] as? String,
                retryAfterSecs: (dict["retry_after_secs"] as? NSNumber ?? dict["retryAfterSecs"] as? NSNumber)?.uint32Value ?? 0
            )
        }
    }

    nonisolated struct ToolPermissions: Codable, Equatable, Sendable {
        let allowFileTransfer: Bool
        let allowTerminal: Bool
        let allowPortMap: Bool

        static let allAllowed = ToolPermissions(
            allowFileTransfer: true,
            allowTerminal: true,
            allowPortMap: true
        )

        private enum CodingKeys: String, CodingKey {
            case allowFileTransfer = "allow_file_transfer"
            case allowTerminal = "allow_terminal"
            case allowPortMap = "allow_port_map"
        }

        static func decode(from dict: [String: Any]) -> ToolPermissions? {
            guard JSONSerialization.isValidJSONObject(dict),
                  let data = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
            return try? JSONDecoder().decode(ToolPermissions.self, from: data)
        }
    }

    nonisolated struct RemoteDisplay: Equatable, Identifiable, Sendable {
        let id: String
        let name: String
        let width: Int
        let height: Int
        let isMain: Bool
        let isVirtual: Bool

        static func decode(from dict: [String: Any]) -> RemoteDisplay? {
            let idString: String?
            if let s = dict["id"] as? String {
                idString = s
            } else if let n = dict["id"] as? NSNumber {
                idString = n.stringValue
            } else {
                idString = nil
            }
            guard let id = idString else { return nil }
            let width = (dict["width"] as? NSNumber)?.intValue ?? 0
            let height = (dict["height"] as? NSNumber)?.intValue ?? 0
            let rawName = (dict["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let fallbackName = width > 0 && height > 0 ? "显示器 (\(width)×\(height))" : "显示器 \(id)"
            return RemoteDisplay(
                id: id,
                name: rawName.isEmpty ? fallbackName : rawName,
                width: width,
                height: height,
                isMain: dict["is_main"] as? Bool ?? dict["isMain"] as? Bool ?? false,
                isVirtual: dict["is_virtual"] as? Bool ?? dict["isVirtual"] as? Bool ?? false
            )
        }
    }

    nonisolated struct DisplaysState: Equatable, Sendable {
        let displays: [RemoteDisplay]
        let activeDisplayID: String?

        var activeDisplay: RemoteDisplay? {
            if let activeDisplayID, let matched = displays.first(where: { $0.id == activeDisplayID }) {
                return matched
            }
            return displays.first(where: \.isMain) ?? displays.first
        }

        static func decode(from dict: [String: Any]) -> DisplaysState? {
            let list = (dict["displays"] as? [[String: Any]] ?? []).compactMap(RemoteDisplay.decode(from:))
            guard !list.isEmpty else { return nil }
            let activeID: String?
            if let s = dict["active_display_id"] as? String {
                activeID = s
            } else if let n = dict["active_display_id"] as? NSNumber {
                activeID = n.stringValue
            } else {
                activeID = nil
            }
            return DisplaysState(displays: list, activeDisplayID: activeID)
        }
    }

    nonisolated struct PrivacyState: Equatable, Sendable {
        let supported: Bool
        let enabled: Bool
        let mode: String?
        let preset: String?

        static func decode(from dict: [String: Any]) -> PrivacyState {
            PrivacyState(
                supported: dict["supported"] as? Bool ?? false,
                enabled: dict["enabled"] as? Bool ?? ((dict["mode"] as? String).map { $0 != "off" && !$0.isEmpty } ?? false),
                mode: dict["mode"] as? String,
                preset: dict["preset"] as? String
            )
        }
    }

    nonisolated struct HostMuteState: Equatable, Sendable {
        let supported: Bool
        let muted: Bool

        static func decode(from dict: [String: Any]) -> HostMuteState {
            HostMuteState(
                supported: dict["supported"] as? Bool ?? false,
                muted: dict["muted"] as? Bool ?? false
            )
        }
    }

    nonisolated struct RemoteHostInfo: Equatable, Sendable {
        let version: String
        let os: String
        let arch: String
        let updateCapable: Bool
        let isOwnerSession: Bool
        let serviceInstalled: Bool

        static func decode(from dict: [String: Any]) -> RemoteHostInfo? {
            guard let version = dict["version"] as? String, !version.isEmpty else { return nil }
            return RemoteHostInfo(
                version: version,
                os: dict["os"] as? String ?? "",
                arch: dict["arch"] as? String ?? "",
                updateCapable: dict["updateCapable"] as? Bool ?? dict["update_capable"] as? Bool ?? false,
                isOwnerSession: dict["isOwnerSession"] as? Bool ?? dict["is_owner_session"] as? Bool ?? false,
                serviceInstalled: dict["serviceInstalled"] as? Bool ?? dict["service_installed"] as? Bool ?? false
            )
        }
    }

    nonisolated struct RemoteUpdateProgress: Equatable, Sendable {
        let stage: String
        let progressPct: Int?
        let targetVersion: String?
        let message: String?
        let error: String?

        static func decode(from dict: [String: Any]) -> RemoteUpdateProgress? {
            guard let stage = dict["stage"] as? String, !stage.isEmpty else { return nil }
            return RemoteUpdateProgress(
                stage: stage,
                progressPct: (dict["progressPct"] as? NSNumber ?? dict["progress_pct"] as? NSNumber)?.intValue,
                targetVersion: dict["targetVersion"] as? String ?? dict["target_version"] as? String,
                message: dict["message"] as? String,
                error: dict["error"] as? String
            )
        }
    }

    nonisolated struct DisplayConfig: Decodable, Equatable, Sendable {
        struct Preset: Decodable, Hashable, Sendable {
            let width, height: Int
            let label: String
            let isNative: Bool
            let isHidpi: Bool

            private enum CodingKeys: String, CodingKey {
                case width, height, label, isNative, isHidpi
            }

            init(width: Int, height: Int, label: String, isNative: Bool = false, isHidpi: Bool = false) {
                self.width = width
                self.height = height
                self.label = label
                self.isNative = isNative
                self.isHidpi = isHidpi
            }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                width = try c.decode(Int.self, forKey: .width)
                height = try c.decode(Int.self, forKey: .height)
                label = try c.decode(String.self, forKey: .label)
                isNative = try c.decodeIfPresent(Bool.self, forKey: .isNative) ?? false
                isHidpi = try c.decodeIfPresent(Bool.self, forKey: .isHidpi) ?? false
            }
        }

        struct Advisory: Decodable, Equatable, Sendable {
            let level: String
            let reason: String?
            let canEnableHevc: Bool
            let recommendedWidth: Int?
            let recommendedHeight: Int?

            private enum CodingKeys: String, CodingKey {
                case level, reason, canEnableHevc, recommendedWidth, recommendedHeight
            }

            init(
                level: String,
                reason: String? = nil,
                canEnableHevc: Bool = false,
                recommendedWidth: Int? = nil,
                recommendedHeight: Int? = nil
            ) {
                self.level = level
                self.reason = reason
                self.canEnableHevc = canEnableHevc
                self.recommendedWidth = recommendedWidth
                self.recommendedHeight = recommendedHeight
            }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                level = try c.decodeIfPresent(String.self, forKey: .level) ?? "optimal"
                reason = try c.decodeIfPresent(String.self, forKey: .reason)
                canEnableHevc = try c.decodeIfPresent(Bool.self, forKey: .canEnableHevc) ?? false
                recommendedWidth = try c.decodeIfPresent(Int.self, forKey: .recommendedWidth)
                recommendedHeight = try c.decodeIfPresent(Int.self, forKey: .recommendedHeight)
            }

            var localizedHint: String? {
                switch reason ?? level {
                case "suggest_hevc", "h264_suggest_hevc":
                    return "当前分辨率/帧率下启用 H.265 可显著降低带宽占用并提升清晰度。"
                case "above_sweet_spot", "hevc_over_budget":
                    return "当前分辨率与高帧率组合接近带宽上限，若偶发卡顿可切至推荐分辨率。"
                case "h264_no_hevc":
                    return "远端当前仅支持 H.264，高分辨率高刷下建议适当降低分辨率以稳帧。"
                default:
                    return nil
                }
            }
        }

        let width, height, fps, maxFps: Int
        let nativeWidth: Int?
        let nativeHeight: Int?
        let presets: [Preset]
        let codec: VideoCodec?
        let supportedCodecs: [VideoCodec]
        let clientSupportsHevc: Bool
        let clientSupportsAv1: Bool
        let advisory: Advisory?

        private enum CodingKeys: String, CodingKey {
            case width, height, nativeWidth, nativeHeight, fps, maxFps, presets
            case codec, supportedCodecs, clientSupportsHevc, clientSupportsAv1, advisory
        }

        init(
            width: Int,
            height: Int,
            fps: Int,
            maxFps: Int,
            presets: [Preset],
            codec: VideoCodec? = nil,
            supportedCodecs: [VideoCodec] = [.h264],
            clientSupportsHevc: Bool = true,
            clientSupportsAv1: Bool = VideoCodec.isHardwareAV1DecodeSupported,
            advisory: Advisory? = nil,
            nativeWidth: Int? = nil,
            nativeHeight: Int? = nil
        ) {
            self.width = width
            self.height = height
            self.nativeWidth = nativeWidth
            self.nativeHeight = nativeHeight
            self.fps = fps
            self.maxFps = maxFps
            self.presets = presets
            self.codec = codec
            self.supportedCodecs = supportedCodecs
            self.clientSupportsHevc = clientSupportsHevc
            self.clientSupportsAv1 = clientSupportsAv1
            self.advisory = advisory
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            width = try c.decode(Int.self, forKey: .width)
            height = try c.decode(Int.self, forKey: .height)
            nativeWidth = try c.decodeIfPresent(Int.self, forKey: .nativeWidth)
            nativeHeight = try c.decodeIfPresent(Int.self, forKey: .nativeHeight)
            fps = try c.decode(Int.self, forKey: .fps)
            maxFps = try c.decode(Int.self, forKey: .maxFps)
            presets = try c.decodeIfPresent([Preset].self, forKey: .presets) ?? []
            let parsedCodec = VideoCodec.parse(try c.decodeIfPresent(String.self, forKey: .codec))
            codec = parsedCodec
            var supported = (try c.decodeIfPresent([String].self, forKey: .supportedCodecs) ?? [])
                .compactMap(VideoCodec.parse)
            if !supported.contains(.h264) {
                supported.append(.h264)
            }
            if parsedCodec == .hevc, !supported.contains(.hevc) {
                supported.insert(.hevc, at: 0)
            }
            if parsedCodec == .av1, !supported.contains(.av1) {
                supported.insert(.av1, at: 0)
            }
            supportedCodecs = supported
            clientSupportsHevc = try c.decodeIfPresent(Bool.self, forKey: .clientSupportsHevc) ?? true
            clientSupportsAv1 = try c.decodeIfPresent(Bool.self, forKey: .clientSupportsAv1)
                ?? VideoCodec.isHardwareAV1DecodeSupported
            advisory = try c.decodeIfPresent(Advisory.self, forKey: .advisory)
        }

        /// 当前主被控两端是否均支持 H.265 (HEVC)。
        var canUseHevc: Bool {
            clientSupportsHevc && supportedCodecs.contains(.hevc)
        }

        /// 当前主被控两端是否均支持 AV1（本机按 VideoToolbox 硬解能力 fail-closed）。
        var canUseAv1: Bool {
            clientSupportsAv1 && supportedCodecs.contains(.av1)
        }

        /// 当前会话允许双向协商切换的编码器列表（按效率从高到低排列）。
        var selectableCodecs: [VideoCodec] {
            var list: [VideoCodec] = []
            if canUseAv1 { list.append(.av1) }
            if canUseHevc { list.append(.hevc) }
            list.append(.h264)
            return list
        }

        func updating(width: Int? = nil, height: Int? = nil, fps: Int? = nil, codec: VideoCodec? = nil) -> DisplayConfig {
            DisplayConfig(
                width: width ?? self.width,
                height: height ?? self.height,
                fps: fps ?? self.fps,
                maxFps: maxFps,
                presets: presets,
                codec: codec ?? self.codec,
                supportedCodecs: supportedCodecs,
                clientSupportsHevc: clientSupportsHevc,
                clientSupportsAv1: clientSupportsAv1,
                advisory: advisory,
                nativeWidth: nativeWidth,
                nativeHeight: nativeHeight
            )
        }

        static func decode(
            from dict: [String: Any],
            clientSupportsAv1: Bool = VideoCodec.isHardwareAV1DecodeSupported
        ) -> DisplayConfig? {
            var enriched = dict
            if enriched["client_supports_av1"] == nil {
                enriched["client_supports_av1"] = clientSupportsAv1
            } else if !clientSupportsAv1 {
                // 本机无硬解时严格 fail-closed
                enriched["client_supports_av1"] = false
            }
            guard let bytes = try? JSONSerialization.data(withJSONObject: enriched) else { return nil }
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try? decoder.decode(DisplayConfig.self, from: bytes)
        }
    }

    private(set) var hud: [String: Any]?
    private var pollTask: Task<Void, Never>?
    private var negotiatedAt: Date?
    private var didAutoAlignCodec = false
    private var userSelectedCodec: VideoCodec?

    /// 当前生效的视频编码（收到 display_config 后确定）。
    var activeCodec: VideoCodec? { display?.codec }

    var isConnected: Bool {
        guard case .negotiated = state else { return false }
        return sessionID != nil
    }

    // MARK: - 生命周期

    /// 收养已由运行时(信令)建立的会话,接管轮询与输入。
    func adopt(sessionID id: UInt64, watchOnly: Bool, deviceID: String? = nil, toolsOnly: Bool = false) {
        close()
        peerWatchOnly = watchOnly
        localWatchOnly = watchOnly
        mediaPaused = toolsOnly
        stillRefinementEnabled = PrefsStore.shared.stillRefinementEnabled
        targetDeviceID = deviceID
        sessionID = id
        state = .connecting(phase: "endpoint_creating")
        if toolsOnly {
            sendCommand(["type": "set_media_paused", "paused": true])
        }
        startPolling()
    }

    /// 直连打开会话(LAN 或手动输入地址)。
    func open(
        connectAddr: String,
        password: String?,
        watchOnly: Bool,
        deviceID: String? = nil,
        toolsOnly: Bool = false
    ) {
        close()
        do {
            try AppLockStore.shared.requireUnlocked()
            try RuntimeService.validateProxyAndConnectionMode(PrefsStore.shared.connectionMode)
        } catch {
            let uiErr = (error as? AuthService.AuthError)?.uiError ?? RCUiErrorCodec.fromError(error)
            endedUiError = uiErr
            endedRecoverable = false
            state = .ended(reason: uiErr.message.isEmpty ? uiErr.title : uiErr.message)
            return
        }
        peerWatchOnly = watchOnly
        localWatchOnly = watchOnly
        mediaPaused = toolsOnly
        stillRefinementEnabled = PrefsStore.shared.stillRefinementEnabled
        targetDeviceID = deviceID
        var payload: [String: Any] = [
            "connect_addr": connectAddr,
            "watch_only": watchOnly,
            "fps": PrefsStore.shared.effectiveFps,
            "bitrate_bps": PrefsStore.shared.effectiveBitrateBps,
            "tools_only": toolsOnly,
        ]
        if let password, !password.isEmpty {
            payload["password"] = password
        }
        guard let raw = Self.callSync(rc_session_open, payload),
              let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let uiErr = CoreClient.resolveUiError(code: RCErrorCodes.serviceRuntimeNotInitialized, detail: "核心库无响应")
            endedUiError = uiErr
            endedRecoverable = false
            state = .ended(reason: uiErr.message)
            return
        }
        if let uiErr = RCUiErrorCodec.extractEnvelopeError(from: obj, fallbackCode: RCErrorCodes.sessionHandshakeFailed) {
            endedUiError = uiErr
            endedRecoverable = false
            state = .ended(reason: uiErr.message.isEmpty ? uiErr.title : uiErr.message)
            return
        }
        guard let id = (obj["session_id"] as? NSNumber)?.uint64Value else {
            let uiErr = CoreClient.resolveUiError(code: RCErrorCodes.validationInvalidJson, detail: "响应格式错误")
            endedUiError = uiErr
            endedRecoverable = false
            state = .ended(reason: uiErr.message)
            return
        }
        sessionID = id
        state = .connecting(phase: "endpoint_creating")
        if toolsOnly {
            sendCommand(["type": "set_media_paused", "paused": true])
        }
        startPolling()
    }

    /// 主动结束会话（若开启了「远程结束后自动锁屏」则在断开前先下发锁屏指令）。
    func endUserSession() {
        if PrefsStore.shared.lockRemoteOnDisconnect, isConnected, !effectiveWatchOnly {
            sendCommand(["type": "lock_remote_screen"])
        }
        close()
    }

    func close() {
        let closingSessionID = sessionID
        releasePressedInput()
        setPlaybackActive(false)
        pollTask?.cancel()
        pollTask = nil
        ToolService.shared.stop(clearSessionID: closingSessionID)
        if let id = closingSessionID, let payload = Self.jsonString(["session_id": id]) {
            inputQueue.async { _ = Self.callSyncJSON(rc_session_close, payload) }
        }
        sessionID = nil
        targetDeviceID = nil
        state = .idle
        peerWatchOnly = false
        localWatchOnly = false
        mediaPaused = false
        stillRefinementEnabled = PrefsStore.shared.stillRefinementEnabled
        mutuallyAuthenticated = nil
        peerCertFingerprint = nil
        audioMuted = false
        clearClipboard()
        display = nil
        displaysState = nil
        privacyState = nil
        hostMuteState = nil
        hostInfo = nil
        remoteUpdateStatus = nil
        hostScreenLocked = false
        hostCaptureSuspended = false
        mouseMode = "smart"
        terminalLockState = nil
        lastTerminalUnlockResult = nil
        virtualDisplayError = nil
        toolPermissions = .allAllowed
        endedUiError = nil
        endedRecoverable = false
        lastToolDeniedError = nil
        hud = nil
        negotiatedAt = nil
        didAutoAlignCodec = false
        userSelectedCodec = nil
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

        if let permsDict = obj["tool_permissions"] as? [String: Any],
           let perms = ToolPermissions.decode(from: permsDict) {
            applyToolPermissions(perms)
        }
        for update in updates {
            applyUpdate(update)
        }
        reconcilePreferredCodecIfNeeded()
        if obj["running"] as? Bool == false, case .ended = state {
            // 已结束状态保持不变
        } else if obj["running"] as? Bool == false {
            let uiErr = CoreClient.resolveUiError(code: RCErrorCodes.sessionDisconnected, detail: "会话线程退出")
            endedUiError = uiErr
            state = .ended(reason: uiErr.message)
        }
        if case .ended = state {
            setPlaybackActive(false)
            ToolService.shared.stop(clearSessionID: nil)
            pollTask?.cancel()
        }
        if clipboardEnabled {
            if !isConnected || effectiveWatchOnly { clearClipboard() }
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

    var negotiatedFps: Int {
        if case .negotiated(_, _, let fps, _, _) = state { return fps }
        return 0
    }

    private func applyUpdate(_ update: [String: Any]) {
        guard let kind = update["kind"] as? String else { return }
        let data = update["data"] as? [String: Any]
        switch kind {
        case "connecting":
            state = .connecting(phase: data?["phase"] as? String ?? "")
        case "negotiated":
            endedRecoverable = false
            endedUiError = nil
            if data?["watch_only"] as? Bool == true {
                peerWatchOnly = true
                localWatchOnly = true
            }
            if mediaPaused {
                sendCommand(["type": "set_media_paused", "paused": true])
                setPlaybackActive(false)
            } else {
                if !InteractionPrefs.shared.audioEnabledDefault && !audioMuted {
                    audioMuted = true
                    sendCommand(["type": "set_audio_muted", "muted": true])
                }
                setPlaybackActive(!audioMuted)
            }
            if InteractionPrefs.shared.clipboardEnabledDefault && !effectiveWatchOnly && !clipboardEnabled {
                setClipboardEnabled(true)
            }
            if !stillRefinementEnabled {
                sendCommand(["type": "set_still_refinement_enabled", "enabled": false])
            }
            mutuallyAuthenticated = data?["mtls_active"] as? Bool
            peerCertFingerprint = data?["peer_cert_fingerprint"] as? String
            if negotiatedAt == nil {
                negotiatedAt = .now
            }
            state = .negotiated(
                width: data?["width"] as? Int ?? 0,
                height: data?["height"] as? Int ?? 0,
                fps: data?["fps"] as? Int ?? 0,
                backend: data?["backend"] as? String ?? "",
                transport: data?["transport"] as? String ?? ""
            )
            if !effectiveWatchOnly, let id = sessionID {
                ToolService.shared.start(sessionID: id)
                PortMapStore.shared.restorePersistedRulesIfNeeded(sessionID: id, deviceID: targetDeviceID)
            }
            // 核心库握手后默认自动尝试切 HEVC；若用户显式偏好 H.264 兼容，立即覆盖回 H.264。
            let desiredCodec = userSelectedCodec ?? PrefsStore.shared.preferredCodec
            if !effectiveWatchOnly, !mediaPaused, !didAutoAlignCodec, desiredCodec == .h264 {
                didAutoAlignCodec = true
                sendCommand(["type": "set_codec", "codec": VideoCodec.h264.rawValue])
            }
        case "hud":
            hud = data
        case "display_config":
            if let data, let decoded = DisplayConfig.decode(from: data) {
                display = decoded
            }
        case "displays_state":
            if let data, let decoded = DisplaysState.decode(from: data) {
                displaysState = decoded
                virtualDisplayError = nil
            }
        case "virtual_display_error":
            virtualDisplayError = data?["message"] as? String ?? data?["reason"] as? String
        case "privacy_state":
            if let data {
                privacyState = PrivacyState.decode(from: data)
            }
        case "host_mute_state":
            if let data {
                hostMuteState = HostMuteState.decode(from: data)
            }
        case "host_version":
            if let data, let decoded = RemoteHostInfo.decode(from: data) {
                hostInfo = decoded
            }
        case "remote_update_status":
            if let data, let decoded = RemoteUpdateProgress.decode(from: data) {
                remoteUpdateStatus = decoded
            }
        case "host_screen_state":
            hostScreenLocked = data?["locked"] as? Bool ?? false
            hostCaptureSuspended = data?["capture_suspended"] as? Bool ?? false
        case "mouse_mode_state":
            if let m = data?["mode"] as? String, !m.isEmpty {
                mouseMode = m
            }
        case "reconnecting":
            let att = (data?["attempt"] as? NSNumber)?.intValue ?? 1
            let maxAtt = (data?["max_attempts"] as? NSNumber)?.intValue ?? 8
            let reason = data?["reason"] as? String ?? "连接中断，正在重连…"
            state = .reconnecting(attempt: att, maxAttempts: maxAtt, reason: reason)
        case "media_state":
            if let paused = data?["paused"] as? Bool {
                mediaPaused = paused
                if paused {
                    setPlaybackActive(false)
                } else if !audioMuted {
                    setPlaybackActive(true)
                }
            }
        case "media_resumed":
            mediaPaused = false
            let w = (data?["width"] as? NSNumber)?.intValue ?? width
            let h = (data?["height"] as? NSNumber)?.intValue ?? height
            let fps = (data?["fps"] as? NSNumber)?.intValue ?? negotiatedFps
            let backend = data?["backend"] as? String ?? ""
            let currentTransport: String = {
                if case .negotiated(_, _, _, _, let t) = state { return t }
                return ""
            }()
            state = .negotiated(width: w, height: h, fps: fps, backend: backend, transport: currentTransport)
            if !audioMuted { setPlaybackActive(true) }
        case "terminal_lock_state":
            if let data {
                terminalLockState = TerminalLockState.decode(from: data)
            }
        case "terminal_unlock_result":
            if let data {
                let result = TerminalUnlockResult.decode(from: data)
                lastTerminalUnlockResult = result
                if result.ok, let prev = terminalLockState {
                    terminalLockState = TerminalLockState(
                        required: prev.required,
                        unlocked: true,
                        username: prev.username,
                        retryAfterSecs: 0
                    )
                }
            }
        case "wallpaper":
            if let devID = targetDeviceID,
               AuthService.shared.previews[devID] == nil,
               let dataURL = data?["data_url"] as? String {
                Task.detached(priority: .utility) {
                    guard let imageBytes = Self.decodeDataURLImage(dataURL),
                          let image = UIImage(data: imageBytes) else { return }
                    await MainActor.run {
                        if AuthService.shared.previews[devID] == nil {
                            AuthService.shared.rememberPreview(image, deviceID: devID)
                        }
                    }
                }
            }
        case "session_switching":
            endedRecoverable = true
            state = .switching(reason: data?["reason"] as? String ?? "远端正在切换系统桌面，自动重连中…")
        case "tool_permissions_updated":
            if let data, let perms = ToolPermissions.decode(from: data) {
                applyToolPermissions(perms)
            }
        case "tool_permission_denied":
            let uiErr = RCUiErrorCodec.decode(from: data?["ui_error"] as? [String: Any])
                ?? CoreClient.resolveUiError(code: RCErrorCodes.toolForbidden)
            lastToolDeniedError = uiErr
            if let channel = (data?["channel"] as? NSNumber)?.intValue, channel == 1 {
                ToolService.shared.handleFileTransferRevoked(uiError: uiErr)
            }
            RCErrorCenter.shared.present(uiErr)
        case "ended":
            let rawReason = data?["reason"] as? String ?? ""
            let recoverableFlag = data?["recoverable"] as? Bool ?? false
            let uiErr = RCUiErrorCodec.decode(from: data?["ui_error"] as? [String: Any])
                ?? CoreClient.resolveUiError(
                    code: RCErrorCodes.sessionDisconnected,
                    detail: rawReason.isEmpty ? nil : rawReason
                )
            endedUiError = uiErr
            // 鉴权/证书/权限拒绝一律不可盲目自动重连（遵守 §4.1 不误降级/不死循环红线）
            let nonRecoverablePrefix = uiErr.code.hasPrefix("auth.")
                || uiErr.code.hasPrefix("pki.")
                || uiErr.code == RCErrorCodes.proxyConfigConflict
                || uiErr.code == RCErrorCodes.accountDisabled
            endedRecoverable = recoverableFlag && !nonRecoverablePrefix
            let displayReason = uiErr.message.isEmpty ? (rawReason.isEmpty ? uiErr.title : rawReason) : uiErr.message
            state = .ended(reason: displayReason)
        default:
            break
        }
    }

    func applyToolPermissions(_ perms: ToolPermissions) {
        let previous = toolPermissions
        toolPermissions = perms
        if previous.allowFileTransfer && !perms.allowFileTransfer {
            ToolService.shared.handleFileTransferRevoked()
        }
    }

    nonisolated static func queryToolPermissions(sessionID: UInt64) -> ToolPermissions? {
        guard let raw = CoreClient.withRustString(rc_session_tool_permissions_json(sessionID)),
              let data = raw.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              dict["error"] == nil else {
            return nil
        }
        return ToolPermissions.decode(from: dict)
    }

    nonisolated static func decodeDataURLImage(_ dataURL: String) -> Data? {
        guard dataURL.hasPrefix("data:image/"),
              let commaIndex = dataURL.firstIndex(of: ",") else { return nil }
        let meta = dataURL[..<commaIndex]
        guard meta.contains(";base64") else { return nil }
        let base64Body = String(dataURL[dataURL.index(after: commaIndex)...])
        guard base64Body.utf8.count <= 10_000_000 else { return nil }
        return Data(base64Encoded: base64Body, options: [.ignoreUnknownCharacters])
    }

    private let inputQueue = DispatchQueue(label: "rabbitcontrol.session.input", qos: .userInteractive)
    private var pressedButtons = Set<String>()
    private var pressedKeys = Set<UInt16>()
    private var pendingClickReleases: [String: DispatchWorkItem] = [:]
    private(set) var isLeftMouseHeld = false
    /// 用户通过「拖拽锁定」按钮显式锁定的左键常驻按下态（区别于单击瞬态 35ms 按下）。
    private(set) var isDragLocked = false
    /// 当前是否处于持续按住左键态（包含「拖拽锁定」或手指按住物理「左键」按钮，排除 35ms 瞬时单击脉冲）。
    var isSustainedLeftHold: Bool {
        isLeftMouseHeld && pendingClickReleases["left"] == nil
    }
    /// 会话级修饰键锁存状态（单击 sticky 配合下一次键鼠操作生效，双击 locked 常驻保持）。
    private(set) var modifierLatch = ModifierLatch()
    /// 单元测试专用的输入事件旁路捕获钩子（非 nil 时不经底层 FFI 直接记录序列化前的输入字典）。
    var inputTestSink: (([String: Any]) -> Void)?

    private var canSendInput: Bool {
        if inputTestSink != nil {
            return !effectiveWatchOnly && RCErrorCenter.shared.modal == nil && !AppLockStore.shared.isLocked
        }
        return isConnected && !effectiveWatchOnly && RCErrorCenter.shared.modal == nil && !AppLockStore.shared.isLocked && sessionID != nil
    }

    func releasePressedInput() {
        for (_, work) in pendingClickReleases {
            work.cancel()
        }
        pendingClickReleases.removeAll()
        modifierLatch.clearAll()
        for button in pressedButtons {
            sendRawInputAllowingRelease(["kind": "mouse_button", "button": button, "pressed": false])
        }
        for key in pressedKeys {
            sendRawInputAllowingRelease(["kind": "key", "scancode": key, "pressed": false, "modifiers": UInt8(0)])
        }
        pressedButtons.removeAll()
        pressedKeys.removeAll()
        if isDragLocked { isDragLocked = false }
        if isLeftMouseHeld { isLeftMouseHeld = false }
    }

    // MARK: - 输入与指令

    /// 远端是否为 Windows / Linux 键位体系（优先采用实时握手上报的 hostInfo.os，其次参考设备类型）。
    func prefersPCShortcuts(deviceKind: Device.Kind? = nil) -> Bool {
        if let os = hostInfo?.os.lowercased(), !os.isEmpty {
            if os.contains("mac") || os.contains("darwin") { return false }
            if os.contains("win") || os.contains("linux") { return true }
        }
        return deviceKind == .windows
    }

    /// 切换修饰键锁存状态（空闲 → 单次 sticky → 双击常驻 locked → 释放），并同步远端修饰键按下/抬起。
    func toggleModifier(_ code: UInt16, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard canSendInput || modifierLatch.mode(for: code) != nil else { return }
        modifierLatch.toggle(code, now: now)
        if modifierLatch.mode(for: code) != nil {
            if !pressedKeys.contains(code) {
                sendKey(scancode: code, pressed: true)
            }
        } else if pressedKeys.contains(code) {
            sendKey(scancode: code, pressed: false)
        }
    }

    /// 指针点击或拖拽释放完成后，自动弹起单次（sticky）修饰键，保留常驻锁定（locked）修饰键。
    func consumeStickyModifiersAfterPointerAction() {
        guard !modifierLatch.isEmpty else { return }
        let activeBefore = modifierLatch.consumeForKeyPress()
        let keepLocked = Set(modifierLatch.activeCodes)
        for code in activeBefore.reversed() where !keepLocked.contains(code) {
            if pressedKeys.remove(code) != nil {
                sendRawInputAllowingRelease(["kind": "key", "scancode": code, "pressed": false, "modifiers": UInt8(0)])
            }
        }
    }

    /// 若指定鼠标按键仍有未到期的单击释放定时器，立即补发抬起并取消定时器，防止后续拖拽或快速双击被旧定时器打断。
    private func flushPendingClickRelease(for button: String) {
        guard let pending = pendingClickReleases.removeValue(forKey: button) else { return }
        pending.cancel()
        if pressedButtons.remove(button) != nil {
            sendRawInputAllowingRelease(["kind": "mouse_button", "button": button, "pressed": false])
        }
        if button == "left" && !isDragLocked {
            isLeftMouseHeld = false
        }
    }

    /// 发送指针移动(视图坐标按远端画面归一化到 0...65535)。
    func sendMouseMove(nx: Double, ny: Double) {
        sendInput([
            "kind": "mouse_move",
            "x": UInt16(max(0, min(1, nx)) * 65535),
            "y": UInt16(max(0, min(1, ny)) * 65535),
        ])
    }

    func sendMouseButton(button: String, pressed: Bool) {
        if pressed {
            guard canSendInput else { return }
            flushPendingClickRelease(for: button)
            guard !pressedButtons.contains(button) else {
                if button == "left" && !isLeftMouseHeld { isLeftMouseHeld = true }
                return
            }
            pressedButtons.insert(button)
            if button == "left" && !isLeftMouseHeld {
                isLeftMouseHeld = true
            }
            sendInput(["kind": "mouse_button", "button": button, "pressed": true])
        } else {
            pendingClickReleases.removeValue(forKey: button)?.cancel()
            if button == "left" {
                if isDragLocked { isDragLocked = false }
                if isLeftMouseHeld { isLeftMouseHeld = false }
            }
            guard pressedButtons.remove(button) != nil else { return }
            sendRawInputAllowingRelease(["kind": "mouse_button", "button": button, "pressed": false])
            consumeStickyModifiersAfterPointerAction()
        }
    }

    func clickMouse(_ button: String) {
        guard canSendInput else { return }
        if button == "left", isDragLocked {
            isDragLocked = false
            sendMouseButton(button: "left", pressed: false)
            return
        }
        flushPendingClickRelease(for: button)
        pressedButtons.insert(button)
        if button == "left" && !isLeftMouseHeld {
            isLeftMouseHeld = true
        }
        sendInput(["kind": "mouse_button", "button": button, "pressed": true])

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingClickReleases.removeValue(forKey: button)
            guard self.pressedButtons.remove(button) != nil else { return }
            if button == "left" && !self.isDragLocked && self.isLeftMouseHeld {
                self.isLeftMouseHeld = false
            }
            self.sendRawInputAllowingRelease(["kind": "mouse_button", "button": button, "pressed": false])
            self.consumeStickyModifiersAfterPointerAction()
        }
        pendingClickReleases[button] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.035, execute: work)
    }

    func toggleLeftMouseHold() {
        guard canSendInput else { return }
        if isDragLocked || isLeftMouseHeld {
            isDragLocked = false
            sendMouseButton(button: "left", pressed: false)
        } else {
            isDragLocked = true
            sendMouseButton(button: "left", pressed: true)
        }
    }

    func sendWheel(delta: Int, horizontal: Bool = false) {
        guard delta != 0 else { return }
        sendInput(["kind": "mouse_wheel", "delta": delta, "horizontal": horizontal])
    }

    func sendKey(scancode: UInt16, pressed: Bool, modifiers: UInt8 = 0) {
        if pressed {
            guard canSendInput else { return }
            pressedKeys.insert(scancode)
            sendInput(["kind": "key", "scancode": scancode, "pressed": true, "modifiers": modifiers])
        } else {
            pressedKeys.remove(scancode)
            sendRawInputAllowingRelease(["kind": "key", "scancode": scancode, "pressed": false, "modifiers": modifiers])
        }
    }

    private func sendInput(_ fields: [String: Any]) {
        guard canSendInput else { return }
        if let sink = inputTestSink {
            sink(fields)
            return
        }
        guard let id = sessionID else { return }
        var payload = fields
        payload["session_id"] = id
        guard let json = Self.jsonString(payload) else { return }
        inputQueue.async {
            _ = Self.callSyncJSON(rc_session_input, json)
        }
    }

    /// 释放型输入通道：即使刚切入观看模式、弹窗或本地锁屏，也确保已按下的远端按键/鼠标键可靠抬起不卡死。
    private func sendRawInputAllowingRelease(_ fields: [String: Any]) {
        if let sink = inputTestSink {
            sink(fields)
            return
        }
        guard isConnected, let id = sessionID else { return }
        var payload = fields
        payload["session_id"] = id
        guard let json = Self.jsonString(payload) else { return }
        inputQueue.async {
            _ = Self.callSyncJSON(rc_session_input, json)
        }
    }

    func tapKey(_ key: UInt16, modifiers: [UInt16] = []) {
        guard canSendInput else { return }
        let latched = modifierLatch.consumeForKeyPress()
        let keepLocked = Set(modifierLatch.activeCodes)
        var combined = latched
        for code in modifiers where !combined.contains(code) {
            combined.append(code)
        }
        for code in combined where !pressedKeys.contains(code) {
            sendKey(scancode: code, pressed: true)
        }
        sendKey(scancode: key, pressed: true)
        sendKey(scancode: key, pressed: false)
        for code in combined.reversed() where !keepLocked.contains(code) {
            sendKey(scancode: code, pressed: false)
        }
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

    /// 切网后向在途会话下发 `probe_now` 快速活性探针。
    func probeNow() {
        guard sessionID != nil else { return }
        sendCommand(["type": "probe_now"])
    }

    /// 暂停或恢复视频媒体流（`SessionCommand::SetMediaPaused`）。
    func setMediaPaused(_ paused: Bool) {
        guard sessionID != nil else { return }
        mediaPaused = paused
        sendCommand(["type": "set_media_paused", "paused": paused])
        if paused {
            setPlaybackActive(false)
        } else if isConnected {
            if !audioMuted { setPlaybackActive(true) }
            _ = requestIDR()
        }
    }

    /// 纯工具会话原地热升级为完整远程桌面（不断开当前会话与在途工具）。
    func upgradeToDesktop() {
        setMediaPaused(false)
    }

    /// 会话内动态切换观看模式（只读不注入输入，对端未强制只读时可随时恢复控制）。
    func setWatchOnly(_ enabled: Bool) {
        guard !peerWatchOnly else { return }
        localWatchOnly = enabled
        if enabled {
            releasePressedInput()
            if clipboardEnabled { setClipboardEnabled(false) }
        } else if isConnected, let id = sessionID {
            ToolService.shared.start(sessionID: id)
        }
    }

    /// 动态开关静止画面无损文字锐化补帧（`SessionCommand::SetStillRefinementEnabled`）。
    func setStillRefinementEnabled(_ enabled: Bool) {
        stillRefinementEnabled = enabled
        PrefsStore.shared.stillRefinementEnabled = enabled
        guard isConnected, !effectiveWatchOnly else { return }
        sendCommand(["type": "set_still_refinement_enabled", "enabled": enabled])
    }

    /// 发送扩展显示/隐私/更新控制指令并校验底层 FFI 响应。
    func sendExtendedControlCommand(_ command: [String: Any]) async -> RCUiError? {
        guard let id = sessionID, isConnected, !effectiveWatchOnly else {
            return CoreClient.resolveUiError(code: RCErrorCodes.sessionDisconnected)
        }
        let payload: [String: Any] = ["session_id": id, "command": command]
        guard let json = Self.jsonString(payload) else {
            return CoreClient.resolveUiError(code: RCErrorCodes.validationInvalidJson)
        }
        let raw = await Task.detached(priority: .userInitiated) {
            Self.callSyncJSON(rc_session_command, json)
        }.value
        guard let raw, let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return CoreClient.resolveUiError(code: RCErrorCodes.serviceRuntimeNotInitialized)
        }
        if obj["ok"] as? Bool == true {
            return nil
        }
        if let errStr = obj["error"] as? String, errStr.contains("unknown variant") {
            return CoreClient.resolveUiError(
                code: RCErrorCodes.validationInvalidConfig,
                detail: "当前预编译核心库尚未开放此控制指令，升级最新 xcframework 后自动生效。"
            )
        }
        return RCUiErrorCodec.extractEnvelopeError(from: obj)
    }

    func switchRemoteDisplay(id: String) async -> RCUiError? {
        let idVal: Any = UInt32(id) ?? id
        if let err = await sendExtendedControlCommand(["type": "switch_display", "display_id": idVal]) {
            return err
        }
        if let current = displaysState {
            displaysState = DisplaysState(displays: current.displays, activeDisplayID: id)
        }
        return nil
    }

    func createRemoteVirtualDisplay(width: Int = 1920, height: Int = 1080, hidpi: Bool = true) async -> RCUiError? {
        await sendExtendedControlCommand([
            "type": "create_virtual_display",
            "width": width,
            "height": height,
            "hidpi": hidpi,
        ])
    }

    func removeRemoteVirtualDisplay(id: String) async -> RCUiError? {
        let idVal: Any = UInt32(id) ?? id
        return await sendExtendedControlCommand(["type": "remove_virtual_display", "display_id": idVal])
    }

    func setRemotePrivacyMode(_ mode: String) async -> RCUiError? {
        if let err = await sendExtendedControlCommand(["type": "set_privacy_mode", "mode": mode]) {
            return err
        }
        privacyState = PrivacyState(supported: true, enabled: mode != "off", mode: mode, preset: privacyState?.preset)
        return nil
    }

    func setRemoteHostMute(_ muted: Bool) async -> RCUiError? {
        if let err = await sendExtendedControlCommand(["type": "set_host_mute", "muted": muted]) {
            return err
        }
        hostMuteState = HostMuteState(supported: true, muted: muted)
        return nil
    }

    func triggerRemoteHostUpdate() async -> RCUiError? {
        await sendExtendedControlCommand(["type": "trigger_remote_update"])
    }

    func cancelRemoteHostUpdate() async -> RCUiError? {
        await sendExtendedControlCommand(["type": "cancel_remote_update"])
    }

    /// 通过重申当前视频流参数或目标码率触发远端编码器重配并立即下发关键帧(恢复花屏/前后台切换卡帧)。
    @discardableResult
    func requestIDR() -> Bool {
        guard isConnected, !effectiveWatchOnly else { return false }
        if let display, display.width > 0, display.height > 0 {
            let targetFps = display.fps > 0 ? display.fps : PrefsStore.shared.effectiveFps
            sendCommand([
                "type": "set_stream_params",
                "width": display.width,
                "height": display.height,
                "fps": targetFps,
            ])
            return true
        }
        if width > 0, height > 0 {
            let targetFps = negotiatedFps > 0 ? negotiatedFps : PrefsStore.shared.effectiveFps
            sendCommand([
                "type": "set_stream_params",
                "width": width,
                "height": height,
                "fps": targetFps,
            ])
            return true
        }
        sendCommand(["type": "set_bitrate", "bps": PrefsStore.shared.effectiveBitrateBps])
        return true
    }

    func setBitrate(_ bps: Int) {
        guard isConnected, !effectiveWatchOnly else { return }
        sendCommand(["type": "set_bitrate", "bps": bps])
    }

    func lockRemoteScreen() {
        guard isConnected, !effectiveWatchOnly else { return }
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
        guard isConnected, !effectiveWatchOnly, let display else { return }
        let targetW = width > 0 ? width : display.width
        let targetH = height > 0 ? height : display.height
        let targetFps = fps > 0 ? fps : display.fps
        let resValid = (width == 0 && height == 0)
            || (width == display.width && height == display.height)
            || display.presets.contains { $0.width == width && $0.height == height }
        guard resValid, (0...max(0, display.maxFps)).contains(fps) else { return }
        sendCommand(["type": "set_stream_params", "width": targetW, "height": targetH, "fps": targetFps])
        // 乐观更新本地选中状态，并保持音频通道处于激活/非静音态
        self.display = display.updating(width: targetW, height: targetH, fps: targetFps)
        if !audioMuted {
            setPlaybackActive(true)
            sendCommand(["type": "set_audio_muted", "muted": false])
        }
    }

    func setCodec(_ codec: VideoCodec) {
        guard isConnected, !effectiveWatchOnly, let display else { return }
        if codec == .av1, !display.canUseAv1 { return }
        if codec == .hevc, !display.canUseHevc { return }
        userSelectedCodec = codec
        didAutoAlignCodec = true
        guard display.codec != codec else { return }
        sendCommand(["type": "set_codec", "codec": codec.rawValue])
        self.display = display.updating(codec: codec)
        if !audioMuted {
            setPlaybackActive(true)
            sendCommand(["type": "set_audio_muted", "muted": false])
        }
    }

    nonisolated enum CodecReconciliation: Equatable, Sendable {
        case none
        case markAligned
        case send(VideoCodec)
    }

    nonisolated static func evaluateCodecReconciliation(
        display: DisplayConfig,
        preferred: VideoCodec,
        userSelected: VideoCodec?,
        didAutoAlign: Bool,
        negotiatedElapsed: TimeInterval
    ) -> CodecReconciliation {
        guard !didAutoAlign else { return .none }
        let desired = userSelected ?? preferred
        let actual = display.codec ?? .h264
        switch desired {
        case .av1:
            if display.canUseAv1 {
                if actual == .av1 { return .markAligned }
                guard negotiatedElapsed >= 1.0 else { return .none }
                return .send(.av1)
            }
            // 本机或远端不支持 AV1 时 fail-closed 降级为 H.265 / H.264
            guard display.canUseHevc else { return .markAligned }
            if actual == .hevc { return .markAligned }
            guard negotiatedElapsed >= 1.0 else { return .none }
            return .send(.hevc)
        case .hevc:
            if actual == .av1 && userSelected == nil { return .markAligned }
            guard display.canUseHevc else { return .markAligned }
            if actual == .hevc { return .markAligned }
            if actual == .av1 { return .send(.hevc) }
            // 核心库在握手完成时已自动下发一次 SetCodec("hevc")；预留 1s 等待流切换，
            // 仅在被控端因首帧分辨率重配竞态跳过该请求、仍停留在 H.264 时补发一次兜底。
            guard negotiatedElapsed >= 1.0 else { return .none }
            return .send(.hevc)
        case .h264:
            if actual == .h264 && !display.canUseHevc && !display.canUseAv1 { return .markAligned }
            if actual == .hevc || actual == .av1 { return .send(.h264) }
            return .none
        }
    }

    private func reconcilePreferredCodecIfNeeded(now: Date = .now) {
        guard isConnected, !effectiveWatchOnly, !mediaPaused, let display else { return }
        let elapsed = negotiatedAt.map { now.timeIntervalSince($0) } ?? 0
        switch Self.evaluateCodecReconciliation(
            display: display,
            preferred: PrefsStore.shared.preferredCodec,
            userSelected: userSelectedCodec,
            didAutoAlign: didAutoAlignCodec,
            negotiatedElapsed: elapsed
        ) {
        case .none:
            break
        case .markAligned:
            didAutoAlignCodec = true
        case .send(let target):
            didAutoAlignCodec = true
            sendCommand(["type": "set_codec", "codec": target.rawValue])
            self.display = display.updating(codec: target)
            if !audioMuted {
                setPlaybackActive(true)
                sendCommand(["type": "set_audio_muted", "muted": false])
            }
        }
    }

    private func clearClipboard() {
        clipboardEnabled = false
        receivedText = nil
        rc_apple_clipboard_reset()
    }

    func setClipboardEnabled(_ enabled: Bool) {
        guard isConnected, !effectiveWatchOnly else { return }
        clearClipboard()
        clipboardEnabled = enabled
        sendCommand(["type": "set_clipboard_enabled", "enabled": enabled])
    }

    func sendClipboard(_ text: String) -> Bool {
        guard isConnected, !effectiveWatchOnly, clipboardEnabled, text.utf8.count <= 65535,
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
