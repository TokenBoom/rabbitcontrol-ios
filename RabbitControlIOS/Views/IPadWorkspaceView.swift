import SwiftUI
import UIKit

/// iPad 端顶层侧边栏工作台（`horizontalSizeClass == .regular` 时启用）。
///
/// 采用单层稳定的 `NavigationSplitView`：左侧常驻主导航与信令状态栏，右侧根据所选模块
/// 切换「我的设备（主从双栏）」、「远程协助（双栏连接工作台）」与「我的（主从设置中心）」。
struct IPadWorkspaceView: View {
    @Binding var selection: RootView.Tab
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var viewportSize = CGSize.zero
    @State private var assistFlow = AssistFlow.shared

    private var auth: AuthService { .shared }
    private var runtime: RuntimeService { .shared }
    private var lanService: LANDiscoveryService { .shared }

    private var onlineCount: Int {
        DeviceListView.controllableDevices(
            accountDevices: auth.devices,
            peers: lanService.peers,
            ownDeviceID: runtime.deviceID
        )
        .filter(\.online)
        .count
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebarContent
                .accessibilityHidden(assistFlow.sessionActive)
                .navigationSplitViewColumnWidth(min: 208, ideal: 226, max: 248)
        } detail: {
            Group {
                switch selection {
                case .devices:
                    IPadDevicesSplitPane(
                        columnVisibility: $columnVisibility,
                        prefersCollapsedSidebar: viewportSize.width > 0 && viewportSize.width < 940
                    )
                case .assist:
                    NavigationStack {
                        AssistView(embeddedInTab: true)
                            .toolbar {
                                if columnVisibility == .detailOnly {
                                    ToolbarItem(placement: .topBarLeading) {
                                        sidebarRevealButton
                                    }
                                }
                            }
                    }
                case .profile:
                    IPadProfileSplitPane(
                        columnVisibility: $columnVisibility,
                        prefersCollapsedSidebar: viewportSize.width > 0 && viewportSize.width < 940
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityHidden(assistFlow.sessionActive)
            .background(RCColor.bgPage.ignoresSafeArea())
        }
        .navigationSplitViewStyle(.balanced)
        .accessibilityHidden(assistFlow.sessionActive)
        .onGeometryChange(for: CGSize.self) { geo in
            geo.size
        } action: { newSize in
            let wasPortraitNarrow = viewportSize.width > 0 && viewportSize.width < 940
            let isPortraitNarrow = newSize.width > 0 && newSize.width < 940
            viewportSize = newSize
            if isPortraitNarrow && !wasPortraitNarrow && (selection == .devices || selection == .profile) {
                columnVisibility = .detailOnly
            } else if !isPortraitNarrow && wasPortraitNarrow {
                columnVisibility = .all
            }
        }
        .onAppear {
            auth.startAutoRefresh()
        }
    }

    private var sidebarRevealButton: some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) {
                columnVisibility = .all
            }
        } label: {
            Label("显示导航栏", systemImage: "sidebar.left")
        }
    }

    // MARK: - 左侧常驻工作台导航栏

    private var sidebarContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            sidebarHeader
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 18)

            if !assistFlow.sessionActive {
                VStack(spacing: 6) {
                    sidebarNavItem(
                        tab: .devices,
                        title: "我的设备",
                        icon: .devices,
                        badge: onlineCount > 0 ? "\(onlineCount)" : nil
                    )
                    sidebarNavItem(
                        tab: .assist,
                        title: "远程协助",
                        icon: .remoteAssist
                    )
                    sidebarNavItem(
                        tab: .profile,
                        title: "我的",
                        icon: .person
                    )
                }
                .padding(.horizontal, 12)
            }

            Spacer(minLength: 16)

            sidebarStatusFooter
                .padding(12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RCColor.bgSidebar.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
    }

    private var sidebarHeader: some View {
        HStack(spacing: 11) {
            ZStack {
                LinearGradient(
                    colors: [Color(hex: 0x3C8CE7), RCColor.accent],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                RabbitIcon(.devices, size: 19)
                    .foregroundStyle(.white)
            }
            .frame(width: 36, height: 36)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .shadow(color: RCColor.accent.opacity(0.22), radius: 6, y: 2)

            VStack(alignment: .leading, spacing: 2) {
                Text("RabbitControl")
                    .font(.headline)
                    .foregroundStyle(RCColor.textPrimary)
                    .lineLimit(1)
                Text(auth.session?.email ?? "已登录")
                    .font(.caption2)
                    .foregroundStyle(RCColor.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    private func sidebarNavItem(
        tab: RootView.Tab,
        title: String,
        icon: RabbitIcon.Name,
        badge: String? = nil
    ) -> some View {
        let selected = selection == tab
        return Button {
            guard selection != tab else { return }
            UISelectionFeedbackGenerator().selectionChanged()
            selection = tab
        } label: {
            HStack(spacing: 10) {
                RabbitIcon(icon, size: 19)
                    .foregroundStyle(selected ? RCColor.accent : RCColor.textSecondary)
                    .frame(width: 24)

                Text(title)
                    .font(.subheadline.weight(selected ? .semibold : .medium))
                    .foregroundStyle(selected ? RCColor.accent : RCColor.textPrimary)
                    .lineLimit(1)

                Spacer(minLength: 4)

                if let badge {
                    Text(badge)
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(selected ? RCColor.accent : RCColor.textSecondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(
                            selected ? RCColor.accent.opacity(0.16) : RCColor.bgHover,
                            in: Capsule()
                        )
                }
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .background(
                selected ? RCColor.accent.opacity(0.12) : Color.clear,
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("tab.\(title)")
    }

    private var sidebarStatusFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Circle()
                    .fill(runtime.signalRunning ? RCColor.online : RCColor.warning)
                    .frame(width: 7, height: 7)
                Text(runtime.signalRunning ? "信令在线" : "未连信令")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(RCColor.textPrimary)
                Spacer(minLength: 4)
                Text(auth.serverTarget.host)
                    .font(.caption2.monospaced())
                    .foregroundStyle(RCColor.textSecondary)
                    .lineLimit(1)
            }

            if let ownID = runtime.deviceID, !ownID.isEmpty {
                let formatted = AssistView.display(ownID.replacingOccurrences(of: " ", with: ""))
                Button {
                    UIPasteboard.general.string = ownID.replacingOccurrences(of: " ", with: "")
                    ToastCenter.shared.show("已复制本机码")
                } label: {
                    HStack(spacing: 5) {
                        Text("本机 \(formatted)")
                            .font(.caption2.monospacedDigit())
                        Spacer(minLength: 4)
                        RabbitIcon(.clipboard, size: 12)
                    }
                    .foregroundStyle(RCColor.textSecondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(11)
        .background(RCColor.bgWindow, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(RCColor.popoverStroke, lineWidth: 0.5)
        }
    }
}

// MARK: - iPad「我的设备」主从双栏视图

struct IPadDevicesSplitPane: View {
    enum Filter: String, CaseIterable {
        case all = "全部"
        case online = "在线"
        case lan = "LAN"
    }

    @Binding var columnVisibility: NavigationSplitViewVisibility
    var prefersCollapsedSidebar: Bool

    @State private var selectedDeviceID: String?
    @State private var searchText = ""
    @State private var filter: Filter = .all
    @State private var onlineExpanded = true
    @State private var offlineExpanded = true
    @State private var isRefreshing = false
    @State private var showAllAccountDevices = false

    private var auth: AuthService { .shared }
    private var lanService: LANDiscoveryService { .shared }

    private var allDevices: [Device] {
        DeviceListView.controllableDevices(
            accountDevices: auth.devices,
            peers: lanService.peers,
            ownDeviceID: RuntimeService.shared.deviceID
        )
    }

    private var allAccountDevices: [Device] {
        DeviceListView.allDevices(
            accountDevices: auth.devices,
            peers: lanService.peers,
            ownDeviceID: RuntimeService.shared.deviceID
        )
    }

    private var filteredDevices: [Device] {
        allDevices.filter { dev in
            guard dev.matches(search: searchText) else { return false }
            switch filter {
            case .all: return true
            case .online: return dev.online
            case .lan: return dev.isLocal
            }
        }
    }

    private var onlineDevices: [Device] { filteredDevices.filter(\.online) }
    private var offlineDevices: [Device] { filteredDevices.filter { !$0.online } }

    private var selectedDevice: Device? {
        if let selectedDeviceID, let found = allDevices.first(where: { $0.id == selectedDeviceID }) {
            return found
        }
        return allDevices.first(where: \.online) ?? allDevices.first
    }

    var body: some View {
        HStack(spacing: 0) {
            listColumn
                .frame(width: prefersCollapsedSidebar ? 312 : 334)

            RCColor.divider.frame(width: 0.5)

            detailColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(RCColor.bgPage)
        .sheet(isPresented: $showAllAccountDevices) {
            NavigationStack {
                AllDevicesView { allAccountDevices }
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("关闭") { showAllAccountDevices = false }
                        }
                    }
            }
        }
        .onAppear {
            ensureSelection()
        }
        .onChange(of: allDevices.map(\.id)) {
            ensureSelection()
        }
    }

    private func ensureSelection() {
        if let selectedDeviceID, allDevices.contains(where: { $0.id == selectedDeviceID }) {
            return
        }
        selectedDeviceID = allDevices.first(where: \.online)?.id ?? allDevices.first?.id
    }

    // MARK: - 中栏：搜索 + 筛选 + 设备分组列表

    private var listColumn: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    if columnVisibility == .detailOnly {
                        Button {
                            withAnimation(.snappy(duration: 0.2)) { columnVisibility = .all }
                        } label: {
                            Image(systemName: "sidebar.left")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(RCColor.textPrimary)
                                .frame(width: 34, height: 34)
                                .background(RCColor.bgWindow, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("展开导航侧边栏")
                    }

                    Text("我的设备")
                        .font(.title2.bold())
                        .foregroundStyle(RCColor.textPrimary)
                        .accessibilityIdentifier("root.title")
                        .accessibilityAddTraits(.isHeader)

                    Spacer()

                    Button {
                        showAllAccountDevices = true
                    } label: {
                        RabbitIcon(.allDevices, size: 16)
                            .foregroundStyle(RCColor.textSecondary)
                            .frame(width: 34, height: 34)
                            .background(RCColor.bgWindow, in: Circle())
                            .overlay {
                                Circle().strokeBorder(RCColor.popoverStroke, lineWidth: 0.5)
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("全部账号设备")
                    .accessibilityIdentifier("devices.allDevices")

                    Button {
                        guard !isRefreshing else { return }
                        isRefreshing = true
                        Task {
                            await auth.refreshDevices()
                            isRefreshing = false
                        }
                    } label: {
                        Group {
                            if isRefreshing || auth.loadingDevices {
                                ProgressView().controlSize(.small)
                            } else {
                                RabbitIcon(.restart, size: 16)
                                    .foregroundStyle(RCColor.textSecondary)
                            }
                        }
                        .frame(width: 34, height: 34)
                        .background(RCColor.bgWindow, in: Circle())
                        .overlay {
                            Circle().strokeBorder(RCColor.popoverStroke, lineWidth: 0.5)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("刷新设备列表")
                }

                // 内联搜索框
                HStack(spacing: 8) {
                    RabbitIcon(.search, size: 15)
                        .foregroundStyle(RCColor.textSecondary)
                    TextField("搜索设备名称或 ID", text: $searchText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.subheadline)
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            RabbitIcon(.close, size: 11)
                                .foregroundStyle(RCColor.textSecondary)
                                .frame(width: 22, height: 22)
                                .background(Color.secondary.opacity(0.14), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("清除搜索")
                    }
                }
                .padding(.horizontal, 10)
                .frame(minHeight: 38)
                .background(RCColor.bgWindow, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(RCColor.popoverStroke, lineWidth: 0.5)
                }

                // 快捷过滤胶囊
                HStack(spacing: 6) {
                    filterChip(.all, count: allDevices.count)
                    filterChip(.online, count: allDevices.filter(\.online).count)
                    let lanCount = allDevices.filter(\.isLocal).count
                    if lanCount > 0 || filter == .lan {
                        filterChip(.lan, count: lanCount)
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 10)

            RCColor.divider.frame(height: 0.5)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let uiErr = auth.devicesUiError {
                        RCInlineErrorView(
                            error: uiErr,
                            actionLabelOverride: auth.loadingDevices ? nil : (uiErr.action == .relogin ? "重新登录" : "重新加载"),
                            onAction: auth.loadingDevices ? nil : { action in
                                if action == .relogin {
                                    auth.logout()
                                } else {
                                    Task { await auth.refreshDevices() }
                                }
                            }
                        )
                    }

                    if allDevices.isEmpty && auth.devicesError == nil {
                        if auth.loadingDevices {
                            ProgressView("正在加载设备…")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 32)
                        } else {
                            emptyListHint(title: "暂无可控设备", subtitle: "在你的电脑上登录同一账号后会自动出现在这里")
                        }
                    } else if filteredDevices.isEmpty {
                        emptyListHint(title: "没有匹配的设备", subtitle: "试试更换关键词或切换筛选条件")
                    } else {
                        if !onlineDevices.isEmpty {
                            splitDeviceSection(
                                title: "在线设备",
                                count: onlineDevices.count,
                                expanded: $onlineExpanded,
                                items: onlineDevices
                            )
                        }
                        if !offlineDevices.isEmpty {
                            splitDeviceSection(
                                title: "离线设备",
                                count: offlineDevices.count,
                                expanded: $offlineExpanded,
                                items: offlineDevices
                            )
                        }
                    }
                }
                .padding(14)
            }
            .refreshable {
                await auth.refreshDevices()
            }
        }
        .background(RCColor.bgPage)
    }

    private func filterChip(_ item: Filter, count: Int) -> some View {
        let active = filter == item
        return Button {
            UISelectionFeedbackGenerator().selectionChanged()
            filter = item
        } label: {
            HStack(spacing: 4) {
                Text(item.rawValue)
                Text("\(count)")
                    .monospacedDigit()
                    .opacity(0.8)
            }
            .font(.caption.weight(active ? .semibold : .regular))
            .foregroundStyle(active ? RCColor.accent : RCColor.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                active ? RCColor.accent.opacity(0.12) : RCColor.bgWindow,
                in: Capsule()
            )
            .overlay {
                Capsule()
                    .strokeBorder(active ? RCColor.accent.opacity(0.38) : RCColor.popoverStroke, lineWidth: 0.8)
            }
        }
        .buttonStyle(.plain)
    }

    private func splitDeviceSection(
        title: String,
        count: Int,
        expanded: Binding<Bool>,
        items: [Device]
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    expanded.wrappedValue.toggle()
                }
            } label: {
                HStack(spacing: 4) {
                    Text("\(title) \(count)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(RCColor.textSecondary)
                    RabbitIcon(expanded.wrappedValue ? .chevronUp : .chevronDown, size: 13)
                        .foregroundStyle(RCColor.textSecondary)
                    Spacer()
                }
                .frame(minHeight: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("section.\(title)")

            if expanded.wrappedValue {
                VStack(spacing: 8) {
                    ForEach(items) { item in
                        Button {
                            selectedDeviceID = item.id
                        } label: {
                            DeviceCard(
                                device: item,
                                isSelected: selectedDevice?.id == item.id,
                                showsChevron: false
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("device.\(item.id)")
                    }
                }
            }
        }
    }

    private func emptyListHint(title: String, subtitle: String) -> some View {
        VStack(spacing: 8) {
            RabbitIcon(.devices, size: 36)
                .foregroundStyle(RCColor.textDisabled)
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(RCColor.textSecondary)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(RCColor.textDisabled)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    // MARK: - 右栏：选中设备常驻详情台

    @ViewBuilder
    private var detailColumn: some View {
        if let device = selectedDevice {
            DeviceDetailView(
                device: device,
                embeddedInSplit: true,
                onDeviceRemoved: {
                    selectedDeviceID = nil
                    ensureSelection()
                }
            )
            .id(device.id)
        } else {
            VStack(spacing: 12) {
                RabbitIcon(.computer, size: 48)
                    .foregroundStyle(RCColor.textDisabled)
                Text("选择一台设备开始远程控制")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(RCColor.textSecondary)
                Text("在左侧选择在线的 Mac 或 Windows 设备，即可查看桌面预览、启动远控或使用远程终端与文件传输。")
                    .font(.subheadline)
                    .foregroundStyle(RCColor.textDisabled)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RCColor.bgPage)
        }
    }
}

// MARK: - iPad「我的」主从分栏设置中心

struct IPadProfileSplitPane: View {
    enum Panel: Hashable {
        case remoteDefaults
        case servers
        case proxy
        case appLock
        case changePassword
        case aboutDiagnostics
    }

    @Binding var columnVisibility: NavigationSplitViewVisibility
    var prefersCollapsedSidebar: Bool

    @State private var selectedPanel: Panel = .remoteDefaults
    @State private var showLogoutConfirm = false
    @State private var input = InteractionPrefs.shared
    @State private var lockStore = AppLockStore.shared

    private var auth: AuthService { .shared }
    private var runtime: RuntimeService { .shared }

    private var serverSummary: String {
        let host = auth.serverTarget.host.isEmpty ? "未配置" : auth.serverTarget.host
        return auth.savedServers.count > 1 ? "\(host) (\(auth.savedServers.count))" : host
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    private var signalStatusText: String {
        if runtime.signalRunning { return "信令在线" }
        if let err = runtime.lastError, !err.isEmpty { return "信令异常：\(err)" }
        return "信令连接中…"
    }

    var body: some View {
        HStack(spacing: 0) {
            menuColumn
                .frame(width: prefersCollapsedSidebar ? 304 : 326)

            RCColor.divider.frame(width: 0.5)

            NavigationStack {
                Group {
                    switch selectedPanel {
                    case .remoteDefaults:
                        SettingsView()
                    case .servers:
                        ServerConfigSheet(embeddedInSplit: true)
                    case .proxy:
                        ProxySettingsView(embeddedInSplit: true)
                    case .appLock:
                        AppLockSettingsView()
                    case .changePassword:
                        ChangePasswordSheet(embeddedInSplit: true)
                    case .aboutDiagnostics:
                        AboutDiagnosticsSheet(appVersion: appVersion, embeddedInSplit: true)
                    }
                }
                .frame(maxWidth: 680)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RCColor.bgPage)
            }
            .id(selectedPanel)
        }
        .background(RCColor.bgPage)
    }

    private var menuColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    if columnVisibility == .detailOnly {
                        Button {
                            withAnimation(.snappy(duration: 0.2)) { columnVisibility = .all }
                        } label: {
                            Image(systemName: "sidebar.left")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(RCColor.textPrimary)
                                .frame(width: 34, height: 34)
                                .background(RCColor.bgWindow, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("展开导航侧边栏")
                    }

                    Text("我的")
                        .font(.title2.bold())
                        .foregroundStyle(RCColor.textPrimary)

                    Spacer()
                }
                .padding(.top, 2)

                splitAccountCard

                VStack(spacing: 4) {
                    splitNavRow(
                        panel: .remoteDefaults,
                        icon: .settings,
                        title: "远控默认设置",
                        trailing: input.touchMode.label,
                        id: "profile.设置"
                    )
                    splitNavRow(
                        panel: .servers,
                        icon: .server,
                        title: "服务器管理",
                        trailing: serverSummary,
                        id: "profile.服务器设置"
                    )
                    splitNavRow(
                        panel: .proxy,
                        icon: .portMap,
                        title: "网络代理",
                        trailing: ProxyConfigStore.shared.config.summaryText,
                        id: "profile.网络代理"
                    )
                    splitNavRow(
                        panel: .appLock,
                        icon: .lock,
                        title: "本地应用锁",
                        trailing: lockStore.isEnabled ? "已启用" : "未启用",
                        id: "profile.应用锁"
                    )

                    Menu {
                        ForEach(AppThemeMode.allCases, id: \.self) { mode in
                            Button {
                                input.themeMode = mode
                            } label: {
                                if input.themeMode == mode {
                                    Label(mode.label, rabbitIcon: .checkmark)
                                } else {
                                    Text(mode.label)
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 10) {
                            RabbitIcon(.display, size: 19)
                                .foregroundStyle(RCColor.accent)
                                .frame(width: 24)
                            Text("外观主题")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(RCColor.textPrimary)
                            Spacer()
                            Text(input.themeMode.label)
                                .font(.caption)
                                .foregroundStyle(RCColor.textSecondary)
                            RabbitIcon(.chevronDown, size: 13)
                                .foregroundStyle(RCColor.textSecondary.opacity(0.7))
                        }
                        .padding(.horizontal, 12)
                        .frame(minHeight: 46)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("profile.外观主题")
                }
                .padding(6)
                .background(RCColor.bgWindow, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(RCColor.popoverStroke, lineWidth: 0.5)
                }

                VStack(spacing: 4) {
                    if auth.isLoggedIn {
                        splitNavRow(
                            panel: .changePassword,
                            icon: .security,
                            title: "修改密码",
                            trailing: nil,
                            id: "profile.修改密码"
                        )
                    }
                    splitNavRow(
                        panel: .aboutDiagnostics,
                        icon: .devices,
                        title: "关于与版本诊断",
                        trailing: "v\(appVersion)",
                        id: "profile.关于"
                    )
                }
                .padding(6)
                .background(RCColor.bgWindow, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(RCColor.popoverStroke, lineWidth: 0.5)
                }

                if auth.isLoggedIn {
                    Button(role: .destructive) {
                        showLogoutConfirm = true
                    } label: {
                        Text("退出登录")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(RCColor.danger)
                            .frame(maxWidth: .infinity, minHeight: 46)
                            .background(RCColor.bgWindow, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(RCColor.popoverStroke, lineWidth: 0.5)
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("profile.退出登录")
                    .confirmationDialog("退出当前账号？", isPresented: $showLogoutConfirm, titleVisibility: .visible) {
                        Button("退出登录", role: .destructive) { auth.logout() }
                        Button("取消", role: .cancel) {}
                    } message: {
                        Text("将断开当前会话并清除本机账号信息，不会解绑设备。")
                    }
                }
            }
            .padding(14)
        }
        .background(RCColor.bgPage)
    }

    private var splitAccountCard: some View {
        let displayTitle: String = {
            if let name = auth.session?.displayName, !name.isEmpty { return name }
            return "RabbitControl 账户"
        }()
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                RabbitIcon(.person, size: 22)
                    .foregroundStyle(RCColor.accent)
                    .frame(width: 42, height: 42)
                    .background(RCColor.accent.opacity(0.12), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(RCColor.textPrimary)
                        .lineLimit(1)
                    Text(auth.session?.email ?? "未登录")
                        .font(.caption)
                        .foregroundStyle(RCColor.textSecondary)
                        .lineLimit(1)
                        .accessibilityIdentifier("profile.phone")
                }
                Spacer(minLength: 0)
            }

            if auth.isLoggedIn {
                RCColor.divider.frame(height: 0.5)
                HStack(spacing: 6) {
                    Circle()
                        .fill(runtime.signalRunning ? RCColor.online : RCColor.warning)
                        .frame(width: 7, height: 7)
                    Text(signalStatusText)
                        .font(.caption2)
                        .foregroundStyle(RCColor.textSecondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if let ownID = runtime.deviceID, !ownID.isEmpty {
                        Button {
                            UIPasteboard.general.string = ownID.replacingOccurrences(of: " ", with: "")
                            ToastCenter.shared.show("已复制本机码")
                        } label: {
                            HStack(spacing: 4) {
                                Text(AssistView.display(ownID.replacingOccurrences(of: " ", with: "")))
                                    .font(.caption2.monospacedDigit())
                                RabbitIcon(.clipboard, size: 12)
                            }
                            .foregroundStyle(RCColor.textSecondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(14)
        .background(RCColor.bgWindow, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(RCColor.popoverStroke, lineWidth: 0.5)
        }
    }

    private func splitNavRow(
        panel: Panel,
        icon: RabbitIcon.Name,
        title: String,
        trailing: String?,
        id: String
    ) -> some View {
        let active = selectedPanel == panel
        return Button {
            guard selectedPanel != panel else { return }
            UISelectionFeedbackGenerator().selectionChanged()
            selectedPanel = panel
        } label: {
            HStack(spacing: 10) {
                RabbitIcon(icon, size: 19)
                    .foregroundStyle(active ? RCColor.accent : RCColor.textSecondary)
                    .frame(width: 24)
                Text(title)
                    .font(.subheadline.weight(active ? .semibold : .medium))
                    .foregroundStyle(active ? RCColor.accent : RCColor.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let trailing, !trailing.isEmpty {
                    Text(trailing)
                        .font(.caption)
                        .foregroundStyle(active ? RCColor.accent.opacity(0.85) : RCColor.textSecondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 46)
            .background(
                active ? RCColor.accent.opacity(0.12) : Color.clear,
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active ? .isSelected : [])
        .accessibilityIdentifier(id)
    }
}
