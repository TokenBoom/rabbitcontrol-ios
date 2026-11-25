import SwiftUI

struct AllDevicesView: View {
    var devices: () -> [Device]
    @State private var search = ""

    var body: some View {
        let devices = devices()
        let matches = devices.filter { $0.matches(search: search) }
        List {
            group("电脑", matches.filter { $0.kind == .mac || $0.kind == .windows })
            group("手机 / 平板", matches.filter { $0.kind == .phone || $0.kind == .tablet })
        }
        .overlay {
            if devices.isEmpty {
                if AuthService.shared.loadingDevices { ProgressView("正在加载设备…") }
                else if let error = AuthService.shared.devicesError {
                    ContentUnavailableView {
                        Label {
                            Text("未能加载设备")
                        } icon: {
                            RabbitIcon(.networkError, size: 42)
                        }
                    } description: { Text(error) } actions: {
                        Button("重试") { Task { await AuthService.shared.refreshDevices() } }
                    }
                } else {
                    ContentUnavailableView {
                        Label {
                            Text("暂无账号设备")
                        } icon: {
                            RabbitIcon(.devices, size: 44)
                        }
                    }
                }
            } else if matches.isEmpty { ContentUnavailableView {
                Label {
                    Text("没有匹配的设备")
                } icon: {
                    RabbitIcon(.search, size: 42)
                }
            } description: { Text("可按设备名称或九位 ID 查找。") } actions: {
                Button("清除搜索") { search = "" }
            } }
        }
        .refreshable { await AuthService.shared.refreshDevices() }
        .scrollDismissesKeyboard(.interactively)
        .searchable(text: $search, prompt: "设备名称或 ID")
        .navigationTitle("全部设备")
    }

    @ViewBuilder private func group(_ title: String, _ items: [Device]) -> some View {
        if !items.isEmpty {
            Section(title) {
                ForEach(items) { device in
                    NavigationLink { DeviceDetailView(device: device) } label: {
                        HStack(spacing: 12) {
                            RabbitIcon(device.kind.icon, size: 24).foregroundStyle(.tint).frame(width: 32)
                            VStack(alignment: .leading) {
                                Text(device.name).font(.headline)
                                Text("\(device.online ? "在线" : "离线") · \(device.displayID)")
                                    .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }.padding(.vertical, 3)
                    }.accessibilityIdentifier("all.device.\(device.id)")
                }
            }
        }
    }
}
