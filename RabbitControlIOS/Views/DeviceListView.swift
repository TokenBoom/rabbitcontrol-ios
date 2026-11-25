import SwiftUI

/// 「我的设备」主页:可控设备列表,在线/离线分组折叠(移动端适配版 P1/P3)。
struct DeviceListView: View {
    @State private var devices = MockData.devices
    @State private var onlineExpanded = true
    @State private var offlineExpanded = true

    private var onlineDevices: [Device] { devices.filter(\.online) }
    private var offlineDevices: [Device] { devices.filter { !$0.online } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

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
        .background(RCColor.bgPage)
        .navigationBarHidden(true)
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
                Text(device.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(device.online ? RCColor.textPrimary : RCColor.textSecondary)
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
