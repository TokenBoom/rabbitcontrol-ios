import SwiftUI

/// 「我的设备」主页:可控设备列表,在线/离线分组折叠(移动端适配版 P1/P3)。
///
/// 数据源为**登录账号的设备**;局域网发现不作为独立设备来源,
/// 仅在发现的节点与本账号设备匹配(device_id)时,标记 LAN 直连可用。
struct DeviceListView: View {
    @State private var onlineExpanded = true
    @State private var offlineExpanded = true

    private var auth: AuthService { .shared }
    private var lanService: LANDiscoveryService { .shared }

    static func controllableDevices(
        accountDevices: [AccountDevice],
        peers: [LANPeer],
        ownDeviceID: String?
    ) -> [Device] {
        let nearbyIDs = Set(
            peers.compactMap(\.deviceID).flatMap { [$0, $0.replacingOccurrences(of: " ", with: "")] }
        )
        return AccountDevice.sortForSidebar(accountDevices)
            .filter { $0.canShowInSidebar(ownDeviceID: ownDeviceID) }
            .map { $0.card(nearbyIDs: nearbyIDs, ownDeviceID: ownDeviceID) }
    }

    static func allDevices(
        accountDevices: [AccountDevice],
        peers: [LANPeer],
        ownDeviceID: String?
    ) -> [Device] {
        let nearbyIDs = Set(
            peers.compactMap(\.deviceID).flatMap { [$0, $0.replacingOccurrences(of: " ", with: "")] }
        )
        return AccountDevice.sortForSidebar(accountDevices)
            .map { $0.card(nearbyIDs: nearbyIDs, ownDeviceID: ownDeviceID) }
    }

    private var allAccountDevices: [Device] {
        Self.allDevices(
            accountDevices: auth.devices,
            peers: lanService.peers,
            ownDeviceID: RuntimeService.shared.deviceID
        )
    }

    private var devices: [Device] {
        Self.controllableDevices(
            accountDevices: auth.devices,
            peers: lanService.peers,
            ownDeviceID: RuntimeService.shared.deviceID
        )
    }

    private var onlineDevices: [Device] { devices.filter(\.online) }
    private var offlineDevices: [Device] { devices.filter { !$0.online } }

    var body: some View {
        deviceList
        .background(RCColor.bgPage)
        .navigationBarHidden(true)
        .task(id: auth.isLoggedIn) {
            auth.startAutoRefresh()
        }
    }

    private var deviceList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
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

                if devices.isEmpty && auth.devicesError == nil {
                    if auth.loadingDevices {
                        ProgressView("正在加载设备…").frame(maxWidth: .infinity)
                    } else { emptyState }
                }

                if !onlineDevices.isEmpty {
                    DeviceSection(
                        title: "在线设备",
                        count: onlineDevices.count,
                        expanded: $onlineExpanded,
                        devices: onlineDevices
                    )

                }
                if !offlineDevices.isEmpty {
                    DeviceSection(
                        title: "离线设备",
                        count: offlineDevices.count,
                        expanded: $offlineExpanded,
                        devices: offlineDevices
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .refreshable {
            await auth.refreshDevices()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            RabbitIcon(.devices, size: 46)
                .foregroundStyle(RCColor.textDisabled)
            Text("暂无设备")
                .font(.headline)
                .foregroundStyle(RCColor.textSecondary)
            Text("在你的其他设备上登录同一账号后,会显示在这里")
                .font(.caption)
                .foregroundStyle(RCColor.textDisabled)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }

    private var header: some View {
        HStack {
            Text("我的设备")
                .font(.largeTitle.bold())
                .foregroundStyle(RCColor.textPrimary)
                .accessibilityIdentifier("root.title")
                .accessibilityAddTraits(.isHeader)
            Spacer()
            NavigationLink {
                AllDevicesView { allAccountDevices }
            } label: {
                HStack(spacing: 4) {
                    RabbitIcon(.allDevices, size: 17)
                    Text("全部设备")
                        .font(.subheadline)
                }
                .foregroundStyle(RCColor.textPrimary)
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .background(RCColor.bgWindow, in: Capsule())
                .overlay {
                    Capsule().strokeBorder(RCColor.stroke, lineWidth: 0.5)
                }
            }
            .accessibilityIdentifier("devices.allDevices")
        }
    }
}

/// 在线/离线分组:组头可折叠,下挂设备卡片列表。
struct DeviceSection: View {
    var title: String
    var count: Int
    @Binding var expanded: Bool
    var devices: [Device]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    expanded.toggle()
                }
            } label: {
                HStack(spacing: 4) {
                    Text("\(title) \(count)")
                        .font(.subheadline)
                        .foregroundStyle(RCColor.textSecondary)
                    RabbitIcon(expanded ? .chevronUp : .chevronDown, size: 14)
                        .foregroundStyle(RCColor.textSecondary)
                    Spacer()
                }.frame(minHeight: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(expanded ? "已展开" : "已收起")
            .accessibilityIdentifier("section.\(title)")

            if expanded {
                VStack(spacing: 10) {
                    ForEach(devices) { device in
                        NavigationLink {
                            DeviceDetailView(device: device)
                        } label: {
                            DeviceCard(device: device)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("device.\(device.id)")
                    }
                }
            }
        }
    }
}

/// 设备卡片:左侧壁纸缩略图(在线设备左上角叠「在线」pill),右侧名称+平台图标+chevron;
/// 离线卡片整体降透明度。支持 iPad 分栏列表中的选中态高亮。
struct DeviceCard: View {
    var device: Device
    var isSelected = false
    var showsChevron = true

    private var activeLocalSession: Bool {
        let s = SessionService.shared
        guard s.isConnected, let target = s.targetDeviceID else { return false }
        return target.replacingOccurrences(of: " ", with: "") == device.id.replacingOccurrences(of: " ", with: "")
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .topLeading) {
                DevicePreview(device: device)
                    .frame(width: 96, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .saturation(device.online ? 1 : 0.4)

                if device.online {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(activeLocalSession ? RCColor.accent : RCColor.online)
                            .frame(width: 6, height: 6)
                        Text(activeLocalSession ? "在控" : "在线")
                            .font(.system(size: 10))
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.55), in: Capsule())
                    .padding(4)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(device.name)
                        .font(.headline)
                        .foregroundStyle(device.online ? RCColor.textPrimary : RCColor.textSecondary)
                        .lineLimit(1)
                    if device.isLocal {
                        Text("LAN")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(RCColor.online, in: Capsule())
                    }
                    if activeLocalSession || device.inSession {
                        Text(activeLocalSession ? "本机在控" : "会话中")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(RCColor.accent)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(RCColor.accent.opacity(0.14), in: Capsule())
                    }
                }
                Label(device.displayID, rabbitIcon: device.kind.icon)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if showsChevron {
                RabbitIcon(.chevronRight, size: 16)
                    .foregroundStyle(RCColor.textDisabled)
            }
        }
        .padding(8)
        .background(
            isSelected ? RCColor.bgToolTile : RCColor.bgWindow,
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(RCColor.accent.opacity(0.65), lineWidth: 1.5)
            } else {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(RCColor.popoverStroke, lineWidth: 0.5)
            }
        }
        .shadow(color: .black.opacity(isSelected ? 0.06 : 0.03), radius: isSelected ? 6 : 3, y: 1)
    }
}
