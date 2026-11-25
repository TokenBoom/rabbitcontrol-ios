import SwiftUI

/// 远控会话界面(S1 移动端适配):真实会话画面(VT 解码)+ 顶部会话工具栏 + HUD。
/// LAN 直连可用时自动建连;UI 测试或无直连地址时退回 mock 占位。
struct SessionView: View {
    var device: Device
    var mode: DeviceDetailView.SessionMode
    /// 显式直连地址(ip:port);非空时优先于 LAN 匹配。
    var directAddr: String?

    @Environment(\.dismiss) private var dismiss
    @State private var startedAt = Date.now
    @State private var hudVisible = true
    @State private var quality = "超清 14M"
    @State private var frameRate = "144 帧"
    @State private var showSecurity = false
    @State private var session = SessionService.shared

    private var watchMode: Bool { mode == .watch }

    /// 是否启用真实会话链路(UI 测试注入 mock 时禁用)。
    private var resolvedAddr: String? {
        if let directAddr { return directAddr }
        return LANDiscoveryService.shared.directAddr(forDeviceID: device.id)
    }

    private var useRealSession: Bool {
        !AuthService.uiTestingMock && resolvedAddr != nil
    }

    var body: some View {
        ZStack(alignment: .top) {
            // 画面区:真实会话或占位
            RCColor.stageBg.ignoresSafeArea()
            if session.isActive {
                RemoteVideoView(session: session)
                    .ignoresSafeArea()
            } else {
                VStack(spacing: 10) {
                    if useRealSession, case .ended(let reason) = session.state {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(RCColor.warning)
                        Text(reason)
                            .font(.system(size: 13))
                            .foregroundStyle(RCColor.textSecondary)
                    } else {
                        ProgressView()
                            .tint(.white)
                        Text(useRealSession ? session.state.displayText : "画面接入将在后续版本桥接视频层")
                            .font(.system(size: 13))
                            .foregroundStyle(RCColor.textSecondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

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
        .onAppear {
            guard useRealSession, !session.isActive else { return }
            openSession()
        }
        .onDisappear {
            session.close()
        }
        .sheet(isPresented: $showSecurity) {
            SecurityStatusView()
                .presentationDetents([.medium])
        }
    }

    /// 账号设备(9 位设备码)且信令在线 → 一键连接(三阶路由+免密);
    /// 否则回退直连地址。
    private func openSession() {
        let digits = device.id.filter { $0.isNumber }
        if digits.count == 9, RuntimeService.shared.signalRunning {
            Task {
                do {
                    let result = try await RuntimeService.connect(
                        targetID: digits,
                        watchOnly: watchMode,
                        lanDirectAddr: resolvedAddr
                    )
                    await MainActor.run {
                        session.adopt(sessionID: result.sessionID)
                    }
                } catch {
                    // 信令连接失败回退直连
                    if let addr = resolvedAddr {
                        await MainActor.run {
                            session.open(connectAddr: addr, password: nil, watchOnly: watchMode)
                        }
                    }
                }
            }
        } else if let addr = resolvedAddr {
            session.open(connectAddr: addr, password: nil, watchOnly: watchMode)
        }
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            // 安全状态(S2)
            Button {
                showSecurity = true
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

/// S2 安全状态面板:防窥模式 Select + 被控静音/自动锁屏 Switch。
/// 「需关注」琥珀 pill 判定:防窥模式=「关闭」或自动锁屏=关时显示(设计规范 S2)。
struct SecurityStatusView: View {
    @State private var privacyMode = "隐私屏保"
    @State private var muted = false
    @State private var autoLock = false

    private let privacyOptions = ["隐私屏保", "黑屏", "关闭"]

    private var needsAttention: Bool {
        privacyMode == "关闭" || !autoLock
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("安全状态")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(RCColor.textPrimary)
                Spacer()
                if needsAttention {
                    HStack(spacing: 4) {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 11))
                        Text("需关注")
                            .font(.system(size: 12))
                    }
                    .foregroundStyle(RCColor.warning)
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .background(Color(hex: 0xFFF7E8), in: Capsule())
                    .accessibilityIdentifier("security.attention")
                }
            }

            // 防窥模式
            HStack(spacing: 12) {
                Image(systemName: "eye.slash")
                    .font(.system(size: 16))
                    .foregroundStyle(RCColor.textSecondary)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text("防窥模式")
                        .font(.system(size: 14))
                        .foregroundStyle(RCColor.textPrimary)
                    Text("被控端屏幕已防护,遮挡屏幕内容")
                        .font(.system(size: 12))
                        .foregroundStyle(RCColor.textSecondary)
                }
                Spacer()
                Menu {
                    ForEach(privacyOptions, id: \.self) { option in
                        Button {
                            privacyMode = option
                        } label: {
                            if option == privacyMode {
                                Label(option, systemImage: "checkmark")
                            } else {
                                Text(option)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(privacyMode)
                            .font(.system(size: 13))
                            .foregroundStyle(RCColor.textPrimary)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10))
                            .foregroundStyle(RCColor.textSecondary)
                    }
                }
                .accessibilityIdentifier("security.privacyMode")
            }

            // 被控静音
            HStack(spacing: 12) {
                Image(systemName: muted ? "speaker.slash" : "speaker.wave.2")
                    .font(.system(size: 16))
                    .foregroundStyle(RCColor.textSecondary)
                    .frame(width: 24)
                Text("被控静音")
                    .font(.system(size: 14))
                    .foregroundStyle(RCColor.textPrimary)
                Text(muted ? "已静音" : "已外放")
                    .font(.system(size: 12))
                    .foregroundStyle(RCColor.textSecondary)
                Spacer()
                Toggle("", isOn: $muted)
                    .labelsHidden()
                    .tint(RCColor.accent)
                    .accessibilityIdentifier("security.muted")
            }

            // 自动锁屏
            HStack(spacing: 12) {
                Image(systemName: "lock")
                    .font(.system(size: 16))
                    .foregroundStyle(RCColor.textSecondary)
                    .frame(width: 24)
                Text("自动锁屏")
                    .font(.system(size: 14))
                    .foregroundStyle(RCColor.textPrimary)
                Text(autoLock ? "已开启" : "未开启")
                    .font(.system(size: 12))
                    .foregroundStyle(RCColor.textSecondary)
                Spacer()
                Toggle("", isOn: $autoLock)
                    .labelsHidden()
                    .tint(RCColor.accent)
                    .accessibilityIdentifier("security.autoLock")
            }

            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
    }
}
