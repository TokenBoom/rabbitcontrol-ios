import SwiftUI

/// 端口映射(W4 移动端适配):支持新建、编辑、热启停、删除与按设备本地持久化自动恢复（对齐基线 §7.3）。
struct PortMappingView: View {
    var device: Device

    @State private var showAdd = false
    @State private var editingRule: ToolService.PortmapRule?
    @State private var tools = ToolService.shared
    @State private var session = SessionService.shared
    @State private var store = PortMapStore.shared
    @State private var removing: ToolService.PortmapRule?
    @State private var actionError: String?

    private var portMapAllowed: Bool { session.toolPermissions.allowPortMap }

    var body: some View {
        List {
            Section {
                LabeledContent("已连接", value: device.name)
                if !store.rules(for: device.id).isEmpty {
                    LabeledContent("已保存自动恢复规则", value: "\(store.rules(for: device.id).count) 条")
                        .font(.footnote)
                }
            }
            if !portMapAllowed {
                Section {
                    RCInlineErrorView(error: CoreClient.resolveUiError(code: RCErrorCodes.toolForbidden))
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }
            Section {
                if tools.portmapRules.isEmpty {
                    ContentUnavailableView {
                        Label("暂无端口映射", rabbitIcon: .portMap)
                    } description: {
                        Text("点右上角的添加，设置本地端口与远端目标；保存后重连该设备将自动恢复生效。")
                    }
                }
                ForEach(tools.portmapRules) { rule in
                    realMappingRow(rule)
                        .swipeActions(allowsFullSwipe: false) {
                            Button("移除", role: .destructive) { removing = rule }
                            Button("编辑") { editingRule = rule }
                                .tint(RCColor.accent)
                        }
                        .accessibilityAction(named: "移除映射") { removing = rule }
                }
            } header: { Text("本次会话的映射") } footer: {
                if !tools.portmapRules.isEmpty {
                    Text("使用开关暂停或恢复映射；点击规则或向左滑动可编辑、移除。")
                }
            }
        }
        .navigationTitle("端口映射").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button { showAdd = true } label: { Label("添加", rabbitIcon: .plus) }
                .disabled(!session.isConnected || !portMapAllowed).accessibilityIdentifier("portmap.add")
        }
        .confirmationDialog(
            "移除这条映射？",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            presenting: removing
        ) { rule in
            Button("移除", role: .destructive) {
                if let sid = session.sessionID {
                    actionError = tools.portmapRemove(
                        sessionID: sid,
                        ruleID: rule.id,
                        localPort: rule.localPort,
                        persistDeviceID: device.id
                    )
                }
            }
        } message: { Text("移除“\($0.name)”后，本地端口将不再通过此规则转发。") }
        .alert("操作未完成", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("好", role: .cancel) {}
        } message: { Text(actionError ?? "") }
        .onAppear {
            if let sid = session.sessionID {
                tools.start(sessionID: sid)
                tools.portmapRefresh(sessionID: sid)
                store.restorePersistedRulesIfNeeded(sessionID: sid, deviceID: device.id)
            }
        }
        .sheet(isPresented: $showAdd) {
            AddMappingSheet { mapping in
                guard let sid = session.sessionID, session.isConnected else { return "会话已结束" }
                return tools.portmapAdd(
                    sessionID: sid,
                    name: mapping.name,
                    localPort: mapping.localPort,
                    remoteHost: mapping.targetAddress,
                    remotePort: mapping.targetPort,
                    enabled: true,
                    persistDeviceID: device.id
                )
            }
        }
        .sheet(item: $editingRule) { rule in
            AddMappingSheet(existing: rule) { mapping in
                guard let sid = session.sessionID, session.isConnected else { return "会话已结束" }
                return tools.portmapUpdate(
                    sessionID: sid,
                    existingRule: rule,
                    name: mapping.name,
                    localPort: mapping.localPort,
                    remoteHost: mapping.targetAddress,
                    remotePort: mapping.targetPort,
                    persistDeviceID: device.id
                )
            }
        }
    }

    private func realMappingRow(_ rule: ToolService.PortmapRule) -> some View {
        HStack(spacing: 10) {
            Button {
                editingRule = rule
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(rule.name)
                            .font(.headline)
                            .foregroundStyle(rule.enabled ? RCColor.textPrimary : RCColor.textDisabled)
                        Text(rule.statusLabel)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(statusColor(for: rule))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(statusColor(for: rule).opacity(0.12), in: Capsule())
                    }
                    Text(":\(rule.localPort) → \(rule.targetAddr):\(rule.targetPort)")
                        .font(.footnote.monospaced())
                        .foregroundStyle(rule.enabled ? RCColor.textSecondary : RCColor.textDisabled)
                    if rule.enabled || rule.bytesTx > 0 || rule.bytesRx > 0 {
                        Text("活跃连接 \(rule.activeConns) · ↑ \(formatBytes(rule.bytesTx)) · ↓ \(formatBytes(rule.bytesRx))")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    if let error = rule.error {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer()
            Toggle("", isOn: Binding(
                get: { rule.enabled },
                set: { on in
                    if let sid = session.sessionID {
                        actionError = tools.portmapToggle(
                            sessionID: sid,
                            ruleID: rule.id,
                            enabled: on,
                            localPort: rule.localPort,
                            persistDeviceID: device.id
                        )
                    }
                }
            ))
            .labelsHidden().accessibilityLabel("启用映射：\(rule.name)")
            .tint(RCColor.accent)
        }
        .padding(.vertical, 4)
    }

    private func statusColor(for rule: ToolService.PortmapRule) -> Color {
        if !rule.enabled { return .secondary }
        if rule.error != nil || rule.status == "error" || rule.status == "failed" { return RCColor.danger }
        if rule.status == "pending" || rule.status == "starting" { return RCColor.warning }
        return RCColor.online
    }

    private func formatBytes(_ count: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: count), countStyle: .file)
    }
}

struct PortMapping {
    let name: String
    let localPort: UInt16
    let targetAddress: String
    let targetPort: UInt16
}

struct AddMappingSheet: View {
    var existing: ToolService.PortmapRule? = nil
    var onSave: (PortMapping) -> String?

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var localPort: String
    @State private var targetAddress: String
    @State private var targetPort: String
    @State private var error: String?

    init(existing: ToolService.PortmapRule? = nil, onSave: @escaping (PortMapping) -> String?) {
        self.existing = existing
        self.onSave = onSave
        _name = State(initialValue: existing?.name ?? "")
        _localPort = State(initialValue: existing.map { String($0.localPort) } ?? "")
        _targetAddress = State(initialValue: existing?.targetAddr ?? "")
        _targetPort = State(initialValue: existing.map { String($0.targetPort) } ?? "")
    }

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
            .navigationTitle(existing == nil ? "添加映射" : "编辑映射")
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
