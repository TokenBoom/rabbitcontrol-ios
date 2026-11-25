import SwiftUI

/// 远控会话界面(S1 移动端适配):深色画面占位区 + 顶部会话工具栏 + 控制中心菜单 + HUD。
/// 画面接入将在后续版本桥接视频层(设计规范 §8.5),本期为静态 mock。
struct SessionView: View {
    var device: Device
    var mode: DeviceDetailView.SessionMode

    @Environment(\.dismiss) private var dismiss
    @State private var startedAt = Date.now
    @State private var hudVisible = true
    @State private var quality = "超清 14M"
    @State private var frameRate = "144 帧"

    private var watchMode: Bool { mode == .watch }

    var body: some View {
        ZStack(alignment: .top) {
            // 画面区(占位)
            RCColor.stageBg.ignoresSafeArea()
            Text("画面接入将在后续版本桥接视频层")
                .font(.system(size: 13))
                .foregroundStyle(RCColor.textSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if watchMode {
                Text("观看模式")
                    .font(.system(size: 12))
                    .foregroundStyle(RCColor.textSecondary)
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .background(RCColor.bgHover.opacity(0.9), in: Capsule())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.leading, 16)
                    .padding(.top, 76)
            }

            // 顶部会话工具栏
            topBar

            // HUD(右下角常驻)
            if hudVisible {
                SessionHUD(startedAt: startedAt)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(.trailing, 16)
                    .padding(.bottom, 32)
                    .accessibilityIdentifier("session.hud")
            }

            // HUD 显隐切换(左下偏移小按钮)
            Button {
                hudVisible.toggle()
            } label: {
                Image(systemName: "pencil")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(width: 32, height: 32)
                    .background(RCColor.hudBg, in: Circle())
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .padding(.leading, 24)
            .padding(.bottom, 32)
            .accessibilityIdentifier("session.toggleHUD")
        }
        .statusBarHidden(true)
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            // 安全状态(占位)
            Button {
                ToastCenter.shared.show("功能开发中")
            } label: {
                Image(systemName: "shield")
                    .font(.system(size: 16))
                    .foregroundStyle(RCColor.textSecondary)
                    .frame(width: 32, height: 32)
            }
            .accessibilityIdentifier("session.security")

            // 屏幕 tab(单屏 mock)
            Text("显示屏1 (Built-in Retina Display)")
                .font(.system(size: 12))
                .foregroundStyle(RCColor.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.white, in: Capsule())
                .shadow(color: .black.opacity(0.06), radius: 3, y: 1)
                .frame(maxWidth: 180)

            Spacer()

            // 计时器
            TimelineView(.periodic(from: startedAt, by: 1)) { context in
                Text(sessionElapsed(at: context.date))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(RCColor.textSecondary)
            }
            .accessibilityIdentifier("session.timer")

            // 控制中心
            Menu {
                Button("切换下一个屏幕") {
                    ToastCenter.shared.show("功能开发中")
                }
                Menu("画质") {
                    ForEach(["自动", "原画 30M", "超清 14M", "高清 8M"], id: \.self) { option in
                        Button {
                            quality = option
                            ToastCenter.shared.show("画质将在下次连接生效")
                        } label: {
                            if option == quality {
                                Label(option, systemImage: "checkmark")
                            } else {
                                Text(option)
                            }
                        }
                    }
                    Divider()
                    ForEach(["144 帧", "90 帧", "60 帧", "30 帧"], id: \.self) { option in
                        Button {
                            frameRate = option
                            ToastCenter.shared.show("画质将在下次连接生效")
                        } label: {
                            if option == frameRate {
                                Label(option, systemImage: "checkmark")
                            } else {
                                Text(option)
                            }
                        }
                    }
                }
                Button("声音") { ToastCenter.shared.show("功能开发中") }
                Button("外设") { ToastCenter.shared.show("功能开发中") }
                Divider()
                Button("退出远控", role: .destructive) {
                    dismiss()
                }
                .accessibilityIdentifier("session.exit")
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "square.grid.2x2")
                    Text("控制中心")
                }
                .font(.system(size: 12))
                .foregroundStyle(RCColor.textPrimary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(RCColor.bgHover, in: Capsule())
            }
            .accessibilityIdentifier("session.controlCenter")
        }
        .padding(.horizontal, 10)
        .frame(height: 48)
        .background(.white.opacity(0.96))
    }

    private func sessionElapsed(at date: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(startedAt)))
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }
}

/// S4 HUD:静态 mock 链路数据,字段与 `LoopbackReport` 语义对齐,后续接真数据。
struct SessionHUD: View {
    var startedAt: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TimelineView(.periodic(from: startedAt, by: 1)) { context in
                Text(elapsed(at: context.date))
                    .foregroundStyle(.white)
            }
            Group {
                Text("UDP LAN")
                Text("2 fps")
                Text("227.2 Kbps")
                Text("110 ms")
                Text("20 ms frm.")
                Text("0.0% loss")
                Text("2K")
            }
            .foregroundStyle(Color(hex: 0x98989D))
        }
        .font(.system(size: 12, design: .monospaced))
        .padding(10)
        .background(RCColor.hudBg, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("session.hud")
    }

    private func elapsed(at date: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(startedAt)))
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }
}
