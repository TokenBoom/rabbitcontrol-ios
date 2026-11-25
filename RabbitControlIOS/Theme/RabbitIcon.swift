import SwiftUI

/// 应用内自绘 SVG 矢量图标。资源位于 Assets.xcassets/Icons，按模板色渲染。
struct RabbitIcon: View {
    enum Name: String, CaseIterable {
        case devices = "icon-devices"
        case person = "icon-person"
        case computer = "icon-computer"
        case desktopPC = "icon-desktop-pc"
        case phone = "icon-phone"
        case tablet = "icon-tablet"
        case remoteAssist = "icon-remote-assist"
        case chevronRight = "icon-chevron-right"
        case chevronUp = "icon-chevron-up"
        case chevronDown = "icon-chevron-down"
        case warning = "icon-warning"
        case allDevices = "icon-all-devices"
        case arrowRight = "icon-arrow-right"
        case arrowUp = "icon-arrow-up"
        case arrowDown = "icon-arrow-down"
        case watchScreen = "icon-watch-screen"
        case pencil = "icon-pencil"
        case trash = "icon-trash"
        case ellipsis = "icon-ellipsis"
        case settings = "icon-settings"
        case server = "icon-server"
        case security = "icon-security"
        case disconnected = "icon-disconnected"
        case networkError = "icon-network-error"
        case search = "icon-search"
        case portMap = "icon-port-map"
        case plus = "icon-plus"
        case folder = "icon-folder"
        case file = "icon-file"
        case download = "icon-download"
        case terminalFollow = "icon-terminal-follow"
        case sessionEnded = "icon-session-ended"
        case close = "icon-close"
        case eye = "icon-eye"
        case cursor = "icon-cursor"
        case keyboard = "icon-keyboard"
        case terminal = "icon-terminal"
        case fileTransfer = "icon-file-transfer"
        case mouse = "icon-mouse"
        case clipboard = "icon-clipboard"
        case speaker = "icon-speaker"
        case display = "icon-display"
        case folderAdd = "icon-folder-add"
        case star = "icon-star"
        case starFilled = "icon-star-filled"
    }

    let name: Name
    var size: CGFloat = 20
    @ScaledMetric(relativeTo: .body) private var dynamicScale: CGFloat = 1

    init(_ name: Name, size: CGFloat = 20) {
        self.name = name
        self.size = size
    }

    var body: some View {
        Image(name.rawValue)
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: size * dynamicScale, height: size * dynamicScale)
            .accessibilityHidden(true)
    }
}

extension Label where Title == Text, Icon == RabbitIcon {
    init(_ titleKey: LocalizedStringKey, rabbitIcon: RabbitIcon.Name) {
        self.init {
            Text(titleKey)
        } icon: {
            RabbitIcon(rabbitIcon, size: 18)
        }
    }

    init<S>(_ title: S, rabbitIcon: RabbitIcon.Name) where S: StringProtocol {
        self.init {
            Text(title)
        } icon: {
            RabbitIcon(rabbitIcon, size: 18)
        }
    }
}
