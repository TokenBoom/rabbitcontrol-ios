import SwiftUI

/// 设计规范色彩 token,与 `rabbitcontrol-core` `docs/reference/design/08-ui-design.md` §3.1 一致。
enum RCColor {
    static let bgWindow = Color(uiColor: .secondarySystemGroupedBackground)
    private static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            let rgb = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat(rgb >> 16) / 255, green: CGFloat((rgb >> 8) & 255) / 255,
                           blue: CGFloat(rgb & 255) / 255, alpha: 1)
        })
    }
    static let bgSidebar = Color(hex: 0xF5F5F7)
    static let bgHover = adaptive(0xE8E8EA, 0x35363A)
    static let bgCard = Color(hex: 0xF8F9FA)
    static let bgPage = adaptive(0xEEF1F6, 0x18191C)
    static let bgToolTile = adaptive(0xF2F6FF, 0x1B2A44)
    static let bgToolTilePressed = adaptive(0xE6EEFF, 0x263856)
    static let toolTileStroke = Color(hex: 0x3370FF, opacity: 0.12)
    static let popoverStroke = Color.primary.opacity(0.09)
    static let modalMask = Color.black.opacity(0.30)
    static let accent = Color(hex: 0x3370FF)
    static let accentPressed = Color(hex: 0x2A5FD9)
    static let textPrimary = Color.primary
    static let textSecondary = adaptive(0x606B79, 0xB3BAC4)
    static let textDisplayNum = Color(hex: 0x4E5969)
    static let textDisabled = adaptive(0xC9CDD4, 0x6E7178)
    static let online = Color(hex: 0x23C343)
    static let danger = Color(hex: 0xF53F3F)
    static let warning = Color(hex: 0xFF7D00)
    static let divider = Color(uiColor: .separator).opacity(0.35)
    static let stroke = Color(uiColor: .separator)
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
