import SwiftUI

/// 设备详情页(P1 移动端适配):预览卡 + 双态在途会话横幅 + 「进入桌面」/「观看模式」+ 快捷工具栏 + WoL 远程开机。
struct DeviceDetailView: View {
    var device: Device
    var embeddedInSplit = false
    var onDeviceRemoved: (() -> Void)? = nil

    @State private var sessionMode: SessionMode?
    @State private var adoptExistingOnOpen = false
    @State private var saving = false
    @State private var wakingUp = false
    @State private var pendingTerminalCommand: String?

    private var account: AccountDevice? { AuthService.shared.devices.first { $0.deviceID == device.id } }
    private var online: Bool { account?.online ?? device.online }
    /// 基线 §6.4：P1 同账号设备自控仅受 `allowRemoteControl` 约束，与对外 `allowRemoteAssist` 解耦。
    private var canConnect: Bool {
        account.map { $0.online && !$0.disabled && $0.allowRemoteControl } ?? false
    }
    private var canWakeOnLAN: Bool {
        guard let account, !account.online, !account.disabled else { return false }
        return RuntimeService.shared.isWolCapable(account)
    }
    /// 当前是否已有本机指向该设备的活跃会话（纯工具或桌面在控，对齐 §3.1 双态详情页）。
    private var isActiveSessionTarget: Bool {
        let s = SessionService.shared
        guard s.isConnected, let tid = s.targetDeviceID else { return false }
        return tid.replacingOccurrences(of: " ", with: "") == device.id.replacingOccurrences(of: " ", with: "")
    }
    /// 本机(iOS 注册进账号的 controller 设备):只显示信息,不提供控制入口。
    private var isSelfDevice: Bool {
        guard let account else { return device.isSelfDevice }
        if account.os.lowercased() == "ios" { return true }
        if let own = RuntimeService.shared.deviceID {
            return account.deviceID.replacingOccurrences(of: " ", with: "") == own.replacingOccurrences(of: " ", with: "")
        }
        return false
    }

    /// 快捷入口要直达的独立工具。
    enum QuickTool: Int, Identifiable {
        var id: Int { rawValue }
        case files = 1, terminal = 2, portMapping = 3, hub = 4
    }
    @State private var quickTool: QuickTool?
    @State private var standaloneTool: QuickTool?
    @State private var hotUpgradingToDesktop = false
    @State private var showMoreTools = false
    @State private var powerConfirmKind: DevicePowerAction?
    @State private var showRename = false
    @State private var showRemoveConfirm = false
    @State private var renameText = ""
    @Environment(\.dismiss) private var dismiss

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

    private func quickAction(_ title: String, icon: RabbitIcon.Name, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                RabbitIcon(icon, size: 22)
                Text(title).font(.caption)
            }
            .foregroundStyle(RCColor.textPrimary)
            .frame(maxWidth: .infinity, minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    private var selfInfoCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("本机设备", rabbitIcon: .phone)
                .font(.headline)
            LabeledContent("设备 ID", value: device.displayID)
            if let account {
                LabeledContent("主机名", value: account.hostname.isEmpty ? "—" : account.hostname)
                LabeledContent("系统", value: account.os.isEmpty ? "—" : account.os)
            }
            Text("这是当前 iPhone / iPad 注册到账号的设备。iOS 仅作为控制端,不能被远程控制。")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(RCColor.bgWindow, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 16)
    }

    private var connectionHint: String {
        guard let account else { return "设备已不在当前账号中，请返回设备列表。" }
        if account.disabled { return "设备已被停用，暂时无法连接。" }
        if !account.online {
            if canWakeOnLAN {
                return "设备当前离线，可点击「远程开机」唤醒设备，开机后下拉可刷新在线状态。"
            }
            return "设备离线。请在对方设备上打开 RabbitControl 并检查网络，下拉可刷新状态。"
        }
        if !account.allowRemoteControl { return "请先在对方设备上允许被远程控制。" }
        return "控制模式支持键鼠与远程工具；点击文件传输或终端将按纯工具无头模式秒开，节省带宽。"
    }

    private func triggerWakeOnLAN() {
        guard !wakingUp else { return }
        if AuthService.uiTestingMock {
            ToastCenter.shared.show("已发送远程开机指令")
            return
        }
        wakingUp = true
        Task {
            defer { wakingUp = false }
            do {
                let ack = try await RuntimeService.requestWakeOnLAN(targetID: device.id)
                let msg = ack.message.trimmingCharacters(in: .whitespacesAndNewlines)
                ToastCenter.shared.show(
                    msg.isEmpty ? "已发送远程开机指令，请稍候等待设备上线" : msg,
                    severity: .info,
                    durationSeconds: 2.8
                )
                try? await Task.sleep(for: .seconds(3))
                await AuthService.shared.refreshDevices()
            } catch {
                let uiErr = RCUiErrorCodec.fromError(error, fallbackCode: RCErrorCodes.wolSendFailed)
                RCErrorCenter.shared.present(uiErr)
            }
        }
    }

    private func openMoreTool(_ action: DeviceMoreToolAction) {
        showMoreTools = false
        switch action {
        case .files:
            standaloneTool = .files
        case .watch:
            adoptExistingOnOpen = false
            sessionMode = .watch
        case .terminal:
            standaloneTool = .terminal
        case .portMapping:
            standaloneTool = .portMapping
        }
    }

    private func confirmPowerAction(_ action: DevicePowerAction) {
        powerConfirmKind = nil
        showMoreTools = false
        pendingTerminalCommand = action.command
        standaloneTool = .terminal
    }

    var body: some View {
        ScrollView {
            Group {
                if embeddedInSplit {
                    splitWorkspaceContent
                } else {
                    phoneDetailContent
                }
            }
        }
        .background(RCColor.bgPage)
        .refreshable { await AuthService.shared.refreshDevices() }
        .toolbar {
            if !embeddedInSplit {
                ToolbarItem(placement: .topBarTrailing) {
                    deviceManageMenu
                }
            }
        }
        .alert("重命名设备", isPresented: $showRename) {
            TextField("设备别名", text: $renameText)
            Button("取消", role: .cancel) {}
            Button("确定") {
                Task {
                    saving = true
                    defer { saving = false }
                    do {
                        try await AuthService.shared.renameDevice(
                            deviceID: device.id,
                            alias: renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                        )
                    } catch {
                        let uiErr = (error as? AuthService.AuthError)?.uiError ?? RCUiErrorCodec.fromError(error)
                        RCErrorCenter.shared.present(uiErr)
                    }
                }
            }.disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .alert("解绑该设备?", isPresented: $showRemoveConfirm) {
            Button("取消", role: .cancel) {}
            Button("解绑", role: .destructive) {
                Task {
                    saving = true
                    defer { saving = false }
                    do {
                        try await AuthService.shared.removeDevice(deviceID: device.id)
                        if let onDeviceRemoved {
                            onDeviceRemoved()
                        } else {
                            dismiss()
                        }
                    } catch {
                        let uiErr = (error as? AuthService.AuthError)?.uiError ?? RCUiErrorCodec.fromError(error)
                        RCErrorCenter.shared.present(uiErr)
                    }
                }
            }
        } message: {
            Text("“\(account?.displayName ?? device.name)”将从当前账号移除。")
        }
        .navigationTitle(account?.displayName ?? device.name)
        .toolbar(embeddedInSplit ? .hidden : .visible, for: .navigationBar)
        .onChange(of: device.id) {
            showMoreTools = false
            powerConfirmKind = nil
            showRename = false
            showRemoveConfirm = false
        }
        .disabled(saving)
        .accessibilityHidden(showMoreTools || powerConfirmKind != nil)
        .allowsHitTesting(!(showMoreTools || powerConfirmKind != nil))
        .overlay {
            ZStack {
                if saving {
                    ProgressView("正在保存…")
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
                if showMoreTools {
                    MoreToolsMenuView(
                        onTool: openMoreTool,
                        onPower: { powerConfirmKind = $0 },
                        onClose: { showMoreTools = false },
                        isCovered: powerConfirmKind != nil
                    )
                }
                if let powerConfirmKind {
                    DevicePowerConfirmView(
                        action: powerConfirmKind,
                        deviceName: account?.displayName ?? device.name,
                        onCancel: { self.powerConfirmKind = nil },
                        onConfirm: { confirmPowerAction(powerConfirmKind) }
                    )
                }
            }
            .animation(.easeOut(duration: 0.15), value: showMoreTools)
            .animation(.easeOut(duration: 0.15), value: powerConfirmKind)
        }
        .accessibilityHidden(sessionMode != nil || standaloneTool != nil)
        .onChange(of: sessionMode != nil || standaloneTool != nil) { _, active in
            AssistFlow.shared.sessionActive = active
        }
        .fullScreenCover(item: $sessionMode, onDismiss: {
            AssistFlow.shared.sessionActive = false
            quickTool = nil
            adoptExistingOnOpen = false
            SessionService.shared.endUserSession()
        }) { mode in
            SessionView(
                device: device,
                mode: mode,
                initialTool: mode == .control ? quickTool : nil,
                adoptExistingSession: adoptExistingOnOpen
            )
        }
        .fullScreenCover(item: $standaloneTool, onDismiss: {
            AssistFlow.shared.sessionActive = false
            pendingTerminalCommand = nil
            if hotUpgradingToDesktop {
                hotUpgradingToDesktop = false
                adoptExistingOnOpen = true
                sessionMode = .control
            } else {
                SessionService.shared.close()
            }
        }) { tool in
            StandaloneToolSessionView(
                device: device,
                tool: tool,
                prefilledTerminalCommand: tool == .terminal ? pendingTerminalCommand : nil,
                onUpgradeToDesktop: {
                    hotUpgradingToDesktop = true
                    standaloneTool = nil
                }
            )
        }
    }

    private var deviceManageMenu: some View {
        Menu {
            Button {
                renameText = account?.displayName ?? device.name
                showRename = true
            } label: {
                Label("重命名", rabbitIcon: .pencil)
            }
            Button(role: .destructive) {
                showRemoveConfirm = true
            } label: {
                Label("解绑设备", rabbitIcon: .trash)
            }
        } label: {
            RabbitIcon(.ellipsis, size: embeddedInSplit ? 20 : 22)
                .foregroundStyle(RCColor.textPrimary)
                .frame(width: 36, height: 36)
                .background(embeddedInSplit ? RCColor.bgWindow : .clear, in: Circle())
                .overlay {
                    if embeddedInSplit {
                        Circle().strokeBorder(RCColor.popoverStroke, lineWidth: 1)
                    }
                }
        }
        .accessibilityLabel("管理设备")
        .accessibilityIdentifier("device.menu")
    }

    // MARK: - iPhone 单栏详情视图

    private var phoneDetailContent: some View {
        VStack(spacing: 20) {
            if isSelfDevice {
                selfInfoCard
            } else {
                if isActiveSessionTarget {
                    activeSessionBanner
                        .padding(.horizontal, 16)
                }

                // 预览卡:点击进入桌面（若存在纯工具在途会话则原地热升级）
                Button {
                    if canConnect {
                        AssistFlow.shared.sessionActive = true
                        adoptExistingOnOpen = isActiveSessionTarget
                        sessionMode = .control
                    }
                } label: {
                    DevicePreview(device: device, showsCaption: online, fitsFullDesktop: true)
                        .frame(maxWidth: .infinity)
                        .aspectRatio(16.0 / 10.0, contentMode: .fit)
                        .overlay {
                            if isActiveSessionTarget && !SessionService.shared.mediaPaused {
                                VStack(spacing: 6) {
                                    Text("本机正在控制此设备")
                                        .font(.headline)
                                    Text("点击返回远控画面")
                                        .font(.caption)
                                        .opacity(0.85)
                                }
                                .foregroundStyle(.white)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                            } else if online {
                                HStack(spacing: 4) {
                                    Text(isActiveSessionTarget ? "进入桌面（热升级）" : "进入桌面").font(.headline)
                                    RabbitIcon(.chevronRight, size: 16)
                                }.foregroundStyle(.white).shadow(radius: 4)
                            } else {
                                Text("设备离线")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(.white)
                            }
                        }
                        .background(.black.opacity(online ? 0 : 0.45))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .disabled(!canConnect)
                .accessibilityIdentifier("detail.enterDesktop")
                .padding(.horizontal, 16)

                if canWakeOnLAN {
                    wakeOnLanButton
                        .padding(.horizontal, 16)
                }

                // 快捷入口行
                HStack(spacing: 0) {
                    quickAction("文件传输", icon: .fileTransfer, id: "detail.files") { standaloneTool = .files }
                    Divider().frame(height: 34)
                    quickAction("观看模式", icon: .watchScreen, id: "detail.watchMode") {
                        adoptExistingOnOpen = false
                        sessionMode = .watch
                    }
                    Divider().frame(height: 34)
                    quickAction("终端", icon: .terminal, id: "detail.terminal") { standaloneTool = .terminal }
                    Divider().frame(height: 34)
                    quickAction("更多", icon: .ellipsis, id: "detail.more") { showMoreTools = true }
                }
                .padding(.vertical, 8)
                .background(RCColor.bgWindow, in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 16)
                .opacity(canConnect ? 1 : 0.45)
                .disabled(!canConnect)

                // 状态行
                HStack(spacing: 8) {
                    Circle()
                        .fill(online ? RCColor.online : RCColor.textDisabled)
                        .frame(width: 8, height: 8)
                    Text(online ? "在线" : "离线")
                        .font(.system(size: 14))
                        .foregroundStyle(RCColor.textSecondary)
                    Spacer()
                    copyDeviceIDButton
                }
                .padding(.horizontal, 20)

                Text(connectionHint)
                    .font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 16)
            }
        }
        .padding(.top, 8)
    }

    // MARK: - iPad 右侧常驻详情工作台

    private var splitWorkspaceContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .center, spacing: 10) {
                RabbitIcon(device.kind.icon, size: 22)
                    .foregroundStyle(RCColor.accent)
                    .frame(width: 40, height: 40)
                    .background(RCColor.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(account?.displayName ?? device.name)
                            .font(.title2.bold())
                            .foregroundStyle(RCColor.textPrimary)
                            .lineLimit(1)

                        HStack(spacing: 5) {
                            Circle()
                                .fill(online ? RCColor.online : RCColor.textDisabled)
                                .frame(width: 7, height: 7)
                            Text(online ? "在线" : "离线")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(online ? RCColor.online : RCColor.textSecondary)
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3.5)
                        .background(
                            (online ? RCColor.online : RCColor.textDisabled).opacity(0.14),
                            in: Capsule()
                        )

                        if device.isLocal {
                            Text("LAN 直连")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(RCColor.online)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3.5)
                                .background(RCColor.online.opacity(0.14), in: Capsule())
                        }
                    }

                    HStack(spacing: 8) {
                        if let hostname = account?.hostname, !hostname.isEmpty {
                            Text(hostname)
                                .font(.caption)
                                .foregroundStyle(RCColor.textSecondary)
                                .lineLimit(1)
                            Text("·")
                                .foregroundStyle(RCColor.textDisabled)
                        }
                        copyDeviceIDButton
                    }
                }

                Spacer(minLength: 8)
                deviceManageMenu
            }

            if isSelfDevice {
                selfInfoCard
                    .padding(.horizontal, -16)
            } else {
                if isActiveSessionTarget {
                    activeSessionBanner
                }

                Button {
                    if canConnect {
                        AssistFlow.shared.sessionActive = true
                        adoptExistingOnOpen = isActiveSessionTarget
                        sessionMode = .control
                    }
                } label: {
                    DevicePreview(device: device, showsCaption: online, fitsFullDesktop: true)
                        .frame(maxWidth: .infinity)
                        .aspectRatio(16.0 / 10.0, contentMode: .fit)
                        .overlay(alignment: online ? .bottomTrailing : .center) {
                            if online {
                                HStack(spacing: 6) {
                                    RabbitIcon(.cursor, size: 15)
                                    Text(isActiveSessionTarget ? "进入桌面（热升级）" : "进入远程桌面")
                                        .font(.subheadline.weight(.semibold))
                                    RabbitIcon(.chevronRight, size: 13)
                                }
                                .foregroundStyle(.white)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(.black.opacity(0.62), in: Capsule())
                                .overlay {
                                    Capsule().strokeBorder(.white.opacity(0.22), lineWidth: 1)
                                }
                                .padding(14)
                            } else {
                                VStack(spacing: 6) {
                                    RabbitIcon(.disconnected, size: 24)
                                    Text("设备当前离线")
                                        .font(.subheadline.weight(.semibold))
                                }
                                .foregroundStyle(.white)
                            }
                        }
                        .background(.black.opacity(online ? 0 : 0.45))
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(RCColor.popoverStroke, lineWidth: 1)
                        }
                        .shadow(color: .black.opacity(0.06), radius: 12, y: 4)
                }
                .buttonStyle(.plain)
                .disabled(!canConnect)
                .accessibilityIdentifier("detail.enterDesktop")

                if canWakeOnLAN {
                    wakeOnLanButton
                } else {
                    HStack(spacing: 12) {
                        Button {
                            AssistFlow.shared.sessionActive = true
                            adoptExistingOnOpen = isActiveSessionTarget
                            sessionMode = .control
                        } label: {
                            HStack(spacing: 8) {
                                RabbitIcon(.cursor, size: 18)
                                Text(isActiveSessionTarget ? "进入远程桌面（热升级）" : "进入远程桌面")
                                    .font(.headline)
                            }
                            .foregroundStyle(canConnect ? .white : RCColor.textSecondary)
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .background(
                                canConnect ? RCColor.accent : RCColor.bgWindow,
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                            )
                            .overlay {
                                if !canConnect {
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .strokeBorder(RCColor.popoverStroke, lineWidth: 1)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(!canConnect)

                        Button {
                            AssistFlow.shared.sessionActive = true
                            adoptExistingOnOpen = false
                            sessionMode = .watch
                        } label: {
                            HStack(spacing: 8) {
                                RabbitIcon(.watchScreen, size: 18)
                                Text("观看模式")
                                    .font(.subheadline.weight(.semibold))
                            }
                            .foregroundStyle(canConnect ? RCColor.textPrimary : RCColor.textDisabled)
                            .padding(.horizontal, 22)
                            .frame(minHeight: 48)
                            .background(RCColor.bgWindow, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(RCColor.popoverStroke, lineWidth: 1)
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(!canConnect)
                        .accessibilityIdentifier("detail.watchMode")
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("远程工具与电源")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(RCColor.textSecondary)

                    LazyVGrid(
                        columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                        spacing: 12
                    ) {
                        workspaceToolTile(
                            title: "文件传输",
                            subtitle: "浏览远端目录与上传下载",
                            icon: .fileTransfer,
                            id: "detail.files"
                        ) { standaloneTool = .files }

                        workspaceToolTile(
                            title: "远程终端",
                            subtitle: "多标签命令行交互会话",
                            icon: .terminal,
                            id: "detail.terminal"
                        ) { standaloneTool = .terminal }

                        workspaceToolTile(
                            title: "端口映射",
                            subtitle: "转发远端服务端口至本机",
                            icon: .portMap,
                            id: "detail.portMapping"
                        ) { standaloneTool = .portMapping }

                        workspacePowerCard
                    }
                    .opacity(canConnect ? 1 : 0.45)
                    .disabled(!canConnect)
                }

                HStack(spacing: 8) {
                    RabbitIcon(online ? .security : .warning, size: 15)
                        .foregroundStyle(RCColor.textSecondary)
                    Text(connectionHint)
                        .font(.footnote)
                        .foregroundStyle(RCColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(RCColor.bgWindow, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(RCColor.popoverStroke, lineWidth: 0.5)
                }
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 24)
        .frame(maxWidth: 736)
        .frame(maxWidth: .infinity)
    }

    private var wakeOnLanButton: some View {
        Button(action: triggerWakeOnLAN) {
            HStack(spacing: 10) {
                if wakingUp {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                } else {
                    RabbitIcon(.power, size: 18)
                }
                Text(wakingUp ? "正在发送唤醒指令…" : "远程开机")
                    .font(.headline)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(
                wakingUp ? RCColor.accent.opacity(0.65) : RCColor.accent,
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .disabled(wakingUp)
        .accessibilityIdentifier("detail.wakeOnLan")
    }

    private var copyDeviceIDButton: some View {
        Button {
            UIPasteboard.general.string = device.id.filter { !$0.isWhitespace }
            ToastCenter.shared.show("已复制设备 ID")
        } label: {
            HStack(spacing: 5) {
                Text("ID \(device.displayID)")
                    .font((embeddedInSplit ? Font.caption : Font.subheadline).monospacedDigit())
                RabbitIcon(.clipboard, size: embeddedInSplit ? 13 : 15)
            }
            .foregroundStyle(.secondary)
            .frame(minHeight: embeddedInSplit ? 28 : 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("复制设备 ID \(device.displayID)")
        .accessibilityIdentifier("detail.copyID")
    }

    private func workspaceToolTile(
        title: String,
        subtitle: String,
        icon: RabbitIcon.Name,
        id: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                RabbitIcon(icon, size: 20)
                    .foregroundStyle(RCColor.accent)
                    .frame(width: 38, height: 38)
                    .background(RCColor.bgToolTile, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(RCColor.toolTileStroke, lineWidth: 1)
                    }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(RCColor.textPrimary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(RCColor.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                RabbitIcon(.chevronRight, size: 14)
                    .foregroundStyle(RCColor.textDisabled)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 64)
            .background(RCColor.bgWindow, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(RCColor.popoverStroke, lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    private var workspacePowerCard: some View {
        HStack(spacing: 8) {
            Button {
                powerConfirmKind = .reboot
            } label: {
                HStack(spacing: 6) {
                    RabbitIcon(.restart, size: 16)
                        .foregroundStyle(RCColor.textSecondary)
                    Text("重启")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(RCColor.textPrimary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RCColor.bgWindow, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(RCColor.popoverStroke, lineWidth: 1)
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("moreTools.reboot")

            Button {
                powerConfirmKind = .shutdown
            } label: {
                HStack(spacing: 6) {
                    RabbitIcon(.power, size: 16)
                        .foregroundStyle(RCColor.danger)
                    Text("关机")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(RCColor.danger)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RCColor.bgWindow, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(RCColor.popoverStroke, lineWidth: 1)
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("moreTools.shutdown")
        }
        .frame(minHeight: 64)
    }

    private var activeSessionBanner: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(RCColor.accent)
                .frame(width: 8, height: 8)
            Text(SessionService.shared.mediaPaused ? "纯工具通道连接中（未占视频带宽）" : "远控桌面会话进行中")
                .font(.footnote.weight(.medium))
                .foregroundStyle(RCColor.textPrimary)
            Spacer()
            Button("进入桌面") {
                adoptExistingOnOpen = true
                sessionMode = .control
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(RCColor.accent)

            Button("断开") {
                SessionService.shared.endUserSession()
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(RCColor.danger)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(RCColor.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(RCColor.accent.opacity(0.28), lineWidth: 1)
        }
    }
}

/// 独立文件传输 / 终端 / 端口映射无头会话页（对齐基线 §7.0 `tools_only`）：
/// - 建立连接后立即发 `SetMediaPaused(true)` 停视频采集与解码，秒开工具；
/// - 支持右上角「进入桌面」原地热升级为完整视频远控，在途传输/终端/端口映射不断链。
struct StandaloneToolSessionView: View {
    var device: Device
    var tool: DeviceDetailView.QuickTool
    var directAddr: String? = nil
    var initialPassword: String = ""
    var prefilledTerminalCommand: String? = nil
    var onUpgradeToDesktop: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var session = SessionService.shared
    @State private var attempt = 0
    @State private var openedAttempt: Int?
    @State private var connectionError: String?
    @State private var connectionUiError: RCUiError?
    @State private var retryPassword = ""
    @State private var isUpgrading = false
    @State private var showEmbeddedDesktop = false

    private var failureUiError: RCUiError? {
        if case .ended(let reason) = session.state {
            return session.endedUiError
                ?? CoreClient.resolveUiError(code: RCErrorCodes.sessionDisconnected, detail: reason)
        }
        return connectionUiError
    }

    private var failure: String? {
        if case .ended(let reason) = session.state { return reason }
        return connectionError
    }

    private var titleText: String {
        switch tool {
        case .files: return "文件传输"
        case .terminal: return "远程终端"
        case .portMapping: return "端口映射"
        case .hub: return "会话工具"
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if session.isConnected || AuthService.uiTestingMock {
                    switch tool {
                    case .files:
                        FileTransferView(device: device)
                            .modifier(ConnectedTool(session: session))
                    case .terminal:
                        TerminalView(initialDraftCommand: prefilledTerminalCommand)
                            .modifier(ConnectedTool(session: session))
                    case .portMapping:
                        PortMappingView(device: device)
                            .modifier(ConnectedTool(session: session))
                    case .hub:
                        EmptyView()
                    }
                } else if let failure {
                    ScrollView {
                        VStack(spacing: 16) {
                            RabbitIcon(.sessionEnded, size: 40)
                                .foregroundStyle(.secondary)
                            Text("连接已结束").font(.headline)
                            if let uiErr = failureUiError {
                                RCInlineErrorView(error: uiErr)
                                    .frame(maxWidth: 380)
                            } else {
                                Text(failure)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: 360)
                            }
                            SecureField("远端连接密码（如需）", text: $retryPassword)
                                .textContentType(.password)
                                .textFieldStyle(.roundedBorder)
                                .submitLabel(.go)
                                .onSubmit { attempt += 1 }
                                .frame(maxWidth: 300)
                            HStack(spacing: 12) {
                                Button("重新连接") { attempt += 1 }
                                    .buttonStyle(.borderedProminent)
                                Button("关闭") { dismiss() }
                                    .buttonStyle(.bordered)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(24)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .scrollDismissesKeyboard(.interactively)
                    .background(RCColor.bgPage)
                } else {
                    VStack(spacing: 14) {
                        ProgressView()
                        Text(tool == .files ? "正在建立无头传输通道…" : tool == .terminal ? "正在连接远程终端…" : "正在建立端口映射连接…")
                            .font(.headline)
                        Text("\(device.name) · 纯工具低开销模式")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(RCColor.bgPage)
                }
            }
            .navigationTitle(titleText)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                        .accessibilityIdentifier("standaloneTool.close")
                }
                if session.isConnected || AuthService.uiTestingMock {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            triggerHotUpgradeToDesktop()
                        } label: {
                            HStack(spacing: 3) {
                                RabbitIcon(.computer, size: 15)
                                Text("进入桌面")
                                    .font(.subheadline.weight(.medium))
                            }
                        }
                        .accessibilityIdentifier("standaloneTool.upgradeDesktop")
                    }
                }
            }
        }
        .fullScreenCover(isPresented: $showEmbeddedDesktop, onDismiss: {
            // 从内嵌桌面退回工具视图时，自动发 SetMediaPaused(true) 停视频保工具存活（§7.0）
            if session.isConnected {
                session.setMediaPaused(true)
            }
        }) {
            SessionView(
                device: device,
                mode: .control,
                directAddr: directAddr,
                connectionPassword: retryPassword.isEmpty ? initialPassword : retryPassword,
                adoptExistingSession: true
            )
        }
        .task(id: attempt) {
            guard openedAttempt != attempt else { return }
            openedAttempt = attempt
            await openConnection()
        }
        .onDisappear {
            if !isUpgrading && !showEmbeddedDesktop {
                SessionService.shared.close()
            }
        }
    }

    private func triggerHotUpgradeToDesktop() {
        session.upgradeToDesktop()
        if let onUpgradeToDesktop {
            isUpgrading = true
            onUpgradeToDesktop()
        } else {
            showEmbeddedDesktop = true
        }
    }

    private func openConnection() async {
        guard !AuthService.uiTestingMock else { return }
        // 若当前已有同一设备的活跃连接，直接复用并置为纯工具暂停视频态
        let compactTarget = device.id.replacingOccurrences(of: " ", with: "")
        if session.isConnected,
           let currentTarget = session.targetDeviceID?.replacingOccurrences(of: " ", with: ""),
           currentTarget == compactTarget {
            session.setMediaPaused(true)
            return
        }

        session.close()
        connectionError = nil
        connectionUiError = nil
        let password = retryPassword.isEmpty ? initialPassword : retryPassword
        if let directAddr {
            session.open(
                connectAddr: directAddr,
                password: password,
                watchOnly: false,
                deviceID: device.id,
                toolsOnly: true
            )
            return
        }
        if compactTarget.count == 9, RuntimeService.shared.signalRunning {
            do {
                let result = try await RuntimeService.connect(
                    targetID: compactTarget,
                    password: password,
                    watchOnly: false,
                    lanDirectAddr: LANDiscoveryService.shared.directAddr(forDeviceID: compactTarget),
                    toolsOnly: true
                )
                guard !Task.isCancelled else {
                    SessionService.releaseSession(result.sessionID)
                    return
                }
                session.adopt(sessionID: result.sessionID, watchOnly: false, deviceID: device.id, toolsOnly: true)
            } catch {
                if !Task.isCancelled {
                    let uiErr = (error as? AuthService.AuthError)?.uiError
                        ?? RCUiErrorCodec.fromError(error)
                    connectionUiError = uiErr
                    connectionError = uiErr.message
                }
            }
        } else {
            let uiErr = CoreClient.resolveUiError(code: RCErrorCodes.signalNotStarted)
            connectionUiError = uiErr
            connectionError = uiErr.message
        }
    }
}
