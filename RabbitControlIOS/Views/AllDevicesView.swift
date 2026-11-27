import SwiftUI

/// P3「全部设备」（对齐 macOS 基线 §3.3）：
/// - 展示同账号下全部设备（含 `allowRemoteControl == false` 的移动端及本机）；
/// - 对未开启远控的设备展示「未开启远控」徽标、隐藏进入详情箭头 `>`、禁用远控连接，但保留重命名与移除设备管理。
struct AllDevicesView: View {
    var devices: () -> [Device]
    @State private var search = ""
    @State private var renamingDevice: Device?
    @State private var renameText = ""
    @State private var removingDevice: Device?
    @State private var saving = false

    var body: some View {
        let devices = devices()
        let matches = devices.filter { $0.matches(search: search) }
        List {
            group("电脑", matches.filter { $0.kind == .mac || $0.kind == .windows })
            group("手机 / 平板", matches.filter { $0.kind == .phone || $0.kind == .tablet })
        }
        .disabled(saving)
        .overlay {
            if devices.isEmpty {
                if AuthService.shared.loadingDevices {
                    ProgressView("正在加载设备…")
                } else if let error = AuthService.shared.devicesError {
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
            } else if matches.isEmpty {
                ContentUnavailableView {
                    Label {
                        Text("没有匹配的设备")
                    } icon: {
                        RabbitIcon(.search, size: 42)
                    }
                } description: {
                    Text("可按设备名称或九位 ID 查找。")
                } actions: {
                    Button("清除搜索") { search = "" }
                }
            }
        }
        .refreshable { await AuthService.shared.refreshDevices() }
        .scrollDismissesKeyboard(.interactively)
        .searchable(text: $search, prompt: "设备名称或 ID")
        .navigationTitle("全部设备")
        .alert("重命名设备", isPresented: Binding(get: { renamingDevice != nil }, set: { if !$0 { renamingDevice = nil } })) {
            TextField("设备别名", text: $renameText)
            Button("取消", role: .cancel) { renamingDevice = nil }
            Button("确定") {
                guard let target = renamingDevice else { return }
                let alias = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                renamingDevice = nil
                Task {
                    saving = true
                    defer { saving = false }
                    do {
                        try await AuthService.shared.renameDevice(deviceID: target.id, alias: alias)
                        ToastCenter.shared.show("已更新设备备注名")
                    } catch {
                        let uiErr = (error as? AuthService.AuthError)?.uiError ?? RCUiErrorCodec.fromError(error)
                        RCErrorCenter.shared.present(uiErr)
                    }
                }
            }
            .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .alert("解绑该设备?", isPresented: Binding(get: { removingDevice != nil }, set: { if !$0 { removingDevice = nil } })) {
            Button("取消", role: .cancel) { removingDevice = nil }
            Button("解绑", role: .destructive) {
                guard let target = removingDevice else { return }
                removingDevice = nil
                Task {
                    saving = true
                    defer { saving = false }
                    do {
                        try await AuthService.shared.removeDevice(deviceID: target.id)
                        ToastCenter.shared.show("已移除设备")
                    } catch {
                        let uiErr = (error as? AuthService.AuthError)?.uiError ?? RCUiErrorCodec.fromError(error)
                        RCErrorCenter.shared.present(uiErr)
                    }
                }
            }
        } message: {
            Text("“\(removingDevice?.name ?? "")”将从当前账号移除。")
        }
    }

    @ViewBuilder
    private func group(_ title: String, _ items: [Device]) -> some View {
        if !items.isEmpty {
            Section(title) {
                ForEach(items) { device in
                    if device.allowRemoteControl && !device.isSelfDevice {
                        NavigationLink {
                            DeviceDetailView(device: device)
                        } label: {
                            controllableRow(device)
                        }
                        .accessibilityIdentifier("all.device.\(device.id)")
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            managementSwipeButtons(for: device)
                        }
                    } else {
                        readOnlyRow(device)
                            .accessibilityIdentifier("all.device.\(device.id)")
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                managementSwipeButtons(for: device)
                            }
                    }
                }
            }
        }
    }

    private func controllableRow(_ device: Device) -> some View {
        HStack(spacing: 12) {
            RabbitIcon(device.kind.icon, size: 24)
                .foregroundStyle(.tint)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(device.name).font(.headline)
                    if device.inSession {
                        Text("会话中")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(RCColor.accent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(RCColor.accent.opacity(0.12), in: Capsule())
                    }
                }
                Text("\(device.online ? "在线" : "离线") · \(device.displayID)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }

    private func readOnlyRow(_ device: Device) -> some View {
        HStack(spacing: 12) {
            RabbitIcon(device.kind.icon, size: 24)
                .foregroundStyle(RCColor.textSecondary)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(device.name)
                        .font(.headline)
                        .foregroundStyle(RCColor.textPrimary)
                    Text(device.isSelfDevice ? "本机 · 未开启远控" : "未开启远控")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(RCColor.textSecondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.14), in: Capsule())
                }
                Text("\(device.online ? "在线" : "离线") · \(device.displayID)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                Button {
                    renameText = device.name
                    renamingDevice = device
                } label: {
                    Label("修改备注名", rabbitIcon: .pencil)
                }
                if !device.isSelfDevice {
                    Button(role: .destructive) {
                        removingDevice = device
                    } label: {
                        Label("移除设备", rabbitIcon: .trash)
                    }
                }
            } label: {
                RabbitIcon(.ellipsis, size: 18)
                    .foregroundStyle(RCColor.textSecondary)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("管理 \(device.name)")
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private func managementSwipeButtons(for device: Device) -> some View {
        if !device.isSelfDevice {
            Button(role: .destructive) {
                removingDevice = device
            } label: {
                Label("移除", rabbitIcon: .trash)
            }
        }
        Button {
            renameText = device.name
            renamingDevice = device
        } label: {
            Label("重命名", rabbitIcon: .pencil)
        }
        .tint(RCColor.accent)
    }
}
