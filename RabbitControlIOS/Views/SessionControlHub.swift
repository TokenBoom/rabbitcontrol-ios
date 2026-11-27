import SwiftUI
import UIKit

struct SessionControlHub: View {
    var session: SessionService
    var device: Device
    var watchOnly: Bool
    @Binding var showMouseTools: Bool
    var initialTool: DeviceDetailView.QuickTool? = nil
    var embeddedInInspector = false
    var onSelectInspectorTool: ((DeviceDetailView.QuickTool) -> Void)? = nil
    var onSelectKeyboardInspector: (() -> Void)? = nil
    var onSwitchConnectionMode: ((ConnectionMode) -> Void)? = nil
    var onReplayGuide: (() -> Void)? = nil
    var onExit: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var prefs = PrefsStore.shared
    @State private var input = InteractionPrefs.shared
    @State private var confirmExit = false
    @State private var confirmLock = false
    @State private var showFingerprintDetail = false
    @State private var isExecutingRemoteOp = false
    @State private var clipboardMessage: String?
    @State private var navPath: [DeviceDetailView.QuickTool] = []

    private var effectiveWatchOnly: Bool { watchOnly || session.effectiveWatchOnly }
    private var canControl: Bool { session.isConnected && !effectiveWatchOnly }

    var body: some View {
        NavigationStack(path: $navPath) {
            List {
                statusAndQuickActionsSection

                if !session.peerWatchOnly {
                    sessionModeAndRouteSection
                }

                if !effectiveWatchOnly {
                    manipulationSection
                    sessionToolsSection
                }

                displaySection

                if !effectiveWatchOnly, let display = session.display {
                    Section {
                        multiDisplayControls
                        codecMenu(display: display)
                        resolutionMenu(display: display)
                        fpsMenu(display: display)
                        Toggle(
                            "静止画面无损文字锐化",
                            isOn: Binding(
                                get: { session.stillRefinementEnabled },
                                set: { session.setStillRefinementEnabled($0) }
                            )
                        )
                        advisoryActions(display: display)
                    } header: {
                        Text("显示器与视频流")
                    } footer: {
                        streamSectionFooter(display: display)
                    }
                    .disabled(!canControl || isExecutingRemoteOp)
                }

                if !effectiveWatchOnly {
                    clipboardSection
                }

                securityAndAudioSection
            }
            .navigationTitle(effectiveWatchOnly ? "观看设置" : "会话控制")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(embeddedInInspector ? .hidden : .visible, for: .navigationBar)
            .navigationDestination(for: DeviceDetailView.QuickTool.self) { tool in
                switch tool {
                case .files:
                    FileTransferView(device: device).modifier(ConnectedTool(session: session))
                case .terminal:
                    TerminalView().modifier(ConnectedTool(session: session))
                case .portMapping:
                    PortMappingView(device: device).modifier(ConnectedTool(session: session))
                case .hub:
                    EmptyView()
                }
            }
            .toolbar {
                if !embeddedInInspector {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("结束", role: .destructive) { confirmExit = true }
                            .accessibilityLabel("结束远程协助")
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { dismiss() }
                    }
                }
            }
            .confirmationDialog("结束本次远程协助？", isPresented: $confirmExit, titleVisibility: .visible) {
                Button("结束会话", role: .destructive, action: onExit)
            }
            .confirmationDialog("锁定远端屏幕？", isPresented: $confirmLock, titleVisibility: .visible) {
                Button("锁屏", role: .destructive) { session.lockRemoteScreen() }
            }
            .onAppear {
                if canControl, let sid = session.sessionID {
                    ToolService.shared.start(sessionID: sid)
                }
                if !effectiveWatchOnly, let initialTool, initialTool != .hub, navPath.isEmpty, isToolAllowed(initialTool) {
                    navPath = [initialTool]
                }
            }
            .onChange(of: session.toolPermissions) { _, perms in
                if navPath.last == .files && !perms.allowFileTransfer {
                    navPath.removeLast()
                } else if navPath.last == .terminal && !perms.allowTerminal {
                    navPath.removeLast()
                } else if navPath.last == .portMapping && !perms.allowPortMap {
                    navPath.removeLast()
                }
            }
        }
    }

    // MARK: - 状态、安全盾与顶部快捷磁贴

    private var statusAndQuickActionsSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    RabbitIcon(device.kind == .mac ? .computer : .desktopPC, size: 20)
                        .foregroundStyle(RCColor.accent)
                        .frame(width: 38, height: 38)
                        .background(RCColor.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(device.name)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                            if session.mutuallyAuthenticated == true {
                                Button {
                                    withAnimation(.easeOut(duration: 0.16)) {
                                        showFingerprintDetail.toggle()
                                    }
                                } label: {
                                    HStack(spacing: 3) {
                                        RabbitIcon(.security, size: 11)
                                        Text("mTLS 已加密")
                                    }
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(RCColor.online)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(RCColor.online.opacity(0.12), in: Capsule())
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("hub.securityShield")
                            }
                            if session.hostScreenLocked {
                                Text("远端锁屏")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(RCColor.warning)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(RCColor.warning.opacity(0.14), in: Capsule())
                            }
                        }
                        HStack(spacing: 6) {
                            Circle()
                                .fill(session.isConnected ? RCColor.online : RCColor.warning)
                                .frame(width: 7, height: 7)
                            Text("\(session.state.displayText) · \(effectiveWatchOnly ? "仅查看模式" : input.touchMode.label)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }

                if showFingerprintDetail {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("安全盾连接摘要")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(RCColor.textPrimary)
                        if let fp = session.peerCertFingerprint, !fp.isEmpty {
                            HStack(alignment: .top, spacing: 6) {
                                Text("对端证书指纹 (SHA-256)：\(fp)")
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(RCColor.textSecondary)
                                    .textSelection(.enabled)
                                Spacer(minLength: 4)
                                Button("复制") {
                                    UIPasteboard.general.string = fp
                                    ToastCenter.shared.show("已复制对端证书指纹")
                                }
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(RCColor.accent)
                                .buttonStyle(.plain)
                            }
                        } else {
                            Text("端到端 QUIC / mTLS 通道已激活")
                                .font(.caption2)
                                .foregroundStyle(RCColor.textSecondary)
                        }
                        Text("防窥状态：\(session.privacyState?.enabled == true ? "已开启" : "未开启") · 被控静音：\(session.hostMuteState?.muted == true ? "已静音" : "正常") · 断开锁屏：\(prefs.lockRemoteOnDisconnect ? "开启" : "关闭")")
                            .font(.caption2)
                            .foregroundStyle(RCColor.textSecondary)
                    }
                    .padding(10)
                    .background(RCColor.bgPage, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .transition(.opacity)
                }
            }
            .padding(.vertical, 2)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: effectiveWatchOnly ? 2 : 4), spacing: 8) {
                if !effectiveWatchOnly {
                    quickTile(
                        title: input.touchMode == .trackpad ? "触控板" : "直点触控",
                        icon: input.touchMode == .trackpad ? .mouse : .cursor,
                        active: input.touchMode == .trackpad,
                        enabled: true
                    ) {
                        UISelectionFeedbackGenerator().selectionChanged()
                        input.touchMode = input.touchMode == .trackpad ? .directTouch : .trackpad
                    }
                }

                quickTile(
                    title: session.audioMuted ? "已静音" : "远端声音",
                    icon: .speaker,
                    active: !session.audioMuted && session.isConnected,
                    enabled: session.isConnected
                ) {
                    UISelectionFeedbackGenerator().selectionChanged()
                    session.setAudioMuted(!session.audioMuted)
                }

                quickTile(
                    title: "连接统计",
                    icon: .display,
                    active: prefs.showHUD,
                    enabled: true
                ) {
                    UISelectionFeedbackGenerator().selectionChanged()
                    prefs.showHUD.toggle()
                }

                if !effectiveWatchOnly {
                    quickTile(
                        title: "刷新画面",
                        icon: .restart,
                        active: false,
                        enabled: canControl
                    ) {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        if session.requestIDR() {
                            ToastCenter.shared.show("已请求重同步视频流")
                        }
                    }
                }
            }
            .padding(.vertical, 4)
            .listRowInsets(EdgeInsets(top: 8, leading: 14, bottom: 10, trailing: 14))
        } header: {
            Text(effectiveWatchOnly ? "仅查看设备" : "快捷控制")
        }
    }

    private var sessionModeAndRouteSection: some View {
        Section {
            if watchOnly == false {
                Toggle(
                    isOn: Binding(
                        get: { session.localWatchOnly },
                        set: { session.setWatchOnly($0) }
                    )
                ) {
                    Label("观看模式（只看不发键鼠操作）", rabbitIcon: .eye)
                }
                .accessibilityIdentifier("hub.watchOnlyToggle")
            }

            if let onSwitchConnectionMode {
                Picker(
                    selection: Binding(
                        get: { prefs.connectionMode },
                        set: { newMode in
                            guard newMode != prefs.connectionMode else { return }
                            onSwitchConnectionMode(newMode)
                            dismiss()
                        }
                    )
                ) {
                    ForEach(ConnectionMode.allCases) { item in
                        Text(item.label).tag(item)
                    }
                } label: {
                    Label("连接路由模式", rabbitIcon: .server)
                }
                .accessibilityIdentifier("hub.connectionMode")
            }
        } footer: {
            if onSwitchConnectionMode != nil {
                Text("切换连接模式后将平滑重建链路并应用新的路由策略。")
            }
        }
    }

    private func quickTile(
        title: String,
        icon: RabbitIcon.Name,
        active: Bool,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                RabbitIcon(icon, size: 18)
                    .foregroundStyle(active ? RCColor.accent : RCColor.textPrimary)
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(active ? RCColor.accent : RCColor.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity, minHeight: 58)
            .background(
                active ? RCColor.accent.opacity(0.12) : Color.secondary.opacity(0.08),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(active ? RCColor.accent.opacity(0.35) : .clear, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
    }

    // MARK: - 多显示器与虚拟屏控制（§5.3）

    @ViewBuilder
    private var multiDisplayControls: some View {
        if let displaysState = session.displaysState, let active = displaysState.activeDisplay {
            if displaysState.displays.count > 1 {
                Menu {
                    ForEach(displaysState.displays) { disp in
                        Button {
                            runRemoteOp { await session.switchRemoteDisplay(id: disp.id) }
                        } label: {
                            let tag = disp.isVirtual ? " · 虚拟屏" : (disp.isMain ? " · 主屏" : "")
                            let title = "\(disp.name) (\(disp.width)×\(disp.height))\(tag)"
                            if disp.id == active.id {
                                Label(title, rabbitIcon: .checkmark)
                            } else {
                                Text(title)
                            }
                        }
                    }
                } label: {
                    Label("当前屏幕：\(active.name)（共 \(displaysState.displays.count) 屏）", rabbitIcon: .display)
                }
                .accessibilityIdentifier("session.displaySwitcher")
            } else {
                LabeledContent {
                    Text(active.isVirtual ? "\(active.name) · 虚拟屏" : active.name)
                        .foregroundStyle(.secondary)
                } label: {
                    Label("当前显示器", rabbitIcon: .display)
                }
            }

            Menu {
                Button("新建 1920 × 1080 (HiDPI 虚拟屏)") {
                    runRemoteOp { await session.createRemoteVirtualDisplay(width: 1920, height: 1080, hidpi: true) }
                }
                Button("新建 2560 × 1440 (2K HiDPI 虚拟屏)") {
                    runRemoteOp { await session.createRemoteVirtualDisplay(width: 2560, height: 1440, hidpi: true) }
                }
                if active.isVirtual {
                    Divider()
                    Button("销毁当前虚拟显示器", role: .destructive) {
                        runRemoteOp { await session.removeRemoteVirtualDisplay(id: active.id) }
                    }
                }
            } label: {
                Label("虚拟显示器管理", rabbitIcon: .plus)
            }
            .accessibilityIdentifier("session.virtualDisplayMenu")
        }
    }

    private func runRemoteOp(_ op: @escaping () async -> RCUiError?) {
        guard !isExecutingRemoteOp else { return }
        isExecutingRemoteOp = true
        Task {
            defer { isExecutingRemoteOp = false }
            if let err = await op() {
                RCErrorCenter.shared.present(err)
            }
        }
    }

    // MARK: - 操控与会话内工具

    private var manipulationSection: some View {
        Section {
            Picker(selection: $input.touchMode) {
                ForEach(TouchInputMode.allCases, id: \.self) { Text($0.label).tag($0) }
            } label: {
                Label("触控模式", rabbitIcon: .cursor)
            }

            if input.touchMode == .trackpad {
                HStack {
                    Label("指针灵敏度", rabbitIcon: .mouse)
                    Slider(value: $input.pointerSensitivity, in: 0.5...2.5, step: 0.05)
                    Text(String(format: "%.2fx", input.pointerSensitivity))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            Toggle(isOn: $input.naturalScroll) {
                Label("自然滚动方向", rabbitIcon: .arrowDown)
            }
            Toggle(isOn: $showMouseTools) {
                Label("在桌面上显示鼠标工具", rabbitIcon: .mouse)
            }

            if let onReplayGuide {
                Button(action: onReplayGuide) {
                    Label("查看手势操作指南", rabbitIcon: .watchScreen)
                }
                .accessibilityIdentifier("hub.replayGuide")
            }
        } header: {
            Text("操控")
        } footer: {
            Text(canControl ? "轻点左键，长按后滑动或轻点后再次触按滑动可拖拽窗口与选区；长按原地松手或双指轻点触发右键，双指滚动，捏合缩放。" : "连接成功后可使用操控与远程工具。")
        }
    }

    private func isToolAllowed(_ tool: DeviceDetailView.QuickTool) -> Bool {
        switch tool {
        case .files: session.toolPermissions.allowFileTransfer
        case .terminal: session.toolPermissions.allowTerminal
        case .portMapping: session.toolPermissions.allowPortMap
        case .hub: true
        }
    }

    private var sessionToolsSection: some View {
        Section("会话工具") {
            if let onSelectKeyboardInspector {
                Button(action: onSelectKeyboardInspector) {
                    HStack {
                        Label("远程键盘与系统组合键", rabbitIcon: .keyboard)
                            .foregroundStyle(RCColor.textPrimary)
                        Spacer()
                        RabbitIcon(.chevronRight, size: 14)
                            .foregroundStyle(RCColor.textDisabled)
                    }
                }
            } else {
                NavigationLink {
                    RemoteKeyboard(session: session, deviceKind: device.kind).modifier(ConnectedTool(session: session))
                } label: {
                    Label("远程键盘与系统组合键", rabbitIcon: .keyboard)
                }
            }
            toolRow(tool: .files, title: "文件传输", icon: .fileTransfer, allowed: session.toolPermissions.allowFileTransfer)
            toolRow(tool: .terminal, title: "远程终端", icon: .terminal, allowed: session.toolPermissions.allowTerminal)
            toolRow(tool: .portMapping, title: "端口映射", icon: .portMap, allowed: session.toolPermissions.allowPortMap)
        }
        .disabled(!canControl)
    }

    @ViewBuilder
    private func toolRow(
        tool: DeviceDetailView.QuickTool,
        title: String,
        icon: RabbitIcon.Name,
        allowed: Bool
    ) -> some View {
        if allowed {
            if let onSelectInspectorTool {
                Button {
                    onSelectInspectorTool(tool)
                } label: {
                    HStack {
                        Label(title, rabbitIcon: icon)
                            .foregroundStyle(RCColor.textPrimary)
                        Spacer()
                        RabbitIcon(.chevronRight, size: 14)
                            .foregroundStyle(RCColor.textDisabled)
                    }
                }
            } else {
                NavigationLink(value: tool) {
                    Label(title, rabbitIcon: icon)
                }
            }
        } else {
            Button {
                let uiErr = CoreClient.resolveUiError(code: RCErrorCodes.toolForbidden)
                RCErrorCenter.shared.present(uiErr)
            } label: {
                HStack {
                    Label(title, rabbitIcon: icon)
                        .foregroundStyle(RCColor.textDisabled)
                    Spacer()
                    Text("对方已禁用")
                        .font(.caption)
                        .foregroundStyle(RCColor.textSecondary)
                }
            }
            .accessibilityIdentifier("hub.toolDisabled.\(tool.rawValue)")
        }
    }

    // MARK: - 显示、剪贴板与安全

    private var displaySection: some View {
        Section {
            if UIDevice.current.userInterfaceIdiom != .pad {
                Picker(selection: $input.orientation) {
                    ForEach(SessionOrientation.allCases, id: \.self) { Text($0.label).tag($0) }
                } label: {
                    Label("屏幕方向", rabbitIcon: .display)
                }

                if !effectiveWatchOnly {
                    Picker(selection: $input.portraitLayout) {
                        ForEach(PortraitLayout.allCases, id: \.self) { Text($0.label).tag($0) }
                    } label: {
                        Label("竖屏布局", rabbitIcon: .display)
                    }
                }
            }

            Toggle("控制栏停靠在左侧", isOn: $input.controlsLeading)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("控制栏不透明度")
                    Spacer()
                    Text("\(Int(input.hudAlpha * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(value: $input.hudAlpha, in: 0.35...1)
                    .accessibilityLabel("控制栏不透明度")
            }

            Toggle("显示连接统计", isOn: $prefs.showHUD)

            if !effectiveWatchOnly {
                Picker("画质档位", selection: $prefs.qualityPreset) {
                    ForEach(PrefsStore.QualityPreset.allCases) { Text($0.rawValue).tag($0) }
                }
                .onChange(of: prefs.qualityPreset) {
                    if canControl { session.setBitrate(prefs.effectiveBitrateBps) }
                }
                .disabled(!canControl)
            }
        } header: {
            Text("显示与布局")
        } footer: {
            Text(effectiveWatchOnly ? "观看模式仅支持缩放和平移查看，不发送任何输入或工具指令。" : "顶部悬浮胶囊也支持左右横滑直接切换停靠边。")
        }
    }

    private var clipboardSection: some View {
        Section {
            Toggle(isOn: Binding(get: { session.clipboardEnabled }, set: {
                session.setClipboardEnabled($0)
                clipboardMessage = nil
            })) {
                Label("本次会话交换文本", rabbitIcon: .clipboard)
            }
            if session.clipboardEnabled {
                PasteButton(payloadType: String.self) { items in
                    guard let text = items.first else { return }
                    clipboardMessage = session.sendClipboard(text)
                        ? "文本已发送至远端剪贴板。"
                        : "未发送：请稍后重试，文本不能超过 65535 字节。"
                }
                .accessibilityLabel("粘贴并发送到 Mac")

                Button("复制远端最近共享的文本") {
                    if let text = session.receivedText {
                        UIPasteboard.general.setItems([["public.utf8-plain-text": text]], options: [.localOnly: true])
                        clipboardMessage = "已复制到本机剪贴板。"
                    }
                }
                .disabled(session.receivedText == nil)

                if let clipboardMessage {
                    Text(clipboardMessage).font(.footnote).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("文本剪贴板")
        } footer: {
            Text("仅在你主动点击粘贴时发送；收到的文本不会自动覆盖本机剪贴板。")
        }
        .disabled(!canControl)
    }

    private var securityAndAudioSection: some View {
        Section("音频、防窥与远端维护") {
            Toggle(isOn: Binding(get: { session.audioMuted }, set: { session.setAudioMuted($0) })) {
                Label("静音本机播放的远端声音", rabbitIcon: .speaker)
            }
            .disabled(!session.isConnected)

            if let hostMute = session.hostMuteState, hostMute.supported, !effectiveWatchOnly {
                Toggle(
                    isOn: Binding(
                        get: { hostMute.muted },
                        set: { newMuted in runRemoteOp { await session.setRemoteHostMute(newMuted) } }
                    )
                ) {
                    Label("被控端本机静音运行", rabbitIcon: .speaker)
                }
                .disabled(!canControl || isExecutingRemoteOp)
            } else if let hostMute = session.hostMuteState, hostMute.supported {
                LabeledContent {
                    Text(hostMute.muted ? "已静音" : "正常外放").foregroundStyle(.secondary)
                } label: {
                    Label("远端本机扬声器", rabbitIcon: .speaker)
                }
            }

            if let privacy = session.privacyState, privacy.supported, !effectiveWatchOnly {
                let currentMode = privacy.mode ?? (privacy.enabled ? "black" : "off")
                Menu {
                    Button {
                        runRemoteOp { await session.setRemotePrivacyMode("off") }
                    } label: {
                        if currentMode == "off" || !privacy.enabled {
                            Label("关闭防窥屏", rabbitIcon: .checkmark)
                        } else { Text("关闭防窥屏") }
                    }
                    Button {
                        runRemoteOp { await session.setRemotePrivacyMode("black") }
                    } label: {
                        if privacy.enabled && currentMode == "black" {
                            Label("黑屏防窥模式", rabbitIcon: .checkmark)
                        } else { Text("黑屏防窥模式") }
                    }
                    Button {
                        runRemoteOp { await session.setRemotePrivacyMode("privacy") }
                    } label: {
                        if privacy.enabled && currentMode == "privacy" {
                            Label("隐私屏保幕布", rabbitIcon: .checkmark)
                        } else { Text("隐私屏保幕布") }
                    }
                } label: {
                    Label("远端防窥模式：\(privacy.enabled ? (currentMode == "privacy" ? "隐私屏保" : "黑屏防窥") : "未开启")", rabbitIcon: .eyeOff)
                }
                .disabled(!canControl || isExecutingRemoteOp)
            } else if let privacy = session.privacyState, privacy.supported {
                LabeledContent {
                    Text(privacy.enabled ? "已开启" : "未开启")
                        .foregroundStyle(privacy.enabled ? RCColor.online : .secondary)
                } label: {
                    Label("远端防窥屏", rabbitIcon: .eyeOff)
                }
            }

            if let hostInfo = session.hostInfo {
                LabeledContent {
                    let osPart = hostInfo.os.isEmpty ? "" : " · \(hostInfo.os)"
                    Text("v\(hostInfo.version)\(osPart)")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                } label: {
                    Label("远端核心版本", rabbitIcon: .computer)
                }

                if hostInfo.isOwnerSession && hostInfo.updateCapable && !effectiveWatchOnly {
                    if let progress = session.remoteUpdateStatus {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("正在升级被控端：\(progress.message ?? progress.stage)")
                                    .font(.caption)
                                Spacer()
                                if let pct = progress.progressPct {
                                    Text("\(pct)%").font(.caption.monospacedDigit())
                                }
                            }
                            if let pct = progress.progressPct {
                                ProgressView(value: Double(pct), total: 100)
                            }
                            Button("取消远程升级", role: .destructive) {
                                runRemoteOp { await session.cancelRemoteHostUpdate() }
                            }
                            .font(.caption)
                        }
                    } else if hostInfo.version != CoreClient.coreVersion {
                        Button {
                            runRemoteOp { await session.triggerRemoteHostUpdate() }
                        } label: {
                            Label("升级被控端至最新版本", rabbitIcon: .download)
                        }
                        .disabled(!canControl || isExecutingRemoteOp)
                    }
                }
            }

            if !effectiveWatchOnly {
                Toggle("结束会话时自动锁定远端屏幕", isOn: $prefs.lockRemoteOnDisconnect)
                    .disabled(!canControl)

                Button(role: .destructive) {
                    confirmLock = true
                } label: {
                    Label("立即锁定远端屏幕", rabbitIcon: .security)
                }
                .disabled(!canControl)
            }
        }
    }

    @ViewBuilder
    private func advisoryActions(display: SessionService.DisplayConfig) -> some View {
        if let advisory = display.advisory, advisory.level != "optimal" {
            if advisory.canEnableHevc, display.canUseHevc, (display.codec ?? .h264) != .hevc {
                Button {
                    session.setCodec(.hevc)
                } label: {
                    Label("启用 H.265 优化高刷画质", rabbitIcon: .checkmark)
                }
            }
            if let rw = advisory.recommendedWidth,
               let rh = advisory.recommendedHeight,
               (rw != display.width || rh != display.height),
               display.presets.contains(where: { $0.width == rw && $0.height == rh }) {
                Button {
                    session.setStream(width: rw, height: rh)
                } label: {
                    Label("采用推荐分辨率（\(rw) × \(rh)）", rabbitIcon: .display)
                }
            }
        }
    }

    @ViewBuilder
    private func streamSectionFooter(display: SessionService.DisplayConfig) -> some View {
        if let err = session.virtualDisplayError, !err.isEmpty {
            Text("虚拟显示器异常：\(err)")
                .foregroundStyle(RCColor.warning)
        } else if let hint = display.advisory?.localizedHint {
            Text(hint)
        } else if display.canUseAv1, (display.codec ?? .h264) != .av1 {
            Text("当前两端均支持 AV1 硬件编解码，切换后可在更低带宽下获得更清晰的桌面文字表现。")
        } else if display.canUseHevc, (display.codec ?? .h264) == .h264 {
            Text("当前两端均支持 H.265，切换后可降低同画质码率并解锁更高清的 HiDPI 分辨率预设。")
        }
    }

    @ViewBuilder
    private func codecMenu(display: SessionService.DisplayConfig) -> some View {
        let current = display.codec ?? .h264
        let codecs = display.selectableCodecs
        if codecs.count > 1 {
            Menu {
                ForEach(codecs) { codec in
                    Button {
                        session.setCodec(codec)
                    } label: {
                        let title = codec.menuOptionLabel
                        if codec == current {
                            Label(title, rabbitIcon: .checkmark)
                        } else {
                            Text(title)
                        }
                    }
                }
            } label: {
                Label("视频编码：\(current.label)", rabbitIcon: .display)
            }
            .accessibilityIdentifier("session.codecMenu")
        } else {
            LabeledContent {
                Text("\(current.shortLabel)（远端仅支持 \(current.shortLabel)）")
                    .foregroundStyle(.secondary)
            } label: {
                Label("视频编码", rabbitIcon: .display)
            }
            .accessibilityIdentifier("session.codecMenu")
        }
    }

    @ViewBuilder
    private func resolutionMenu(display: SessionService.DisplayConfig) -> some View {
        let presets: [SessionService.DisplayConfig.Preset] = {
            if display.width > 0, display.height > 0,
               !display.presets.contains(where: { $0.width == display.width && $0.height == display.height }) {
                let current = SessionService.DisplayConfig.Preset(
                    width: display.width, height: display.height,
                    label: "\(display.width) × \(display.height)（当前）"
                )
                return [current] + display.presets
            }
            return display.presets
        }()
        Menu {
            ForEach(presets, id: \.self) { preset in
                Button {
                    session.setStream(width: preset.width, height: preset.height)
                } label: {
                    if preset.width == display.width && preset.height == display.height {
                        Label(preset.label, rabbitIcon: .checkmark)
                    } else {
                        Text(preset.label)
                    }
                }
            }
        } label: {
            Label("分辨率：\(display.width) × \(display.height)", rabbitIcon: .display)
        }
    }

    @ViewBuilder
    private func fpsMenu(display: SessionService.DisplayConfig) -> some View {
        Menu {
            ForEach(Self.fpsOptions(display: display), id: \.self) { fps in
                Button {
                    session.setStream(fps: fps)
                } label: {
                    if fps == display.fps {
                        Label("\(fps) fps", rabbitIcon: .checkmark)
                    } else {
                        Text("\(fps) fps")
                    }
                }
            }
        } label: {
            Label("帧率：\(display.fps) fps", rabbitIcon: .display)
        }
    }

    /// 帧率选项:30/60/90/120,封顶 120 与主机实际上限,始终包含当前值。
    static func fpsOptions(display: SessionService.DisplayConfig) -> [Int] {
        let cap = min(max(display.maxFps, display.fps), 120)
        var list = [30, 60, 90, 120].filter { $0 <= cap }
        if display.fps > 0, !list.contains(display.fps) { list.append(display.fps) }
        return list.sorted()
    }
}

struct ConnectedTool: ViewModifier {
    var session: SessionService
    func body(content: Content) -> some View {
        if session.isConnected && !session.effectiveWatchOnly {
            content
        } else {
            ContentUnavailableView {
                Label("连接已结束", rabbitIcon: .disconnected)
            } description: {
                Text("请返回会话页重新连接。")
            }
        }
    }
}
