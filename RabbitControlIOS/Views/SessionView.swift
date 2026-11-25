import SwiftUI

struct SessionView: View {
    var device: Device
    var mode: DeviceDetailView.SessionMode
    var directAddr: String?
    var connectionPassword = ""
    /// 从设备详情快捷入口进入时,连上后直接打开的工具。
    var initialTool: DeviceDetailView.QuickTool? = nil
    @State private var pendingTool: DeviceDetailView.QuickTool?
    @State private var hubTool: DeviceDetailView.QuickTool?

    @Environment(\.dismiss) private var dismiss
    @State private var startedAt = Date.now
    @State private var showControlHub = false
    @State private var showMouseTools = false
    @State private var confirmExit = false
    @State private var openedAttempt: Int?
    @State private var attempt = 0
    @State private var connectionError: String?
    @State private var retryPassword = ""
    @State private var session = SessionService.shared
    @State private var keyboardBarExpanded = InteractionPrefs.shared.keyboardBarVisible
    @State private var zoomPan = ZoomPanState()
    @State private var inputPrefs = InteractionPrefs.shared
    @State private var showGuide = false
    @State private var openedTool = false
    @State private var controlsCollapsed = false
    @Environment(\.verticalSizeClass) private var verticalClass
    private var watchMode: Bool { mode == .watch || session.peerWatchOnly }
    /// 竖屏且(选了分屏或智能模式下处于触控板模式)时启用上下分屏。
    private var splitLayout: Bool {
        guard verticalClass == .regular, !watchMode else { return false }
        switch inputPrefs.portraitLayout {
        case .fullscreen: return false
        case .splitTrackpad: return true
        case .auto: return inputPrefs.touchMode == .trackpad
        }
    }
    private var failure: String? {
        if case .ended(let reason) = session.state { return reason }
        return connectionError
    }

    var body: some View {
        ZStack {
            RCColor.stageBg.ignoresSafeArea()
            if session.isConnected {
                if splitLayout {
                    VStack(spacing: 0) {
                        RemoteVideoView(session: session, watchOnly: watchMode, showMouseTools: showMouseTools,
                                        zoomPan: zoomPan, inputEnabled: false,
                                        previewDeviceID: directAddr == nil ? device.id : nil)
                            .layoutPriority(1)
                        ZStack {
                            RCColor.hudBg
                            TouchInputView(session: session, zoomPan: zoomPan, watchOnly: watchMode, trackpadOnly: true)
                            VStack {
                                HStack(spacing: 4) {
                                    RabbitIcon(.mouse, size: 13)
                                    Text("触控板 · 单指移动 轻点左键 双指右键/滚动")
                                }.font(.caption2).foregroundStyle(.white.opacity(0.45)).padding(.top, 8)
                                Spacer()
                            }.allowsHitTesting(false)
                        }.frame(height: 220)
                        if !watchMode {
                            SessionKeyboardBar(session: session, expanded: $keyboardBarExpanded)
                                .padding(.vertical, 6)
                                .background(RCColor.hudBg)
                                .onChange(of: keyboardBarExpanded) { InteractionPrefs.shared.keyboardBarVisible = keyboardBarExpanded }
                        }
                    }.ignoresSafeArea(.container, edges: [.top, .horizontal])
                } else {
                    RemoteVideoView(session: session, watchOnly: watchMode, showMouseTools: showMouseTools,
                                    zoomPan: zoomPan,
                                    previewDeviceID: directAddr == nil ? device.id : nil)
                        .ignoresSafeArea()
                }
            } else if let failure {
                ScrollView {
                  VStack(spacing: 16) {
                    Label("连接已结束", rabbitIcon: .sessionEnded).font(.headline)
                    Text(failure).font(.callout).multilineTextAlignment(.center).textSelection(.enabled)
                    SecureField("远端连接密码（如需）", text: $retryPassword)
                        .textContentType(.password).textFieldStyle(.roundedBorder)
                        .submitLabel(.go).onSubmit { attempt += 1 }
                        .foregroundStyle(.primary).frame(maxWidth: 320)
                    Button("重新连接") { attempt += 1 }.buttonStyle(.borderedProminent)
                    Button("返回") { dismiss() }
                  }.frame(maxWidth: .infinity).padding(24).foregroundStyle(.white)
                }.scrollBounceBehavior(.basedOnSize).scrollDismissesKeyboard(.interactively)
                    .safeAreaPadding(.top, 56)
            } else if AuthService.uiTestingMock {
                Text("会话预览").foregroundStyle(.white)
            } else {
                VStack(spacing: 12) {
                    ProgressView().tint(.white)
                    Text(session.state == .idle ? "正在连接…" : session.state.displayText)
                }.foregroundStyle(.white)
            }
        }
        .overlay(alignment: .bottom) {
            if session.isConnected && !watchMode && !splitLayout {
                SessionKeyboardBar(session: session, expanded: $keyboardBarExpanded)
                    .safeAreaPadding(.bottom, 6)
                    .onChange(of: keyboardBarExpanded) { InteractionPrefs.shared.keyboardBarVisible = keyboardBarExpanded }
            }
        }
        .overlay(alignment: inputPrefs.controlsLeading ? .topLeading : .topTrailing) {
            VStack(alignment: inputPrefs.controlsLeading ? .leading : .trailing, spacing: 8) {
                if controlsCollapsed {
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) { controlsCollapsed = false }
                    } label: {
                        RabbitIcon(.settings, size: 18)
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(RCColor.hudBg, in: Circle())
                    }
                    .accessibilityLabel("展开会话控制栏")
                    .accessibilityIdentifier("session.expandControls")
                } else {
                    HStack(spacing: 0) {
                        Button {
                            if session.isConnected { confirmExit = true } else { dismiss() }
                        } label: { RabbitIcon(.close, size: 17).frame(width: 40, height: 40) }
                        .accessibilityLabel("退出远程协助").accessibilityIdentifier("session.exit")
                        Divider().frame(height: 16).overlay(.white.opacity(0.25))
                        Button { session.releasePressedInput(); showControlHub = true } label: {
                            HStack(spacing: 5) {
                                RabbitIcon(.settings, size: 16)
                                Text(watchMode ? "观看" : "控制")
                            }
                            .padding(.horizontal, 10).frame(minHeight: 40)
                        }.accessibilityIdentifier("session.controlCenter")
                        Divider().frame(height: 16).overlay(.white.opacity(0.25))
                        Button {
                            withAnimation(.easeInOut(duration: 0.18)) { controlsCollapsed = true }
                        } label: {
                            RabbitIcon(.chevronUp, size: 14).frame(width: 34, height: 40)
                        }
                        .accessibilityLabel("收起会话控制栏")
                        .accessibilityIdentifier("session.collapseControls")
                    }
                    .font(.subheadline.bold()).foregroundStyle(.white).background(RCColor.hudBg, in: Capsule())
                    if PrefsStore.shared.showHUD && session.isConnected {
                        SessionHUD(startedAt: startedAt, hud: session.hud).allowsHitTesting(false)
                    }
                }
            }
            .opacity(inputPrefs.hudAlpha)
            .safeAreaPadding(.top, 8)
            .safeAreaPadding(.horizontal, 12)
        }
        .statusBarHidden().persistentSystemOverlays(.hidden)
        .overlay {
            if showGuide {
                SessionGestureGuide {
                    inputPrefs.hasSeenGestureGuide = true
                    withAnimation { showGuide = false }
                }
            }
        }
        .onAppear {
            SessionOrientationLock.apply(inputPrefs.orientation)
            if !inputPrefs.hasSeenGestureGuide, !watchMode, !AuthService.uiTestingMock { showGuide = true }
        }
        .onDisappear { SessionOrientationLock.restore() }
        .onChange(of: session.isConnected) {
            if session.isConnected, let tool = pendingTool ?? initialTool, openedTool == false {
                openedTool = true
                hubTool = tool == .hub ? nil : tool
                showControlHub = true
            }
            if session.isConnected {
                TargetHistory.shared.recordConnect(directAddr ?? device.id.replacingOccurrences(of: " ", with: ""))
            }
        }
        .onChange(of: inputPrefs.orientation) { SessionOrientationLock.apply(inputPrefs.orientation) }
        .task(id: attempt) {
            guard openedAttempt != attempt else { return }
            openedAttempt = attempt
            await openSession()
        }
        .confirmationDialog("结束本次远程协助？", isPresented: $confirmExit, titleVisibility: .visible) {
            Button("结束会话", role: .destructive) { dismiss() }
            Button("取消", role: .cancel) {}
        }
        .sheet(isPresented: $showControlHub) {
            SessionControlHub(session: session, device: device, watchOnly: watchMode, showMouseTools: $showMouseTools, initialTool: hubTool) { showControlHub = false; dismiss() }
                .presentationDetents([.large]).presentationDragIndicator(.visible)
        }
    }

    private func openSession() async {
        guard !AuthService.uiTestingMock else { return }
        session.close()
        startedAt = .now
        connectionError = nil
        let password = retryPassword.isEmpty ? connectionPassword : retryPassword
        if let directAddr {
            session.open(connectAddr: directAddr, password: password, watchOnly: mode == .watch)
            return
        }
        let id = device.id.replacingOccurrences(of: " ", with: "")
        if id.count == 9, RuntimeService.shared.signalRunning {
            do {
                let result = try await RuntimeService.connect(targetID: id, password: password, watchOnly: mode == .watch,
                    lanDirectAddr: LANDiscoveryService.shared.directAddr(forDeviceID: id))
                guard !Task.isCancelled else { SessionService.releaseSession(result.sessionID); return }
                session.adopt(sessionID: result.sessionID, watchOnly: mode == .watch)
            } catch { if !Task.isCancelled { connectionError = error.localizedDescription } }
        } else {
            connectionError = "账号信令未就绪，无法验证设备身份。请检查网络和登录状态后重试。"
        }
    }
}

struct SessionHUD: View {
    var startedAt: Date
    /// 没有测量值时显示占位符，不当作零。
    var hud: [String: Any]?

    private var resolutionLabel: String {
        hud?["resolution"] as? String ?? "—"
    }

    private func fmt(_ value: Any?, digits: Int) -> String {
        guard let number = (value as? NSNumber)?.doubleValue else { return "—" }
        return String(format: "%.\(digits)f", number)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TimelineView(.periodic(from: startedAt, by: 1)) { context in
                Text(elapsed(at: context.date))
                    .foregroundStyle(.white)
            }
            Group {
                Text(hud?["transport"] as? String ?? "—")
                Text("\(fmt(hud?["fps"], digits: 0)) fps")
                Text("\(fmt(hud?["bitrate_kbps"], digits: 1)) Kbps")
                Text("\(fmt(hud?["rtt_ms"], digits: 0)) ms")
                Text("\(fmt(hud?["frame_ms"], digits: 0)) ms frm.")
                Text("\(fmt(hud?["loss_pct"], digits: 1))% loss")
                Text(resolutionLabel)
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
