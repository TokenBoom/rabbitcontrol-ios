import SwiftUI

/// 设备详情页(P1 移动端适配):预览卡 + 「进入桌面」/「观看模式」+ 工具入口。
struct DeviceDetailView: View {
    var device: Device

    @State private var sessionMode: SessionMode?

    enum SessionMode: Identifiable {
        case control
        case watch

        var id: Int {
            switch self {
            case .control: 0
            case .watch: 1
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // 预览卡
                WallpaperView(wallpaper: device.wallpaper)
                    .frame(maxWidth: .infinity)
                    .aspectRatio(16.0 / 10.0, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay {
                        if !device.online {
                            RoundedRectangle(cornerRadius: 12)
                                .fill(.black.opacity(0.45))
                            Text("设备离线")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(.white)
                        }
                    }
                    .padding(.horizontal, 16)

                // 状态行
                HStack(spacing: 8) {
                    Circle()
                        .fill(device.online ? RCColor.online : RCColor.textDisabled)
                        .frame(width: 8, height: 8)
                    Text(device.online ? "在线" : "离线")
                        .font(.system(size: 14))
                        .foregroundStyle(RCColor.textSecondary)
                    Spacer()
                }
                .padding(.horizontal, 20)

                // 主操作
                VStack(spacing: 12) {
                    Button {
                        sessionMode = .control
                    } label: {
                        HStack(spacing: 8) {
                            Text("进入桌面")
                                .font(.system(size: 16, weight: .semibold))
                            Image(systemName: "arrow.right")
                                .font(.system(size: 14, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(
                            device.online ? RCColor.accent : RCColor.stroke,
                            in: RoundedRectangle(cornerRadius: 10)
                        )
                    }
                    .disabled(!device.online)
                    .accessibilityIdentifier("detail.enterDesktop")

                    Button {
                        sessionMode = .watch
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "play.square")
                            Text("观看模式")
                        }
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(device.online ? RCColor.textPrimary : RCColor.textDisabled)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(.white, in: RoundedRectangle(cornerRadius: 10))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(RCColor.stroke, lineWidth: 1)
                        }
                    }
                    .disabled(!device.online)
                    .accessibilityIdentifier("detail.watchMode")
                }
                .padding(.horizontal, 16)

                // 工具入口(O1 工具项的移动端入口)
                VStack(spacing: 0) {
                    toolRow(icon: "folder", title: "文件传输")
                    divider
                    toolRow(icon: "terminal", title: "终端")
                    divider
                    toolRow(icon: "network", title: "端口映射")
                }
                .background(.white, in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 16)
            }
            .padding(.top, 8)
        }
        .background(RCColor.bgPage)
        .navigationTitle(device.name)
        .fullScreenCover(item: $sessionMode) { mode in
            SessionView(device: device, mode: mode)
        }
    }

    private var divider: some View {
        RCColor.divider
            .frame(height: 1)
            .padding(.leading, 56)
    }

    private func toolRow(icon: String, title: String) -> some View {
        Button {
            ToastCenter.shared.show("功能开发中")
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 17))
                    .foregroundStyle(RCColor.accent)
                    .frame(width: 24)
                Text(title)
                    .font(.system(size: 14))
                    .foregroundStyle(RCColor.textPrimary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12))
                    .foregroundStyle(RCColor.textDisabled)
            }
            .padding(.horizontal, 16)
            .frame(height: 48)
        }
        .buttonStyle(.plain)
        .disabled(!device.online)
        .accessibilityIdentifier("detail.tool.\(title)")
    }
}
