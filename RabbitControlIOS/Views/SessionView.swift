import SwiftUI
import UIKit

struct SessionView: View {
    var device: Device
    var mode: DeviceDetailView.SessionMode
    var directAddr: String?
    var connectionPassword = ""
    /// 从设备详情快捷入口进入时,连上后直接打开的工具。
    var initialTool: DeviceDetailView.QuickTool? = nil
    /// 从纯工具无头模式原地热升级进入桌面时复用现有已连接会话，不断链重连。
    var adoptExistingSession = false

    @State private var pendingTool: DeviceDetailView.QuickTool?
    @State private var hubTool: DeviceDetailView.QuickTool?

    @Environment(\.dismiss) private var dismiss
    @State private var startedAt = Date.now
    @State private var showControlHub = false
    @State private var hubDetent: PresentationDetent = .fraction(0.64)
    @State private var showMouseTools = false
    @State private var confirmExit = false
    @State private var openedAttempt: Int?
    @State private var attempt = 0
    @State private var connectionError: String?
    @State private var connectionUiError: RCUiError?
    @State private var retryPassword = ""
    @State private var showRetryPassword = false
    @State private var session = SessionService.shared
    @State private var prefs = PrefsStore.shared
    @State private var netMonitor = NetworkMonitorService.shared
    @State private var keyboardBarExpanded = InteractionPrefs.shared.keyboardBarVisible
    @State private var zoomPan = ZoomPanState()
    @State private var inputPrefs = InteractionPrefs.shared
    @State private var showGuide = false
    @State private var openedTool = false
    @State private var controlsCollapsed = false
    @State private var wasConnected = false

    // 自动指数退避重连（对齐基线 §4.3 `AutoReconnectTask` 8 次上限）
    static let maxAutoReconnectAttempts = 8
    private static let backoffScheduleSec: [Double] = [0.6, 1.2, 2.4, 4.0, 6.0, 8.0, 10.0, 12.0]
    @State private var autoReconnectAttempt = 0
    @State private var isAutoReconnecting = false
    @State private var autoReconnectReason: String?
    @State private var autoReconnectTask: Task<Void, Never>?
    @State private var viewportSize = CGSize.zero
    @State private var stageWidth: CGFloat = 0

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalClass
    @Environment(\.verticalSizeClass) private var verticalClass

    private var watchMode: Bool { mode == .watch || session.effectiveWatchOnly }

    /// 竖屏视口且(选了分屏或智能模式下处于触控板模式)时启用上下分屏；iPad 横屏绝不误触发。
    private var splitLayout: Bool {
        RCLayout.shouldUseSessionSplitTrackpad(
            portraitLayout: inputPrefs.portraitLayout,
            touchMode: inputPrefs.touchMode,
            watchOnly: watchMode,
            verticalSizeClass: verticalClass,
            viewportSize: viewportSize
        )
    }

    private var usesSideInspector: Bool {
        RCLayout.prefersSessionSideInspector(
            horizontalSizeClass: horizontalClass,
            viewportSize: viewportSize
        )
    }

    private var inspectorWidth: CGFloat {
        min(376, max(324, round(viewportSize.width * 0.33)))
    }

    private var controlSheetBinding: Binding<Bool> {
        Binding(
            get: { showControlHub && !usesSideInspector },
            set: { showControlHub = $0 }
        )
    }

    private var failure: String? {
        if case .ended(let reason) = session.state { return reason }
        return connectionError
    }

    private var targetSubtitle: String {
        directAddr ?? device.displayID
    }

    private var isCoreReconnectingOrSwitching: Bool {
        switch session.state {
        case .reconnecting, .switching: true
        default: false
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            ZStack {
                RCColor.stageBg.ignoresSafeArea()
                if session.isConnected {
                    connectedStage
                } else if AuthService.uiTestingMock {
                    mockPreviewStage
                } else if isAutoReconnecting || isCoreReconnectingOrSwitching {
                    reconnectingCard
                } else if let failure {
                    disconnectedCard(reason: failure)
                } else {
                    connectingCard
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onGeometryChange(for: CGFloat.self) { geo in
                geo.size.width
            } action: { newWidth in
                stageWidth = newWidth
            }
            .overlay(alignment: .bottom) {
                if session.isConnected && !watchMode && !splitLayout {
                    SessionKeyboardBar(
                        session: session,
                        expanded: $keyboardBarExpanded,
                        stageWidth: stageWidth,
                        deviceKind: device.kind
                    )
                    .safeAreaPadding(.bottom, verticalClass == .compact ? 4 : 6)
                    .onChange(of: keyboardBarExpanded) { InteractionPrefs.shared.keyboardBarVisible = keyboardBarExpanded }
                }
            }
            .overlay(alignment: inputPrefs.controlsLeading ? .topLeading : .topTrailing) {
                floatingControlOverlay
            }

            if usesSideInspector && showControlHub {
                SessionInspectorPanel(
                    session: session,
                    device: device,
                    watchOnly: mode == .watch,
                    showMouseTools: $showMouseTools,
                    initialTool: hubTool,
                    onSwitchConnectionMode: directAddr == nil ? { newMode in
                        switchConnectionModeAndReconnect(newMode)
                    } : nil,
                    onReplayGuide: watchMode ? nil : {
                        withAnimation(.snappy(duration: 0.2)) { showControlHub = false }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                            withAnimation(.easeOut(duration: 0.2)) { showGuide = true }
                        }
                    },
                    onClosePanel: {
                        withAnimation(.snappy(duration: 0.22)) { showControlHub = false }
                    },
                    onExitSession: {
                        showControlHub = false
                        cancelAutoReconnect()
                        session.endUserSession()
                        dismiss()
                    }
                )
                .frame(width: inspectorWidth)
                .transition(.move(edge: .trailing))
            }
        }
        .animation(.snappy(duration: 0.22), value: usesSideInspector && showControlHub)
        .onGeometryChange(for: CGSize.self) { geo in
            geo.size
        } action: { newSize in
            viewportSize = newSize
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .overlay {
            if showGuide {
                SessionGestureGuide {
                    inputPrefs.hasSeenGestureGuide = true
                    withAnimation(.easeOut(duration: 0.2)) { showGuide = false }
                }
            }
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            SessionOrientationLock.apply(inputPrefs.orientation)
            if !inputPrefs.hasSeenGestureGuide, !watchMode, !AuthService.uiTestingMock { showGuide = true }
            if adoptExistingSession && session.isConnected {
                wasConnected = true
                openedAttempt = attempt
                session.upgradeToDesktop()
            }
        }
        .onDisappear {
            autoReconnectTask?.cancel()
            autoReconnectTask = nil
            UIApplication.shared.isIdleTimerDisabled = false
            SessionOrientationLock.restore()
        }
        .onChange(of: session.isConnected) {
            if session.isConnected {
                wasConnected = true
                cancelAutoReconnect()
                if !watchMode, let sid = session.sessionID {
                    ToolService.shared.start(sessionID: sid)
                }
                if let tool = pendingTool ?? initialTool, openedTool == false {
                    openedTool = true
                    hubTool = tool == .hub ? nil : tool
                    hubDetent = hubTool == nil ? .fraction(0.64) : .large
                    showControlHub = true
                }
                TargetHistory.shared.recordConnect(directAddr ?? device.id.replacingOccurrences(of: " ", with: ""))
            }
        }
        .onChange(of: session.state) { _, newState in
            evaluateAutoReconnect(for: newState)
        }
        .onChange(of: netMonitor.networkEpoch) {
            if isAutoReconnecting {
                triggerReconnectNow()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                UIApplication.shared.isIdleTimerDisabled = true
                SessionOrientationLock.apply(inputPrefs.orientation)
                if session.isConnected {
                    session.requestIDR()
                    session.resumeAudioIfNeeded()
                } else if wasConnected, failure != nil, !AuthService.uiTestingMock {
                    triggerReconnectNow()
                }
            } else {
                session.releasePressedInput()
                UIApplication.shared.isIdleTimerDisabled = false
            }
        }
        .onChange(of: inputPrefs.orientation) { SessionOrientationLock.apply(inputPrefs.orientation) }
        .task(id: attempt) {
            guard openedAttempt != attempt else { return }
            openedAttempt = attempt
            if adoptExistingSession && attempt == 0 && session.isConnected {
                session.upgradeToDesktop()
                return
            }
            await openSession()
        }
        .confirmationDialog("结束本次远程协助？", isPresented: $confirmExit, titleVisibility: .visible) {
            Button("结束会话", role: .destructive) {
                cancelAutoReconnect()
                session.endUserSession()
                dismiss()
            }
            Button("取消", role: .cancel) {}
        }
        .sheet(isPresented: controlSheetBinding) {
            SessionControlHub(
                session: session,
                device: device,
                watchOnly: mode == .watch,
                showMouseTools: $showMouseTools,
                initialTool: hubTool,
                onSwitchConnectionMode: directAddr == nil ? { newMode in
                    switchConnectionModeAndReconnect(newMode)
                } : nil,
                onReplayGuide: watchMode ? nil : {
                    showControlHub = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        withAnimation(.easeOut(duration: 0.2)) { showGuide = true }
                    }
                },
                onExit: {
                    showControlHub = false
                    cancelAutoReconnect()
                    session.endUserSession()
                    dismiss()
                }
            )
            .presentationDetents([.fraction(0.64), .large], selection: $hubDetent)
            .presentationDragIndicator(.visible)
        }
    }

    // MARK: - 自动重连与连接模式热切（§4.2 / §4.3）

    private func evaluateAutoReconnect(for newState: SessionState) {
        guard !AuthService.uiTestingMock else { return }
        switch newState {
        case .switching(let reason):
            scheduleAutoReconnect(reason: reason, immediateDelaySec: 0.8)
        case .ended(let reason):
            if wasConnected && session.endedRecoverable && autoReconnectAttempt < Self.maxAutoReconnectAttempts {
                scheduleAutoReconnect(reason: reason, immediateDelaySec: nil)
            } else if isAutoReconnecting && autoReconnectAttempt >= Self.maxAutoReconnectAttempts {
                isAutoReconnecting = false
                autoReconnectTask?.cancel()
                autoReconnectTask = nil
            } else if !session.endedRecoverable {
                cancelAutoReconnect()
            }
        default:
            break
        }
    }

    private func scheduleAutoReconnect(reason: String, immediateDelaySec: Double?) {
        autoReconnectTask?.cancel()
        let nextAttempt = min(Self.maxAutoReconnectAttempts, autoReconnectAttempt + 1)
        autoReconnectAttempt = nextAttempt
        autoReconnectReason = reason
        isAutoReconnecting = true
        let delay = immediateDelaySec ?? Self.backoffScheduleSec[min(nextAttempt - 1, Self.backoffScheduleSec.count - 1)]
        autoReconnectTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(Int(delay * 1000)))
            guard !Task.isCancelled, isAutoReconnecting else { return }
            attempt += 1
        }
    }

    private func triggerReconnectNow() {
        autoReconnectTask?.cancel()
        autoReconnectTask = nil
        isAutoReconnecting = false
        autoReconnectAttempt = 0
        attempt += 1
    }

    private func cancelAutoReconnect() {
        autoReconnectTask?.cancel()
        autoReconnectTask = nil
        isAutoReconnecting = false
        autoReconnectAttempt = 0
        autoReconnectReason = nil
    }

    private func switchConnectionModeAndReconnect(_ newMode: ConnectionMode) {
        prefs.connectionMode = newMode
        cancelAutoReconnect()
        session.close()
        ToastCenter.shared.show("已切换至\(newMode.shortLabel)模式，正在重建连接…")
        attempt += 1
    }

    // MARK: - 已连接舞台与分屏触控板

    @ViewBuilder
    private var connectedStage: some View {
        if splitLayout {
            VStack(spacing: 0) {
                RemoteVideoView(
                    session: session,
                    watchOnly: watchMode,
                    showMouseTools: showMouseTools,
                    zoomPan: zoomPan,
                    inputEnabled: false,
                    previewDeviceID: directAddr == nil ? device.id : nil
                )
                .layoutPriority(1)

                splitTrackpadDeck

                if !watchMode {
                    SessionKeyboardBar(
                        session: session,
                        expanded: $keyboardBarExpanded,
                        stageWidth: stageWidth,
                        deviceKind: device.kind
                    )
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity)
                    .background(Color(hex: 0x161618))
                    .onChange(of: keyboardBarExpanded) {
                        InteractionPrefs.shared.keyboardBarVisible = keyboardBarExpanded
                    }
                }
            }
            .ignoresSafeArea(.container, edges: [.top, .horizontal])
        } else {
            RemoteVideoView(
                session: session,
                watchOnly: watchMode,
                showMouseTools: showMouseTools,
                zoomPan: zoomPan,
                previewDeviceID: directAddr == nil ? device.id : nil
            )
            .ignoresSafeArea()
        }
    }

    private var splitTrackpadDeck: some View {
        let holdingLeft = session.isSustainedLeftHold
        return VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white.opacity(0.04))
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(
                                holdingLeft ? RCColor.accent.opacity(0.75) : Color.white.opacity(0.10),
                                lineWidth: 1
                            )
                    }

                TouchInputView(session: session, zoomPan: zoomPan, watchOnly: watchMode, trackpadOnly: true)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                VStack {
                    HStack(spacing: 5) {
                        RabbitIcon(.mouse, size: 12)
                        Text(holdingLeft ? "左键已按住 · 单指滑动移动窗口或选区" : "精密触控板 · 单指移动 轻点左键 长按滑动拖拽 双指滚轮")
                    }
                    .font(.caption2)
                    .foregroundStyle(holdingLeft ? Color(hex: 0x8AB4FF) : .white.opacity(0.42))
                    .padding(.top, 9)
                    Spacer()
                }
                .allowsHitTesting(false)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: 8) {
                splitHoldableLeftButton
                splitMouseButton(
                    session.isDragLocked ? "释放拖拽" : "拖拽锁定",
                    id: "splitpad.drag",
                    active: session.isDragLocked
                ) {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    session.toggleLeftMouseHold()
                }
                splitMouseButton("右键", id: "splitpad.right") {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    session.clickMouse("right")
                }
            }
            .frame(height: 36)
        }
        .frame(maxWidth: horizontalClass == .regular ? 640 : .infinity)
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity)
        .frame(height: 226)
        .background(Color(hex: 0x161618))
    }

    private var splitHoldableLeftButton: some View {
        HoldableLeftMouseButton(session: session) { active in
            Text("左键")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    active ? RCColor.accent : Color.white.opacity(0.09),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(active ? RCColor.accent : .white.opacity(0.08), lineWidth: 1)
                }
        }
        .accessibilityIdentifier("splitpad.left")
    }

    private func splitMouseButton(_ title: String, id: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    active ? RCColor.accent : Color.white.opacity(0.09),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(active ? RCColor.accent : .white.opacity(0.08), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    // MARK: - 顶部悬浮控制胶囊与遥测

    private var floatingControlOverlay: some View {
        let isLandscape = verticalClass == .compact
        let barHeight: CGFloat = isLandscape ? 34 : 40
        return VStack(alignment: inputPrefs.controlsLeading ? .leading : .trailing, spacing: isLandscape ? 5 : 8) {
            if controlsCollapsed {
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    withAnimation(.easeOut(duration: 0.18)) { controlsCollapsed = false }
                } label: {
                    RabbitIcon(.settings, size: isLandscape ? 16 : 18)
                        .foregroundStyle(.white)
                        .frame(width: barHeight, height: barHeight)
                        .background(RCColor.hudBg, in: Circle())
                        .overlay {
                            Circle().strokeBorder(.white.opacity(0.14), lineWidth: 1)
                        }
                        .shadow(color: .black.opacity(0.28), radius: 10, y: 3)
                }
                .accessibilityLabel("展开会话控制栏")
                .accessibilityIdentifier("session.expandControls")
            } else {
                HStack(spacing: 6) {
                    if zoomPan.isZoomed && inputPrefs.controlsLeading == false {
                        zoomResetChip(height: barHeight, compact: isLandscape)
                    }

                    HStack(spacing: 0) {
                        Button {
                            if session.isConnected { confirmExit = true } else {
                                cancelAutoReconnect()
                                dismiss()
                            }
                        } label: {
                            RabbitIcon(.close, size: isLandscape ? 15 : 17)
                                .frame(width: barHeight, height: barHeight)
                        }
                        .accessibilityLabel("退出远程协助")
                        .accessibilityIdentifier("session.exit")

                        pillDivider

                        if (session.isConnected || AuthService.uiTestingMock) && !watchMode {
                            Button {
                                toggleQuickTouchMode()
                            } label: {
                                HStack(spacing: 4) {
                                    RabbitIcon(inputPrefs.touchMode == .trackpad ? .mouse : .cursor, size: isLandscape ? 13 : 15)
                                    Text(inputPrefs.touchMode == .trackpad ? "触控板" : "直触")
                                }
                                .padding(.horizontal, isLandscape ? 8 : 10)
                                .frame(minHeight: barHeight)
                            }
                            .accessibilityLabel("切换触控模式，当前为\(inputPrefs.touchMode.label)")
                            .accessibilityIdentifier("session.quickTouchMode")

                            pillDivider
                        }

                        Button {
                            session.releasePressedInput()
                            if usesSideInspector && showControlHub {
                                withAnimation(.snappy(duration: 0.22)) { showControlHub = false }
                            } else {
                                hubTool = nil
                                hubDetent = .fraction(0.64)
                                withAnimation(.snappy(duration: 0.22)) { showControlHub = true }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                RabbitIcon(watchMode ? .eye : .settings, size: isLandscape ? 14 : 16)
                                    .foregroundStyle(
                                        (usesSideInspector && showControlHub)
                                            ? RCColor.accent
                                            : (watchMode ? Color(hex: 0x8AB4FF) : .white)
                                    )
                                Text(watchMode ? "观看" : "控制")
                            }
                            .padding(.horizontal, isLandscape ? 8 : 10)
                            .frame(minHeight: barHeight)
                        }
                        .accessibilityIdentifier("session.controlCenter")

                        pillDivider

                        Button {
                            withAnimation(.easeOut(duration: 0.18)) { controlsCollapsed = true }
                        } label: {
                            RabbitIcon(.chevronUp, size: 13)
                                .frame(width: isLandscape ? 28 : 34, height: barHeight)
                        }
                        .accessibilityLabel("收起会话控制栏")
                        .accessibilityIdentifier("session.collapseControls")
                    }
                    .font(isLandscape ? .caption.bold() : .subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .background(RCColor.hudBg, in: Capsule())
                    .overlay {
                        Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.28), radius: 12, y: 4)

                    if zoomPan.isZoomed && inputPrefs.controlsLeading {
                        zoomResetChip(height: barHeight, compact: isLandscape)
                    }
                }
                .simultaneousGesture(
                    DragGesture(minimumDistance: 28)
                        .onEnded { value in
                            if value.translation.width < -36, !inputPrefs.controlsLeading {
                                withAnimation(.spring(duration: 0.25)) { inputPrefs.controlsLeading = true }
                            } else if value.translation.width > 36, inputPrefs.controlsLeading {
                                withAnimation(.spring(duration: 0.25)) { inputPrefs.controlsLeading = false }
                            }
                        }
                )

                if PrefsStore.shared.showHUD && session.isConnected {
                    SessionHUD(startedAt: startedAt, hud: session.hud, codec: session.activeCodec)
                        .allowsHitTesting(false)
                }
            }
        }
        .opacity(inputPrefs.hudAlpha)
        .safeAreaPadding(.top, isLandscape ? 6 : 8)
        .safeAreaPadding(.horizontal, isLandscape ? 14 : 12)
    }

    private var pillDivider: some View {
        Divider().frame(height: 14).overlay(.white.opacity(0.22))
    }

    private func zoomResetChip(height: CGFloat, compact: Bool) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            zoomPan.reset()
        } label: {
            Text(String(format: "%.1f× 还原", zoomPan.displayScale))
                .font((compact ? Font.caption2 : Font.caption).monospacedDigit().weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, compact ? 9 : 11)
                .frame(height: height)
                .background(RCColor.accent.opacity(0.92), in: Capsule())
                .overlay {
                    Capsule().strokeBorder(.white.opacity(0.22), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
        }
        .accessibilityLabel("还原画面缩放 \(String(format: "%.1f", zoomPan.displayScale)) 倍")
        .accessibilityIdentifier("session.resetZoom")
        .transition(.scale(scale: 0.9).combined(with: .opacity))
    }

    private func toggleQuickTouchMode() {
        UISelectionFeedbackGenerator().selectionChanged()
        let next: TouchInputMode = inputPrefs.touchMode == .trackpad ? .directTouch : .trackpad
        inputPrefs.touchMode = next
        ToastCenter.shared.show(next == .trackpad ? "已切换为精密触控板" : "已切换为直点触控")
    }

    // MARK: - 连接中 / 自动重连 / 断开常驻状态卡

    static func connectionProgressStep(for state: SessionState) -> Int {
        switch state {
        case .idle:
            return 1
        case .connecting(let phase):
            switch phase {
            case "endpoint_creating": return 1
            case "connecting": return 2
            case "awaiting_welcome": return 3
            case "first_frame_pending": return 4
            default: return 2
            }
        case .reconnecting, .switching:
            return 3
        case .negotiated:
            return 4
        case .ended:
            return 0
        }
    }

    @ViewBuilder
    private var connectionModeSegmentedStrip: some View {
        if directAddr == nil {
            VStack(alignment: .leading, spacing: 6) {
                Text("连接模式")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.white.opacity(0.55))
                HStack(spacing: 6) {
                    ForEach(ConnectionMode.allCases) { item in
                        let selected = prefs.connectionMode == item
                        Button {
                            guard !selected else { return }
                            switchConnectionModeAndReconnect(item)
                        } label: {
                            Text(item.shortLabel)
                                .font(.caption.weight(selected ? .semibold : .regular))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity, minHeight: 32)
                                .background(
                                    selected ? RCColor.accent : Color.white.opacity(0.08),
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("session.connMode.\(item.rawValue)")
                    }
                }
            }
        }
    }

    private var reconnectingCard: some View {
        let currentAttempt: Int
        let maxAttempts: Int
        let detailText: String
        switch session.state {
        case .reconnecting(let att, let maxAtt, let reason):
            currentAttempt = att
            maxAttempts = maxAtt
            detailText = reason
        case .switching(let reason):
            currentAttempt = max(1, autoReconnectAttempt)
            maxAttempts = Self.maxAutoReconnectAttempts
            detailText = reason
        default:
            currentAttempt = max(1, autoReconnectAttempt)
            maxAttempts = Self.maxAutoReconnectAttempts
            detailText = autoReconnectReason ?? "网络波动，正在尝试恢复连接…"
        }

        return VStack(spacing: 16) {
            HStack(spacing: 12) {
                ProgressView().tint(RCColor.accent)
                    .frame(width: 42, height: 42)
                    .background(RCColor.accent.opacity(0.16), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text("正在自动重连 (\(currentAttempt)/\(max(currentAttempt, maxAttempts)))")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text(detailText)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.68))
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }

            connectionModeSegmentedStrip

            HStack(spacing: 10) {
                Button {
                    cancelAutoReconnect()
                    session.close()
                } label: {
                    Text("停止重连")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)

                Button {
                    triggerReconnectNow()
                } label: {
                    Text("立即重试")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background(RCColor.accent, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("session.reconnectNow")
            }
        }
        .padding(20)
        .frame(maxWidth: 380)
        .background(RCColor.hudBg, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.32), radius: 20, y: 8)
        .padding(.horizontal, 20)
        .accessibilityIdentifier("session.reconnectingCard")
    }

    private var connectingCard: some View {
        let step = Self.connectionProgressStep(for: session.state)
        let isCompact = verticalClass == .compact
        return VStack(spacing: isCompact ? 14 : 18) {
            HStack(spacing: 12) {
                RabbitIcon(directAddr != nil ? .server : .computer, size: 22)
                    .foregroundStyle(RCColor.accent)
                    .frame(width: 44, height: 44)
                    .background(RCColor.accent.opacity(0.16), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(device.name)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text("\(targetSubtitle) · \(watchMode ? "仅查看" : "远程控制")")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.62))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 6) {
                ForEach(1...4, id: \.self) { idx in
                    Capsule()
                        .fill(idx <= step ? RCColor.accent : Color.white.opacity(0.14))
                        .frame(height: 4)
                }
            }
            .animation(.easeOut(duration: 0.22), value: step)

            HStack(spacing: 10) {
                ProgressView().tint(.white).controlSize(.small)
                Text(session.state == .idle ? "正在准备连接通道…" : session.state.displayText)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.88))
                Spacer()
                Button("取消") {
                    cancelAutoReconnect()
                    dismiss()
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white.opacity(0.75))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.10), in: Capsule())
            }
        }
        .padding(20)
        .frame(maxWidth: 360)
        .background(RCColor.hudBg, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.32), radius: 20, y: 8)
        .padding(.horizontal, 20)
    }

    private func disconnectedCard(reason: String) -> some View {
        let isCompact = verticalClass == .compact
        return ScrollView {
            VStack(spacing: isCompact ? 12 : 16) {
                HStack(spacing: 12) {
                    RabbitIcon(.sessionEnded, size: 22)
                        .foregroundStyle(RCColor.warning)
                        .frame(width: 42, height: 42)
                        .background(RCColor.warning.opacity(0.16), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("连接已结束")
                            .font(.headline)
                            .foregroundStyle(.white)
                        Text(device.name)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(1)
                    }
                    Spacer()
                }

                if let uiErr = session.endedUiError ?? connectionUiError {
                    RCInlineErrorView(error: uiErr, onDarkStage: true)
                } else {
                    Text(reason)
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.88))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .textSelection(.enabled)
                }

                connectionModeSegmentedStrip

                HStack(spacing: 10) {
                    RabbitIcon(.lock, size: 16)
                        .foregroundStyle(.white.opacity(0.55))
                    Group {
                        if showRetryPassword {
                            TextField("远端连接密码（如需）", text: $retryPassword)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        } else {
                            SecureField("远端连接密码（如需）", text: $retryPassword)
                        }
                    }
                    .textContentType(.password)
                    .submitLabel(.go)
                    .onSubmit { triggerReconnectNow() }
                    .foregroundStyle(.white)

                    if !retryPassword.isEmpty {
                        Button {
                            showRetryPassword.toggle()
                        } label: {
                            RabbitIcon(showRetryPassword ? .eyeOff : .eye, size: 16)
                                .foregroundStyle(.white.opacity(0.65))
                                .frame(width: 28, height: 28)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(showRetryPassword ? "隐藏密码" : "显示密码")
                    }
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 42)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                }

                HStack(spacing: 10) {
                    Button {
                        cancelAutoReconnect()
                        dismiss()
                    } label: {
                        Text("返回")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, minHeight: 42)
                            .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)

                    Button {
                        triggerReconnectNow()
                    } label: {
                        Text("重新连接")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, minHeight: 42)
                            .background(RCColor.accent, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(20)
            .frame(maxWidth: 380)
            .background(RCColor.hudBg, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.32), radius: 20, y: 8)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)
            .padding(.vertical, isCompact ? 12 : 24)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollDismissesKeyboard(.interactively)
        .safeAreaPadding(.top, isCompact ? 42 : 64)
    }

    private var mockPreviewStage: some View {
        VStack(spacing: 8) {
            RabbitIcon(watchMode ? .eye : .computer, size: 28)
                .foregroundStyle(.white.opacity(0.65))
            Text("会话预览")
                .font(.headline)
                .foregroundStyle(.white)
            Text("\(device.name) · \(watchMode ? "仅查看" : inputPrefs.touchMode.label)")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.55))
        }
    }

    private func openSession() async {
        guard !AuthService.uiTestingMock else { return }
        session.close()
        startedAt = .now
        connectionError = nil
        connectionUiError = nil
        let password = retryPassword.isEmpty ? connectionPassword : retryPassword
        if let directAddr {
            session.open(connectAddr: directAddr, password: password, watchOnly: mode == .watch)
            return
        }
        let id = device.id.replacingOccurrences(of: " ", with: "")
        if id.count == 9, RuntimeService.shared.signalRunning {
            do {
                let result = try await RuntimeService.connect(
                    targetID: id,
                    password: password,
                    watchOnly: mode == .watch,
                    lanDirectAddr: LANDiscoveryService.shared.directAddr(forDeviceID: id),
                    connectionMode: prefs.connectionMode
                )
                guard !Task.isCancelled else { SessionService.releaseSession(result.sessionID); return }
                session.adopt(sessionID: result.sessionID, watchOnly: mode == .watch, deviceID: device.id)
            } catch {
                if !Task.isCancelled {
                    let uiErr = (error as? AuthService.AuthError)?.uiError
                        ?? RCUiErrorCodec.fromError(error)
                    connectionUiError = uiErr
                    connectionError = uiErr.message
                    if isAutoReconnecting, autoReconnectAttempt < Self.maxAutoReconnectAttempts {
                        let nonRetryable = uiErr.code.hasPrefix("auth.")
                            || uiErr.code.hasPrefix("pki.")
                            || uiErr.code == RCErrorCodes.proxyConfigConflict
                            || uiErr.code == RCErrorCodes.accountDisabled
                        if nonRetryable {
                            cancelAutoReconnect()
                        } else {
                            scheduleAutoReconnect(reason: uiErr.message, immediateDelaySec: nil)
                        }
                    } else {
                        isAutoReconnecting = false
                    }
                }
            }
        } else {
            let uiErr = CoreClient.resolveUiError(code: RCErrorCodes.signalNotStarted)
            connectionUiError = uiErr
            connectionError = uiErr.message
            if isAutoReconnecting, autoReconnectAttempt < Self.maxAutoReconnectAttempts {
                scheduleAutoReconnect(reason: uiErr.message, immediateDelaySec: 1.5)
            } else {
                isAutoReconnecting = false
            }
        }
    }
}

struct SessionHUD: View {
    enum SignalQuality: Equatable {
        case good
        case fair
        case poor
        case unknown

        var color: Color {
            switch self {
            case .good: RCColor.online
            case .fair: RCColor.warning
            case .poor: RCColor.danger
            case .unknown: Color(hex: 0x98989D)
            }
        }
    }

    var startedAt: Date
    /// 没有测量值时显示占位符，不当作零。
    var hud: [String: Any]?
    var codec: VideoCodec? = nil

    static func formatBitrate(_ kbps: Double?) -> String {
        guard let kbps else { return "—" }
        if kbps >= 1000 {
            return String(format: "%.1f Mbps", kbps / 1000.0)
        }
        return String(format: "%.0f Kbps", kbps)
    }

    static func formatFrameTime(_ ms: Double?) -> String? {
        guard let ms, ms >= 0 else { return nil }
        if ms < 10 {
            return String(format: "帧 %.1f ms", ms)
        }
        return String(format: "帧 %.0f ms", ms)
    }

    static func evaluateSignal(rttMs: Double?, lossPct: Double?) -> SignalQuality {
        guard rttMs != nil || lossPct != nil else { return .unknown }
        let rtt = rttMs ?? 0
        let loss = lossPct ?? 0
        if rtt >= 110 || loss >= 2.5 { return .poor }
        if rtt >= 45 || loss >= 0.6 { return .fair }
        return .good
    }

    private var resolutionLabel: String {
        hud?["resolution"] as? String ?? "—"
    }

    private var transportLabel: String {
        hud?["transport"] as? String ?? "—"
    }

    private var rttNumber: Double? { (hud?["rtt_ms"] as? NSNumber)?.doubleValue }
    private var frameMsNumber: Double? { (hud?["frame_ms"] as? NSNumber)?.doubleValue }
    private var lossNumber: Double? { (hud?["loss_pct"] as? NSNumber)?.doubleValue }
    private var bitrateNumber: Double? { (hud?["bitrate_kbps"] as? NSNumber)?.doubleValue }

    private func fmt(_ value: Any?, digits: Int) -> String {
        guard let number = (value as? NSNumber)?.doubleValue else { return "—" }
        return String(format: "%.\(digits)f", number)
    }

    var body: some View {
        let quality = Self.evaluateSignal(rttMs: rttNumber, lossPct: lossNumber)
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Circle()
                    .fill(quality.color)
                    .frame(width: 7, height: 7)
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    Text(elapsed(at: context.date))
                        .foregroundStyle(.white)
                        .fontWeight(.semibold)
                }
                Text("·").foregroundStyle(.white.opacity(0.35))
                Text(transportLabel)
                    .foregroundStyle(Color(hex: 0x8AB4FF))
                if let codec {
                    Text("·").foregroundStyle(.white.opacity(0.35))
                    Text(codec.shortLabel)
                        .foregroundStyle((codec == .av1 || codec == .hevc) ? Color(hex: 0x6EE7B7) : Color(hex: 0xB8B8BE))
                }
                if resolutionLabel != "—" {
                    Text("·").foregroundStyle(.white.opacity(0.35))
                    Text(resolutionLabel)
                        .foregroundStyle(Color(hex: 0xB8B8BE))
                }
            }

            HStack(spacing: 6) {
                Text("\(fmt(hud?["fps"], digits: 0)) fps")
                Text("·").foregroundStyle(.white.opacity(0.3))
                Text(Self.formatBitrate(bitrateNumber))
                Text("·").foregroundStyle(.white.opacity(0.3))
                Text("\(fmt(hud?["rtt_ms"], digits: 0)) ms")
                if let frameText = Self.formatFrameTime(frameMsNumber) {
                    Text("·").foregroundStyle(.white.opacity(0.3))
                    Text(frameText)
                }
                if let loss = lossNumber, loss > 0 {
                    Text("·").foregroundStyle(.white.opacity(0.3))
                    Text(String(format: "%.1f%% 丢包", loss))
                        .foregroundStyle(loss >= 2.0 ? RCColor.danger : RCColor.warning)
                }
            }
            .foregroundStyle(Color(hex: 0xAEAEB4))
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RCColor.hudBg, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        }
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
