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

    /// 局域网发现的设备 ID 集合(原始 + 去空格格式化两种形式)。
    private var lanDeviceIDs: Set<String> {
        Set(lanService.peers.compactMap(\.deviceID).flatMap { [$0, $0.replacingOccurrences(of: " ", with: "")] })
    }

    private var devices: [Device] {
        auth.devices.map { accountDevice in
            let compactID = accountDevice.deviceID.replacingOccurrences(of: " ", with: "")
            let formattedCompact = accountDevice.formattedID.replacingOccurrences(of: " ", with: "")
            return Device(
                id: accountDevice.deviceID,
                name: accountDevice.displayName,
                kind: Device.Kind(osString: accountDevice.os),
                online: accountDevice.online,
                isLocal: lanDeviceIDs.contains(compactID) || lanDeviceIDs.contains(formattedCompact),
                wallpaper: Device.Wallpaper(hashSeed: accountDevice.deviceID)
            )
        }
    }

    private var onlineDevices: [Device] { devices.filter(\.online) }
    private var offlineDevices: [Device] { devices.filter { !$0.online } }

    var body: some View {
        Group {
            if auth.isLoggedIn {
                deviceList
            } else {
                LoginView()
            }
        }
        .background(RCColor.bgPage)
        .navigationBarHidden(true)
        .task {
            await auth.refreshDevices()
            auth.startAutoRefresh()
        }
    }

    private var deviceList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                if let error = auth.devicesError {
                    Text("设备列表刷新失败:\(error)")
                        .font(.system(size: 12))
                        .foregroundStyle(RCColor.danger)
                }

                if devices.isEmpty && auth.devicesError == nil {
                    emptyState
                }

                DeviceSection(
                    title: "在线设备",
                    count: onlineDevices.count,
                    expanded: $onlineExpanded,
                    devices: onlineDevices
                )

                DeviceSection(
                    title: "离线设备",
                    count: offlineDevices.count,
                    expanded: $offlineExpanded,
                    devices: offlineDevices
                )
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            // 给悬浮 tab 条留出不遮挡列表的空间
            .padding(.bottom, 110)
        }
        .refreshable {
            await auth.refreshDevices()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "laptopcomputer.and.iphone")
                .font(.system(size: 36))
                .foregroundStyle(RCColor.textDisabled)
            Text("暂无设备")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(RCColor.textSecondary)
            Text("在你的其他设备上登录同一账号后,会显示在这里")
                .font(.system(size: 12))
                .foregroundStyle(RCColor.textDisabled)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }

    private var header: some View {
        HStack {
            Text("可控设备")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(RCColor.textPrimary)
                .accessibilityIdentifier("root.title")
                .accessibilityAddTraits(.isHeader)
            Spacer()
            NavigationLink {
                AllDevicesView()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "rectangle.on.rectangle")
                        .font(.system(size: 13))
                    Text("全部设备")
                        .font(.system(size: 13))
                }
                .foregroundStyle(RCColor.textPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color.white.opacity(0.85), in: Capsule())
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
                        .font(.system(size: 14))
                        .foregroundStyle(RCColor.textSecondary)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12))
                        .foregroundStyle(RCColor.textSecondary)
                    Spacer()
                }
            }
            .buttonStyle(.plain)
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
/// 离线卡片整体降透明度。
struct DeviceCard: View {
    var device: Device

    private var platformIcon: String {
        switch device.kind {
        case .mac: "laptopcomputer"
        case .windows: "pc"
        case .phone: "iphone"
        case .tablet: "ipad"
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .topLeading) {
                WallpaperView(wallpaper: device.wallpaper)
                    .frame(width: 96, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .saturation(device.online ? 1 : 0.4)

                if device.online {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(RCColor.online)
                            .frame(width: 6, height: 6)
                        Text("在线")
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
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(device.online ? RCColor.textPrimary : RCColor.textSecondary)
                    if device.isLocal {
                        Text("LAN")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(RCColor.online, in: Capsule())
                    }
                }
                Image(systemName: platformIcon)
                    .font(.system(size: 14))
                    .foregroundStyle(device.online ? RCColor.accent : RCColor.textDisabled)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 13))
                .foregroundStyle(RCColor.textDisabled)
        }
        .padding(8)
        .background(.white, in: RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.04), radius: 3, y: 1)
    }
}
