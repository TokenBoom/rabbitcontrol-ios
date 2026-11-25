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
    /// 本机(iOS 注册进账号的 controller 设备):只显示信息,不提供控制入口。
    private var isSelfDevice: Bool {
        guard let account else { return false }
        if account.os == "ios" { return true }
        if let own = RuntimeService.shared.deviceID {
            return account.deviceID.replacingOccurrences(of: " ", with: "") == own.replacingOccurrences(of: " ", with: "")
        }
        return false
    }
    /// 快捷入口要直达的工具;nil 表示只进会话。
    enum QuickTool: Int, Identifiable {
        var id: Int { rawValue }
        case files = 1, terminal = 2, hub = 3
    }
    @State private var quickTool: QuickTool?
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


    /// 快捷入口按钮(图标在上文字在下)。
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

    /// 本机信息卡:只展示设备信息,没有任何控制入口。
    private var selfInfoCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("本机设备", rabbitIcon: .phone)
                .font(.headline)
            LabeledContent("设备 ID", value: device.displayID)
            if let account {
                LabeledContent("主机名", value: account.hostname.isEmpty ? "—" : account.hostname)
                LabeledContent("系统", value: account.os.isEmpty ? "—" : account.os)
            }
            Text("这是当前 iPhone 注册到账号的设备。iOS 仅作为控制端,不能被远程控制。")
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
        if !account.online { return "设备离线。请在对方设备上打开 RabbitControl 并检查网络，下拉可刷新状态。" }
        if !account.allowRemoteAssist { return "请先在对方设备上允许远程协助。" }
        return "控制模式支持键鼠与远程工具；仅查看不会发送操作。"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if isSelfDevice {
                    selfInfoCard
                } else {
                // 预览卡:点击进入桌面
                Button { if canConnect { sessionMode = .control } } label: {
                    DevicePreview(device: device, showsCaption: online)
                        .frame(maxWidth: .infinity)
                        .aspectRatio(16.0 / 10.0, contentMode: .fit)
                        .overlay {
                            if online {
                                HStack(spacing: 4) {
                                    Text("进入桌面").font(.headline)
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

                // 快捷入口行
                HStack(spacing: 0) {
                    quickAction("文件传输", icon: .fileTransfer, id: "detail.files") { quickTool = .files; sessionMode = .control }
                    Divider().frame(height: 34)
                    quickAction("观看模式", icon: .watchScreen, id: "detail.watchMode") { sessionMode = .watch }
                    Divider().frame(height: 34)
                    quickAction("终端", icon: .terminal, id: "detail.terminal") { quickTool = .terminal; sessionMode = .control }
                    Divider().frame(height: 34)
                    quickAction("更多", icon: .ellipsis, id: "detail.more") { quickTool = .hub; sessionMode = .control }
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

                if !isSelfDevice {
                    Text(connectionHint)
                        .font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 16)
                }
                }

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
        .fullScreenCover(item: $sessionMode, onDismiss: { quickTool = nil; SessionService.shared.close() }) { mode in
            SessionView(device: device, mode: mode, initialTool: mode == .control ? quickTool : nil)
        }
    }
}
