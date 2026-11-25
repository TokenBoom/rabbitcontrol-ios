import Foundation

/// 主控端偏好(UserDefaults 持久化)。只收录 iOS 主控语义成立的项:
/// 画质/帧率/HUD/默认加密——被控向偏好(防窥/锁屏等)不属于移动端。
@Observable
final class PrefsStore {
    static let shared = PrefsStore()

    enum QualityPreset: String, CaseIterable, Identifiable {
        case smooth = "流畅"
        case balanced = "均衡"
        case hd = "高清"
        case custom = "自定义"
        var id: String { rawValue }

        var bitrateBps: Int {
            switch self {
            case .smooth: 2_000_000
            case .balanced: 8_000_000
            case .hd: 20_000_000
            case .custom: 8_000_000
            }
        }

        var fps: Int {
            switch self {
            case .smooth: 24
            case .balanced: 30
            case .hd: 60
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
    var showHUD: Bool {
        didSet { defaults.set(showHUD, forKey: "prefs.showHUD") }
    }
    var encryptConnection: Bool {
        didSet { defaults.set(encryptConnection, forKey: "prefs.encryptConnection") }
    }

    private let defaults = UserDefaults.standard

    private init() {
        let d = UserDefaults.standard
        qualityPreset = QualityPreset(rawValue: d.string(forKey: "prefs.qualityPreset") ?? "") ?? .balanced
        customBitrateBps = d.object(forKey: "prefs.customBitrateBps") as? Int ?? 8_000_000
        customFps = d.object(forKey: "prefs.customFps") as? Int ?? 30
        showHUD = d.object(forKey: "prefs.showHUD") as? Bool ?? true
        encryptConnection = d.object(forKey: "prefs.encryptConnection") as? Bool ?? true
    }

    /// 会话打开采用的码率(自定义档位取自定义值)。
    var effectiveBitrateBps: Int {
        qualityPreset == .custom ? customBitrateBps : qualityPreset.bitrateBps
    }

    var effectiveFps: Int {
        qualityPreset == .custom ? customFps : qualityPreset.fps
    }
}
