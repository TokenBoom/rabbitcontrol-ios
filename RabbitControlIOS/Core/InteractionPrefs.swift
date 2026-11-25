import SwiftUI

enum TouchInputMode: String, CaseIterable {
    case trackpad
    case directTouch

    var label: String {
        switch self {
        case .trackpad: return "精密触控板"
        case .directTouch: return "直点触控"
        }
    }
}

enum SessionOrientation: String, CaseIterable {
    case auto
    case landscape
    case portrait

    var label: String {
        switch self {
        case .auto: return "自动旋转"
        case .landscape: return "锁定横屏"
        case .portrait: return "锁定竖屏"
        }
    }
}

enum PortraitLayout: String, CaseIterable {
    case auto
    case fullscreen
    case splitTrackpad

    var label: String {
        switch self {
        case .auto: return "智能"
        case .fullscreen: return "竖屏全屏"
        case .splitTrackpad: return "触控板分屏"
        }
    }
}

/// 会话交互偏好:触控模式、指针灵敏度、滚动方向与布局,UserDefaults 持久化。
@Observable final class InteractionPrefs {
    static let shared = InteractionPrefs()

    var touchMode: TouchInputMode {
        didSet { defaults.set(touchMode.rawValue, forKey: "rc.touchMode") }
    }
    var pointerSensitivity: Double {
        didSet { defaults.set(pointerSensitivity, forKey: "rc.pointerSensitivity") }
    }
    var naturalScroll: Bool {
        didSet { defaults.set(naturalScroll, forKey: "rc.naturalScroll") }
    }
    var directTouchOffset: Bool {
        didSet { defaults.set(directTouchOffset, forKey: "rc.directTouchOffset") }
    }
    var orientation: SessionOrientation {
        didSet { defaults.set(orientation.rawValue, forKey: "rc.orientation") }
    }
    var portraitLayout: PortraitLayout {
        didSet { defaults.set(portraitLayout.rawValue, forKey: "rc.portraitLayout") }
    }
    var keyboardBarVisible: Bool {
        didSet { defaults.set(keyboardBarVisible, forKey: "rc.keyboardBarVisible") }
    }
    var hasSeenGestureGuide: Bool {
        didSet { defaults.set(hasSeenGestureGuide, forKey: "rc.hasSeenGestureGuide") }
    }
    var hudAlpha: Double {
        didSet { defaults.set(hudAlpha, forKey: "rc.hudAlpha") }
    }
    var controlsLeading: Bool {
        didSet { defaults.set(controlsLeading, forKey: "rc.controlsLeading") }
    }

    private let defaults = UserDefaults.standard

    private init() {
        let d = UserDefaults.standard
        touchMode = TouchInputMode(rawValue: d.string(forKey: "rc.touchMode") ?? "") ?? .directTouch
        pointerSensitivity = d.object(forKey: "rc.pointerSensitivity") == nil ? 1.15 : d.double(forKey: "rc.pointerSensitivity")
        naturalScroll = d.object(forKey: "rc.naturalScroll") == nil ? true : d.bool(forKey: "rc.naturalScroll")
        directTouchOffset = d.object(forKey: "rc.directTouchOffset") == nil ? true : d.bool(forKey: "rc.directTouchOffset")
        orientation = SessionOrientation(rawValue: d.string(forKey: "rc.orientation") ?? "") ?? .auto
        portraitLayout = PortraitLayout(rawValue: d.string(forKey: "rc.portraitLayout") ?? "") ?? .auto
        keyboardBarVisible = d.object(forKey: "rc.keyboardBarVisible") == nil ? false : d.bool(forKey: "rc.keyboardBarVisible")
        hasSeenGestureGuide = d.bool(forKey: "rc.hasSeenGestureGuide")
        hudAlpha = d.object(forKey: "rc.hudAlpha") == nil ? 1.0 : d.double(forKey: "rc.hudAlpha")
        controlsLeading = d.bool(forKey: "rc.controlsLeading")
    }
}
