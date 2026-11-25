import SwiftUI

/// 全部设备页(P3 移动端适配):电脑与手机/平板两个分组。
struct AllDevicesView: View {
    // mock:与 §6.0 P3 对齐,电脑 4 台 + 手机/平板 4 台
    private let computers: [Device] = [
        Device(id: "y-local-mbp", name: "Y的 MacBook Pro", kind: .mac, online: true, isLocal: true, wallpaper: .coast),
        Device(id: "desktop-q5q8e8r", name: "DESKTOP-Q5Q8E8R", kind: .windows, online: true, isLocal: false, wallpaper: .lake),
        Device(id: "yii-mbp", name: "yii's MacBook Pro", kind: .mac, online: true, isLocal: false, wallpaper: .sunset),
        Device(id: "yii-mac-mini", name: "Y 的 Mac mini", kind: .mac, online: true, isLocal: false, wallpaper: .lake),
    ]
    private let mobiles: [Device] = [
        Device(id: "iphone-17-pro-max", name: "iPhone 17 Pro Max", kind: .phone, online: true, isLocal: false, wallpaper: .coast),
        Device(id: "iqoo-pad2-pro", name: "iQOO Pad2 Pro", kind: .tablet, online: true, isLocal: false, wallpaper: .sunset),
        Device(id: "oneplus-pgp110", name: "OnePlusPGP110", kind: .phone, online: true, isLocal: false, wallpaper: .lake),
        Device(id: "oneplus-ace-pro", name: "一加 Ace Pro 全网通版", kind: .phone, online: true, isLocal: false, wallpaper: .coast),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                group(title: "电脑", devices: computers)
                group(title: "手机 / 平板", devices: mobiles)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .background(RCColor.bgPage)
        .navigationTitle("全部设备")
        .onAppear { AppChrome.shared.tabBarHidden = true }
        .onDisappear { AppChrome.shared.tabBarHidden = false }

    }

    private func group(title: String, devices: [Device]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(RCColor.textPrimary)
            VStack(spacing: 10) {
                ForEach(devices) { device in
                    DeviceCard(device: device)
                }
            }
        }
    }
}
