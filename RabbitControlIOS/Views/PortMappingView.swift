import SwiftUI

/// 端口映射(W4 移动端适配):映射列表 + 添加弹窗(含 §7.1 校验)。
struct PortMappingView: View {
    var device: Device

    @State private var showAdd = false
    @State private var tools = ToolService.shared
    @State private var session = SessionService.shared
    @State private var removing: ToolService.PortmapRule?
    @State private var actionError: String?

    var body: some View {
        List {
            Section {
                LabeledContent("已连接", value: device.name)
            }
            Section {
                if tools.portmapRules.isEmpty {
                    ContentUnavailableView {
                        Label("暂无端口映射", rabbitIcon: .portMap)
                    } description: {
                        Text("点右上角的添加，设置本地端口与远端目标。")
                    }
                }
                ForEach(tools.portmapRules) { rule in
                    realMappingRow(rule)
                        .swipeActions(allowsFullSwipe: false) {
                            Button("移除", role: .destructive) { removing = rule }
                        }
                        .accessibilityAction(named: "移除映射") { removing = rule }
                }
            } header: { Text("本次会话的映射") } footer: {
                if !tools.portmapRules.isEmpty { Text("使用开关暂停或恢复映射；向左滑动可移除。") }
            }
        }
        .navigationTitle("端口映射").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button { showAdd = true } label: { Label("添加", rabbitIcon: .plus) }
                .disabled(!session.isConnected).accessibilityIdentifier("portmap.add")
        }
        .confirmationDialog("移除这条映射？", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing) { rule in
            Button("移除", role: .destructive) {
                if let sid = session.sessionID { actionError = tools.portmapRemove(sessionID: sid, ruleID: rule.id) }
            }
        } message: { Text("移除“\($0.name)”后，本地端口将不再通过此规则转发。") }
        .alert("操作未完成", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("好", role: .cancel) {}
        } message: { Text(actionError ?? "") }
        .onAppear {
            if let sid = session.sessionID {
                tools.start(sessionID: sid)
            }
        }
        .onDisappear {
            tools.stop()
        }

        .sheet(isPresented: $showAdd) {
            AddMappingSheet { mapping in
                guard let sid = session.sessionID, session.isConnected else { return "会话已结束" }
                return tools.portmapAdd(
                        sessionID: sid,
                        name: mapping.name,
                        localPort: mapping.localPort,
                        remoteHost: mapping.targetAddress,
                        remotePort: mapping.targetPort
                )
            }
        }
    }

    private func realMappingRow(_ rule: ToolService.PortmapRule) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(rule.name)
                    .font(.headline)
                    .foregroundStyle(rule.enabled ? RCColor.textPrimary : RCColor.textDisabled)
                Text(":\(rule.localPort) → \(rule.targetAddr):\(rule.targetPort)")
                    .font(.footnote.monospaced())
                    .foregroundStyle(rule.enabled ? RCColor.textSecondary : RCColor.textDisabled)
                if let error = rule.error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { rule.enabled },
                set: { on in
                    if let sid = session.sessionID {
                        actionError = tools.portmapToggle(sessionID: sid, ruleID: rule.id, enabled: on)
                    }
                }
            ))
            .labelsHidden().accessibilityLabel("启用映射：\(rule.name)")
            .tint(RCColor.accent)
        }
        .padding(.vertical, 4)
    }

}

struct PortMapping {
    let name: String
    let localPort: UInt16
    let targetAddress: String
    let targetPort: UInt16
}

struct AddMappingSheet: View {
    var onSave: (PortMapping) -> String?

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var localPort = ""
    @State private var targetAddress = ""
    @State private var targetPort = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("规则") {
                    TextField("名称，例如开发服务器", text: $name)
                        .accessibilityIdentifier("portmap.field.name")
                }
                Section {
                    LabeledContent("本地端口") {
                        TextField("1–65535", text: $localPort).keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing).accessibilityIdentifier("portmap.field.localPort")
                    }
                } header: { Text("此 iPhone / iPad") }
                Section {
                    TextField("目标主机或 IP", text: $targetAddress).keyboardType(.URL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("portmap.field.targetAddress")
                    LabeledContent("目标端口") {
                        TextField("1–65535", text: $targetPort).keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing).accessibilityIdentifier("portmap.field.targetPort")
                    }
                } header: { Text("远端设备可访问的目标") } footer: {
                    if let validation { Text(validation) }
                }

                if let error {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundStyle(RCColor.danger)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("添加映射")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }.disabled(validation != nil)
                        .accessibilityIdentifier("portmap.save")
                }
            }
        }
        .presentationDetents([.large])
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var host: String { targetAddress.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var validation: String? {
        if !(1...64).contains(trimmedName.count) { return "请输入 1–64 个字符的规则名称。" }
        if (UInt16(localPort) ?? 0) == 0 { return "本地端口须为 1–65535。" }
        if host.isEmpty || host.contains(where: { $0.isWhitespace || "/?#@".contains($0) }) { return "请输入目标主机，不含协议或路径。" }
        if (UInt16(targetPort) ?? 0) == 0 { return "目标端口须为 1–65535。" }
        return nil
    }

    private func save() {
        guard validation == nil, let local = UInt16(localPort), let remote = UInt16(targetPort) else { return }
        error = onSave(PortMapping(name: trimmedName, localPort: local, targetAddress: host, targetPort: remote))
        if error == nil { dismiss() }
    }
}
