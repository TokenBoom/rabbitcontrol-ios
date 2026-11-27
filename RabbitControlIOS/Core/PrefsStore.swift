import CoreMedia
import Foundation
import VideoToolbox

/// 视频流编码格式（对齐 core `StreamCodec` 的 `"av1"` / `"hevc"` / `"h264"`）。
nonisolated enum VideoCodec: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case av1 = "av1"
    case hevc = "hevc"
    case h264 = "h264"

    var id: String { rawValue }

    /// 本机是否支持 AV1 硬件解码（A17 Pro / M3 及以上真机；模拟器与不支持机型严格 fail-closed）。
    static var isHardwareAV1DecodeSupported: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        if ProcessInfo.processInfo.environment["RC_DISABLE_AV1"] != nil {
            return false
        }
        return VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)
        #endif
    }

    /// 当前设备允许用户在设置页选择的默认编码偏好列表（按本机解码能力 fail-closed）。
    static var selectablePreferenceCases: [VideoCodec] {
        isHardwareAV1DecodeSupported ? [.av1, .hevc, .h264] : [.hevc, .h264]
    }

    var label: String {
        switch self {
        case .av1: "AV1"
        case .hevc: "H.265 (HEVC)"
        case .h264: "H.264 (AVC)"
        }
    }

    var shortLabel: String {
        switch self {
        case .av1: "AV1"
        case .hevc: "H.265"
        case .h264: "H.264"
        }
    }

    var preferenceLabel: String {
        switch self {
        case .av1: "AV1 高效（A17 Pro+）"
        case .hevc: "H.265 优先（推荐）"
        case .h264: "H.264 兼容"
        }
    }

    var menuOptionLabel: String {
        switch self {
        case .av1: "AV1 · 超清省流"
        case .hevc: "H.265 (HEVC) · 推荐"
        case .h264: "H.264 (AVC) · 兼容"
        }
    }

    static func parse(_ raw: String?) -> VideoCodec? {
        guard let normalized = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !normalized.isEmpty else { return nil }
        switch normalized {
        case "av1", "av01": return .av1
        case "hevc", "h265", "h.265": return .hevc
        case "h264", "h.264", "avc": return .h264
        default: return nil
        }
    }
}

/// 连接路由模式（对齐 macOS 基线 §4.2 `AppPrefs.connection_mode`）。
nonisolated enum ConnectionMode: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case auto = "auto"
    case p2pOnly = "p2p_only"
    case tcpRelay = "tcp_relay"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: "自动路由（推荐）"
        case .p2pOnly: "仅直连 / P2P"
        case .tcpRelay: "强制 TCP 中继"
        }
    }

    var shortLabel: String {
        switch self {
        case .auto: "自动"
        case .p2pOnly: "仅 P2P"
        case .tcpRelay: "TCP 中继"
        }
    }
}

/// 主控端偏好(UserDefaults 持久化)。
@Observable
final class PrefsStore {
    static let shared = PrefsStore()

    enum QualityPreset: String, CaseIterable, Identifiable {
        case smooth = "流畅"
        case balanced = "均衡"
        case superClear = "超清"
        case hd = "高清"
        case original = "原画"
        case master = "臻享"
        case extreme = "极致"
        case custom = "自定义"
        var id: String { rawValue }

        var bitrateBps: Int {
            switch self {
            case .smooth: 2_000_000
            case .balanced: 8_000_000
            case .superClear: 14_000_000
            case .hd: 20_000_000
            case .original: 30_000_000
            case .master: 60_000_000
            case .extreme: 150_000_000
            case .custom: 8_000_000
            }
        }

        var fps: Int {
            switch self {
            case .smooth: 24
            case .balanced: 30
            case .superClear: 60
            case .hd: 60
            case .original: 60
            case .master: 120
            case .extreme: 120
            case .custom: 30
            }
        }
    }

    var qualityPreset: QualityPreset {
        didSet { defaults.set(qualityPreset.rawValue, forKey: "prefs.qualityPreset") }
    }
    var customBitrateBps: Int {
        didSet { defaults.set(customBitrateBps, forKey: "prefs.customBitrateBps") }
    }
    var customFps: Int {
        didSet { defaults.set(customFps, forKey: "prefs.customFps") }
    }
    /// 默认视频编码偏好，优先使用 H.265（两端支持时生效，否则自动回退；不支持 AV1 硬解的机型自动 fail-closed 回退 H.265）。
    var preferredCodec: VideoCodec {
        didSet {
            if preferredCodec == .av1 && !VideoCodec.isHardwareAV1DecodeSupported {
                preferredCodec = .hevc
                return
            }
            defaults.set(preferredCodec.rawValue, forKey: "prefs.preferredCodec")
        }
    }
    var connectionMode: ConnectionMode {
        didSet { defaults.set(connectionMode.rawValue, forKey: "prefs.connectionMode") }
    }
    var showHUD: Bool {
        didSet { defaults.set(showHUD, forKey: "prefs.showHUD") }
    }
    var encryptConnection: Bool {
        didSet { defaults.set(encryptConnection, forKey: "prefs.encryptConnection") }
    }
    /// 静止画面 Tile 级无损文字锐化补帧开关。
    var stillRefinementEnabled: Bool {
        didSet { defaults.set(stillRefinementEnabled, forKey: "prefs.stillRefinement") }
    }
    /// 远程会话主动断开前是否自动锁定被控端屏幕（§6.3）。
    var lockRemoteOnDisconnect: Bool {
        didSet { defaults.set(lockRemoteOnDisconnect, forKey: "prefs.lockRemoteOnDisconnect") }
    }

    private let defaults = UserDefaults.standard

    private init() {
        let d = UserDefaults.standard
        qualityPreset = QualityPreset(rawValue: d.string(forKey: "prefs.qualityPreset") ?? "") ?? .balanced
        customBitrateBps = d.object(forKey: "prefs.customBitrateBps") as? Int ?? 8_000_000
        customFps = d.object(forKey: "prefs.customFps") as? Int ?? 30
        let loadedCodec = VideoCodec.parse(d.string(forKey: "prefs.preferredCodec")) ?? .hevc
        preferredCodec = (loadedCodec == .av1 && !VideoCodec.isHardwareAV1DecodeSupported) ? .hevc : loadedCodec
        connectionMode = ConnectionMode(rawValue: d.string(forKey: "prefs.connectionMode") ?? "") ?? .auto
        showHUD = d.object(forKey: "prefs.showHUD") as? Bool ?? false
        encryptConnection = d.object(forKey: "prefs.encryptConnection") as? Bool ?? true
        stillRefinementEnabled = d.object(forKey: "prefs.stillRefinement") as? Bool ?? true
        lockRemoteOnDisconnect = d.object(forKey: "prefs.lockRemoteOnDisconnect") as? Bool ?? false
    }

    /// 会话打开采用的码率(自定义档位取自定义值)。
    var effectiveBitrateBps: Int {
        qualityPreset == .custom ? customBitrateBps : qualityPreset.bitrateBps
    }

    var effectiveFps: Int {
        qualityPreset == .custom ? customFps : qualityPreset.fps
    }
}
