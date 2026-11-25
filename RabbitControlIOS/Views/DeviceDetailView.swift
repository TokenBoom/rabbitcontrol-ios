import SwiftUI

/// 设备详情页(P1 移动端适配):预览卡 + 「进入桌面」/「观看模式」+ 工具入口。
struct DeviceDetailView: View {
    var device: Device

    @State private var sessionMode: SessionMode?
    @State private var actionError: String?
    @State private var saving = false
    private var account: AccountDevice? { AuthService.shared.devices.first { $0.deviceID == device.id } }
    private var online: Bool { account?.online ?? false }
    private var canConnect: Bool { account.map { $0.online && !$0.disabled && $0.allowRemoteAssist } ?? false }
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

    private var connectionHint: String {
        guard let account else { return "设备已不在当前账号中，请返回设备列表。" }
        if account.disabled { return "设备已被停用，暂时无法连接。" }
        if !account.online { return "设备离线。请在对方设备上打开 RabbitControl 并检查网络，下拉可刷新状态。" }
        if !account.allowRemoteAssist { return "请先在对方设备上允许远程协助。" }
        return "控制模式支持键鼠与远程工具；仅查看不会发送操作。"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // 预览卡
                DevicePreview(device: device, showsCaption: online)
                    .frame(maxWidth: .infinity)
                    .aspectRatio(16.0 / 10.0, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay {
                        if !online {
                            RoundedRectangle(cornerRadius: 12)
                                .fill(.black.opacity(0.45))
                            Text("设备离线")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(.white)
                        }
                    }
                    .padding(.horizontal, 16)

                // 状态行
                HStack(spacing: 8) {
                    Circle()
                        .fill(online ? RCColor.online : RCColor.textDisabled)
                        .frame(width: 8, height: 8)
                    Text(online ? "在线" : "离线")
                        .font(.system(size: 14))
                        .foregroundStyle(RCColor.textSecondary)
                    Spacer()
                    Button {
                        UIPasteboard.general.string = device.id.filter { !$0.isWhitespace }
                        ToastCenter.shared.show("已复制设备 ID")
                    } label: {
                        HStack(spacing: 6) {
                            Text("ID  \(device.displayID)").font(.subheadline.monospacedDigit())
                            RabbitIcon(.clipboard, size: 15)
                        }
                        .foregroundStyle(.secondary).frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("复制设备 ID \(device.displayID)")
                    .accessibilityIdentifier("detail.copyID")
                }
                .padding(.horizontal, 20)

                // 主操作
                VStack(spacing: 12) {
                    Button {
                        sessionMode = .control
                    } label: {
                        HStack(spacing: 8) {
                            Text("进入桌面")
                                .font(.headline)
                            RabbitIcon(.arrowRight, size: 16)
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 48)
                        .background(
                            canConnect ? RCColor.accent : RCColor.stroke,
                            in: RoundedRectangle(cornerRadius: 10)
                        )
                    }
                    .disabled(!canConnect)
                    .accessibilityIdentifier("detail.enterDesktop")

                    Button {
                        sessionMode = .watch
                    } label: {
                        HStack(spacing: 6) {
                            RabbitIcon(.watchScreen, size: 20)
                            Text("查看设备屏幕（只读）")
                        }
                        .font(.body.weight(.medium))
                        .foregroundStyle(canConnect ? RCColor.textPrimary : RCColor.textDisabled)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 48)
                        .background(RCColor.bgWindow, in: RoundedRectangle(cornerRadius: 10))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(RCColor.stroke, lineWidth: 1)
                        }
                    }
                    .disabled(!canConnect)
                    .accessibilityIdentifier("detail.watchMode")
                }
                .padding(.horizontal, 16)

                Text(connectionHint)
                    .font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 16)

            }
            .padding(.top, 8)
        }
        .background(RCColor.bgPage)
        .refreshable { await AuthService.shared.refreshDevices() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
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
                    RabbitIcon(.ellipsis, size: 22)
                }
                .accessibilityLabel("管理设备").accessibilityIdentifier("device.menu")
            }
        }
        .alert("重命名设备", isPresented: $showRename) {
            TextField("设备别名", text: $renameText)
            Button("取消", role: .cancel) {}
            Button("确定") {
                Task {
                    saving = true
                    defer { saving = false }
                    do { try await AuthService.shared.renameDevice(deviceID: device.id, alias: renameText.trimmingCharacters(in: .whitespacesAndNewlines)) }
                    catch { actionError = error.localizedDescription }
                }
            }.disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .alert("解绑该设备?", isPresented: $showRemoveConfirm) {
            Button("取消", role: .cancel) {}
            Button("解绑", role: .destructive) {
                Task {
                    saving = true
                    defer { saving = false }
                    do { try await AuthService.shared.removeDevice(deviceID: device.id); dismiss() }
                    catch { actionError = error.localizedDescription }
                }
            }
        } message: {
            Text("“\(account?.displayName ?? device.name)”将从当前账号移除。")
        }
        .navigationTitle(account?.displayName ?? device.name)

        .disabled(saving)
        .overlay { if saving { ProgressView("正在保存…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
        .alert("操作未完成", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("好") { actionError = nil }
        } message: { Text(actionError ?? "") }
        .accessibilityHidden(sessionMode != nil)
        .fullScreenCover(item: $sessionMode, onDismiss: SessionService.shared.close) { mode in
            SessionView(device: device, mode: mode)
        }
    }
}
