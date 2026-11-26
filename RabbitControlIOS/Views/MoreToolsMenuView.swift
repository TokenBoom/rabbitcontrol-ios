import SwiftUI

/// O1「更多工具」移动端弹层:沿用桌面端浅蓝工具卡 + 白底电源项结构。
enum DeviceMoreToolAction: CaseIterable, Hashable {
    case files, watch, terminal, portMapping

    var title: String {
        switch self {
        case .files: "文件传输"
        case .watch: "观看模式"
        case .terminal: "终端"
        case .portMapping: "端口映射"
        }
    }

    var icon: RabbitIcon.Name {
        switch self {
        case .files: .fileTransfer
        case .watch: .watchScreen
        case .terminal: .terminal
        case .portMapping: .portMap
        }
    }

    var accessibilityID: String {
        switch self {
        case .files: "moreTools.files"
        case .watch: "moreTools.watch"
        case .terminal: "moreTools.terminal"
        case .portMapping: "moreTools.portMapping"
        }
    }
}

enum DevicePowerAction: String, Identifiable {
    case reboot
    case shutdown

    var id: String { rawValue }
    var verb: String { self == .reboot ? "重启" : "关机" }
    var title: String { "\(verb)设备" }
    var command: String { self == .reboot ? "reboot" : "shutdown" }
    var icon: RabbitIcon.Name { self == .reboot ? .restart : .power }

    var accessibilityID: String {
        self == .reboot ? "moreTools.reboot" : "moreTools.shutdown"
    }
}

struct MoreToolsMenuView: View {
    var onTool: (DeviceMoreToolAction) -> Void
    var onPower: (DevicePowerAction) -> Void
    var onReorder: () -> Void
    var onClose: () -> Void
    var isCovered = false

    var body: some View {
        ZStack {
            RCColor.modalMask.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                Text("更多工具")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(RCColor.textPrimary)
                    .accessibilityHidden(isCovered)

                VStack(spacing: 10) {
                    ForEach(DeviceMoreToolAction.allCases, id: \.self) { action in
                        toolRow(action)
                    }
                    powerRow(.reboot)
                        .padding(.top, 6)
                    powerRow(.shutdown)
                }
                .padding(.top, 16)

                HStack {
                    Button("调整顺序", action: onReorder)
                        .buttonStyle(RCModalSecondaryButtonStyle())
                        .accessibilityIdentifier("moreTools.reorder")
                        .disabled(isCovered)
                        .accessibilityHidden(isCovered)
                    Spacer()
                    Button("关闭", action: onClose)
                        .buttonStyle(RCModalSecondaryButtonStyle())
                        .accessibilityIdentifier("moreTools.close")
                        .disabled(isCovered)
                        .accessibilityHidden(isCovered)
                }
                .padding(.top, 16)
            }
            .padding(22)
            .frame(maxWidth: 420)
            .background(RCColor.bgWindow, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(RCColor.popoverStroke, lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.13), radius: 32, y: 12)
            .shadow(color: .black.opacity(0.06), radius: 8, y: 2)
            .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .allowsHitTesting(!isCovered)
        .transition(.scale(scale: 0.96).combined(with: .opacity))
    }

    private func toolRow(_ action: DeviceMoreToolAction) -> some View {
        Button {
            onTool(action)
        } label: {
            rowLabel(icon: action.icon, title: action.title, tint: RCColor.accent)
        }
        .buttonStyle(MoreToolRowButtonStyle(tile: true))
        .accessibilityIdentifier(action.accessibilityID)
        .disabled(isCovered)
        .accessibilityHidden(isCovered)
    }

    private func powerRow(_ action: DevicePowerAction) -> some View {
        Button {
            onPower(action)
        } label: {
            rowLabel(icon: action.icon, title: action.verb, tint: RCColor.textSecondary)
        }
        .buttonStyle(MoreToolRowButtonStyle(tile: false))
        .accessibilityIdentifier(action.accessibilityID)
        .disabled(isCovered)
        .accessibilityHidden(isCovered)
    }

    private func rowLabel(icon: RabbitIcon.Name, title: String, tint: Color) -> some View {
        HStack(spacing: 12) {
            RabbitIcon(icon, size: 20)
                .foregroundStyle(tint)
                .frame(width: 24)
            Text(title)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(RCColor.textPrimary)
            Spacer()
            RabbitIcon(.chevronRight, size: 16)
                .foregroundStyle(RCColor.textSecondary)
        }
        .padding(.horizontal, 16)
        .frame(height: 54)
        .contentShape(Rectangle())
    }
}

struct DevicePowerConfirmView: View {
    var action: DevicePowerAction
    var deviceName: String
    var onCancel: () -> Void
    var onConfirm: () -> Void

    var body: some View {
        ZStack {
            Color.clear
                .ignoresSafeArea()
                .contentShape(Rectangle())

            VStack(alignment: .leading, spacing: 0) {
                Text(action.title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(RCColor.textPrimary)
                Text("确认要\(action.verb)「\(deviceName)」吗？")
                    .font(.system(size: 13))
                    .foregroundStyle(RCColor.textSecondary)
                    .padding(.top, 8)

                HStack(spacing: 8) {
                    Spacer()
                    Button("取消", action: onCancel)
                        .buttonStyle(RCModalSecondaryButtonStyle())
                        .accessibilityIdentifier("powerConfirm.cancel")
                    Button("确认", action: onConfirm)
                        .buttonStyle(RCModalDangerButtonStyle())
                        .accessibilityIdentifier("powerConfirm.confirm")
                }
                .padding(.top, 20)
            }
            .padding(22)
            .frame(maxWidth: 320)
            .background(RCColor.bgWindow, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(RCColor.popoverStroke, lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.13), radius: 32, y: 12)
            .shadow(color: .black.opacity(0.06), radius: 8, y: 2)
            .padding(.horizontal, 36)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .transition(.scale(scale: 0.96).combined(with: .opacity))
    }
}

private struct MoreToolRowButtonStyle: ButtonStyle {
    var tile: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                backgroundColor(pressed: configuration.isPressed),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(tile ? RCColor.toolTileStroke : RCColor.stroke, lineWidth: 1)
            }
    }

    private func backgroundColor(pressed: Bool) -> Color {
        if tile {
            return pressed ? RCColor.bgToolTilePressed : RCColor.bgToolTile
        }
        return pressed ? RCColor.bgHover : RCColor.bgWindow
    }
}

private struct RCModalSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(RCColor.textPrimary)
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(
                configuration.isPressed ? RCColor.bgHover : RCColor.bgWindow,
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(RCColor.stroke, lineWidth: 1)
            }
    }
}

private struct RCModalDangerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(
                RCColor.danger.opacity(configuration.isPressed ? 0.82 : 1),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
    }
}
