import SwiftUI

/// 设计规范色彩 token,与 `rabbitcontrol-core` `docs/reference/design/08-ui-design.md` §3.1 一致。
enum RCColor {
    static let bgWindow = Color(hex: 0xFFFFFF)
    static let bgSidebar = Color(hex: 0xF5F5F7)
    static let bgHover = Color(hex: 0xE8E8EA)
    static let bgCard = Color(hex: 0xF8F9FA)
    static let bgPage = Color(hex: 0xEEF1F6)
    static let accent = Color(hex: 0x3370FF)
    static let accentPressed = Color(hex: 0x2A5FD9)
    static let textPrimary = Color(hex: 0x1D2129)
    static let textSecondary = Color(hex: 0x86909C)
    static let textDisplayNum = Color(hex: 0x4E5969)
    static let textDisabled = Color(hex: 0xC9CDD4)
    static let online = Color(hex: 0x23C343)
    static let danger = Color(hex: 0xF53F3F)
    static let warning = Color(hex: 0xFF7D00)
    static let divider = Color(hex: 0xF2F3F5)
    static let stroke = Color(hex: 0xE5E6EB)
    static let stageBg = Color(hex: 0x2B2B2E)
    static let hudBg = Color(hex: 0x1C1C1E, opacity: 0.82)
    static let pillOnlineBg = Color(hex: 0x1D2129)
}

extension Color {
    init(hex: UInt32, opacity: Double = 1.0) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0,
            opacity: opacity
        )
    }
}
