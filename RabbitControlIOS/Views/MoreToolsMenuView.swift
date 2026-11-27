import SwiftUI

/// O1「更多工具」移动端弹层:支持用户自定义工具顺序持久化（对齐桌面端浅蓝工具卡 + 白底电源项结构）。
enum DeviceMoreToolAction: String, CaseIterable, Codable, Hashable {
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

    private static let orderKey = "moreTools.customOrder"

    static func loadOrdered() -> [DeviceMoreToolAction] {
        guard let saved = UserDefaults.standard.stringArray(forKey: orderKey) else {
            return allCases
        }
        var result = saved.compactMap { DeviceMoreToolAction(rawValue: $0) }
        for item in allCases where !result.contains(item) {
            result.append(item)
        }
        return result
    }

    static func saveOrdered(_ list: [DeviceMoreToolAction]) {
        UserDefaults.standard.set(list.map(\.rawValue), forKey: orderKey)
    }
}

enum DevicePowerAction: String, Identifiable {
    case reboot
    case shutdown

    var id: String { rawValue }
    var verb: String { self == .reboot ? "重启" : "关机" }
    var title: String { "\(verb)设备" }
    var command: String { self == .reboot ? "sudo shutdown -r now" : "sudo shutdown -h now" }
    var icon: RabbitIcon.Name { self == .reboot ? .restart : .power }

    var accessibilityID: String {
        self == .reboot ? "moreTools.reboot" : "moreTools.shutdown"
    }
}

struct MoreToolsMenuView: View {
    var onTool: (DeviceMoreToolAction) -> Void
    var onPower: (DevicePowerAction) -> Void
    var onClose: () -> Void
    var isCovered = false

    @State private var orderedActions: [DeviceMoreToolAction] = DeviceMoreToolAction.loadOrdered()
    @State private var isReordering = false

    var body: some View {
        ZStack {
            RCColor.modalMask.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(isReordering ? "调整工具顺序" : "更多工具")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(RCColor.textPrimary)
                        .accessibilityHidden(isCovered)
                    Spacer()
                    if isReordering {
                        Button("恢复默认") {
                            withAnimation(.snappy(duration: 0.2)) {
                                orderedActions = DeviceMoreToolAction.allCases
                                DeviceMoreToolAction.saveOrdered(orderedActions)
                            }
                        }
                        .font(.caption.weight(.medium))
                        .foregroundStyle(RCColor.accent)
                    }
                }

                VStack(spacing: 10) {
                    ForEach(Array(orderedActions.enumerated()), id: \.element) { idx, action in
                        if isReordering {
                            reorderRow(action, index: idx)
                        } else {
                            toolRow(action)
                        }
                    }
                    if !isReordering {
                        powerRow(.reboot)
                            .padding(.top, 6)
                        powerRow(.shutdown)
                    }
                }
                .padding(.top, 16)

                HStack {
                    Button(isReordering ? "完成排序" : "调整顺序") {
                        withAnimation(.snappy(duration: 0.2)) {
                            isReordering.toggle()
                        }
                    }
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

    private func reorderRow(_ action: DeviceMoreToolAction, index: Int) -> some View {
        HStack(spacing: 12) {
            RabbitIcon(action.icon, size: 20)
                .foregroundStyle(RCColor.accent)
                .frame(width: 24)
            Text(action.title)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(RCColor.textPrimary)
            Spacer()
            Button {
                guard index > 0 else { return }
                withAnimation(.snappy(duration: 0.18)) {
                    orderedActions.swapAt(index, index - 1)
                    DeviceMoreToolAction.saveOrdered(orderedActions)
                }
            } label: {
                RabbitIcon(.arrowUp, size: 15)
                    .foregroundStyle(index > 0 ? RCColor.accent : RCColor.textDisabled)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .disabled(index == 0)

            Button {
                guard index < orderedActions.count - 1 else { return }
                withAnimation(.snappy(duration: 0.18)) {
                    orderedActions.swapAt(index, index + 1)
                    DeviceMoreToolAction.saveOrdered(orderedActions)
                }
            } label: {
                RabbitIcon(.arrowDown, size: 15)
                    .foregroundStyle(index < orderedActions.count - 1 ? RCColor.accent : RCColor.textDisabled)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .disabled(index >= orderedActions.count - 1)
        }
        .padding(.horizontal, 16)
        .frame(height: 54)
        .background(RCColor.bgToolTile, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(RCColor.toolTileStroke, lineWidth: 1)
        }
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
                Text("确认要\(action.verb)「\(deviceName)」吗？将打开远程终端并预填 `\(action.command)` 以便验证系统密码执行。")
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
