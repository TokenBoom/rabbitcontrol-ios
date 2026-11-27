import SwiftUI

/// 修改密码弹层（`embeddedInSplit` 为 true 时作为 iPad 设置右栏内嵌表单渲染）。
struct ChangePasswordSheet: View {
    var embeddedInSplit = false
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focus: Field?
    private enum Field { case current, new, confirm }
    @State private var current = ""
    @State private var new = ""
    @State private var confirm = ""
    @State private var isWorking = false
    @State private var uiError: RCUiError?

    private var auth: AuthService { .shared }

    var body: some View {
        if embeddedInSplit {
            formBody
        } else {
            NavigationStack {
                formBody
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("取消") { dismiss() }.disabled(isWorking)
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button(isWorking ? "提交中…" : "确定") { submit() }
                                .disabled(!canSubmit)
                        }
                    }
            }
        }
    }

    private var formBody: some View {
        Form {
            Section("验证与设置新密码") {
                SecureField("当前密码", text: $current)
                    .textContentType(.password).focused($focus, equals: .current)
                    .submitLabel(.next).onSubmit { focus = .new }
                SecureField("新密码(至少 8 位)", text: $new)
                    .textContentType(.newPassword).focused($focus, equals: .new)
                    .submitLabel(.next).onSubmit { focus = .confirm }
                SecureField("确认新密码", text: $confirm)
                    .textContentType(.newPassword).focused($focus, equals: .confirm)
                    .submitLabel(.done).onSubmit(submit)
                if !confirm.isEmpty && new != confirm { Text("两次输入的新密码不一致").foregroundStyle(.red) }
            }
            if let uiError {
                Section {
                    RCInlineErrorView(error: uiError, onDismiss: {
                        self.uiError = nil
                    })
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
            }
            if embeddedInSplit {
                Section {
                    Button {
                        submit()
                    } label: {
                        HStack {
                            Spacer()
                            if isWorking { ProgressView().padding(.trailing, 6) }
                            Text(isWorking ? "提交中…" : "保存新密码")
                                .fontWeight(.semibold)
                            Spacer()
                        }
                    }
                    .disabled(!canSubmit)
                }
            }
        }
        .navigationTitle("修改密码")
        .disabled(isWorking).interactiveDismissDisabled(isWorking)
        .scrollDismissesKeyboard(.interactively)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var canSubmit: Bool {
        !isWorking && !current.isEmpty && new.count >= 8 && new == confirm
    }

    private func submit() {
        guard canSubmit else { return }
        focus = nil
        isWorking = true
        uiError = nil
        Task {
            do {
                try await auth.changePassword(current: current, new: new)
                if embeddedInSplit {
                    current = ""
                    new = ""
                    confirm = ""
                    ToastCenter.shared.show("密码已更新")
                } else {
                    dismiss()
                }
            } catch {
                uiError = (error as? AuthService.AuthError)?.uiError
                    ?? RCUiErrorCodec.fromError(error)
            }
            isWorking = false
        }
    }
}

/// 多服务器管理弹层:支持查看当前服务器、添加/编辑/删除多台服务器、连通性测试及一键切换。
struct ServerConfigSheet: View {
    var embeddedInSplit = false
    @Environment(\.dismiss) private var dismiss
    @State private var editingServer: EditingItem?
    @State private var pendingSwitch: AuthService.SavedServer?
    @State private var probeStatus: String?
    @State private var isProbing = false
    private var auth: AuthService { .shared }

    private struct EditingItem: Identifiable {
        let id = UUID()
        var existing: AuthService.SavedServer?
    }

    /// 保证当前正在使用的服务器也出现在列表顶部,便于管理与编辑。
    private var allServers: [AuthService.SavedServer] {
        var list = auth.savedServers
        if !list.contains(where: { $0.target == auth.serverTarget }) {
            list.insert(AuthService.SavedServer(name: nil, target: auth.serverTarget, email: auth.session?.email), at: 0)
        }
        return list
    }

    var body: some View {
        if embeddedInSplit {
            serverListContent
        } else {
            NavigationStack {
                serverListContent
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("关闭") { dismiss() }
                        }
                    }
            }
        }
    }

    private var serverListContent: some View {
        List {
            currentServerSection
            serverListSection
            Section {
                NavigationLink {
                    ProxySettingsView()
                } label: {
                    LabeledContent("出站网络代理", value: ProxyConfigStore.shared.config.summaryText)
                }
                .accessibilityIdentifier("server.proxySettings")
            } header: {
                Text("网络环境")
            }
        }
        .navigationTitle("服务器管理")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    editingServer = EditingItem(existing: nil)
                } label: {
                    HStack(spacing: 4) {
                        RabbitIcon(.plus, size: 16)
                        Text("添加")
                    }
                }
                .accessibilityIdentifier("server.add")
            }
        }
        .sheet(item: $editingServer) { item in
            ServerEditorSheet(existing: item.existing)
        }
        .confirmationDialog(
            "切换服务器？",
            isPresented: Binding(get: { pendingSwitch != nil }, set: { if !$0 { pendingSwitch = nil } }),
            titleVisibility: .visible
        ) {
            if let target = pendingSwitch {
                Button("退出并切换到 \(target.displayName)", role: .destructive) {
                    auth.switchToServer(target)
                    pendingSwitch = nil
                    ToastCenter.shared.show("已切换至 \(target.displayName)")
                    if !embeddedInSplit { dismiss() }
                }
            }
            Button("取消", role: .cancel) { pendingSwitch = nil }
        } message: {
            Text("切换到其他服务器将退出当前账号，需要重新登录。")
        }
    }

    private var currentServerSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    RabbitIcon(.server, size: 22)
                        .foregroundStyle(RCColor.accent)
                        .frame(width: 40, height: 40)
                        .background(RCColor.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(currentEntry.displayName).font(.headline)
                            Text(auth.serverTarget.useHTTPS ? "HTTPS" : "HTTP")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(auth.serverTarget.useHTTPS ? Color.green.opacity(0.15) : Color.orange.opacity(0.15),
                                            in: Capsule())
                                .foregroundStyle(auth.serverTarget.useHTTPS ? Color.green : Color.orange)
                        }
                        Text("\(auth.serverTarget.host):\(auth.serverTarget.effectiveAPIPort)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                HStack(spacing: 10) {
                    Button {
                        probeCurrent()
                    } label: {
                        HStack(spacing: 6) {
                            if isProbing { ProgressView().controlSize(.small) }
                            Text(isProbing ? "测试中…" : "测试连接")
                        }
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .background(RCColor.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                        .foregroundStyle(RCColor.accent)
                    }
                    .buttonStyle(.plain)
                    .disabled(isProbing)

                    Button {
                        editingServer = EditingItem(existing: currentEntry)
                    } label: {
                        Text("编辑")
                            .font(.subheadline.weight(.medium))
                            .frame(maxWidth: .infinity, minHeight: 36)
                            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                            .foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)
                }

                if let probeStatus {
                    Text(probeStatus)
                        .font(.caption)
                        .foregroundStyle(probeStatus.hasPrefix("连接成功") ? Color.green : Color.red)
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text("当前服务器")
        }
    }

    private var serverListSection: some View {
        Section {
            ForEach(allServers, id: \.id) { server in
                serverRow(server)
            }
        } header: {
            Text("全部服务器（\(allServers.count)）")
        } footer: {
            Text("点选服务器即可切换，每台服务器会独立记住最近登录的邮箱。左滑可删除未使用的服务器。")
        }
    }

    private func serverRow(_ server: AuthService.SavedServer) -> some View {
        let isCurrent = server.target == auth.serverTarget
        return HStack(spacing: 12) {
            Button {
                selectServer(server)
            } label: {
                HStack(spacing: 10) {
                    RabbitIcon(isCurrent ? .checkmark : .server, size: 20)
                        .foregroundStyle(isCurrent ? RCColor.accent : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(server.displayName)
                                .font(.body.weight(isCurrent ? .semibold : .regular))
                                .foregroundStyle(.primary)
                            if server.target.useHTTPS {
                                Text("HTTPS")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text("\(server.target.host):\(server.target.effectiveAPIPort)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        if let email = server.email, !email.isEmpty {
                            Text("最近账号：\(email)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                    if isCurrent {
                        Text("当前")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(RCColor.accent)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                editingServer = EditingItem(existing: server)
            } label: {
                RabbitIcon(.pencil, size: 16)
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("编辑 \(server.displayName)")
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if !isCurrent {
                Button(role: .destructive) {
                    auth.removeSavedServer(server)
                } label: {
                    Label("删除", rabbitIcon: .trash)
                }
            }
        }
    }

    private var currentEntry: AuthService.SavedServer {
        allServers.first(where: { $0.target == auth.serverTarget })
            ?? AuthService.SavedServer(name: nil, target: auth.serverTarget, email: auth.session?.email)
    }

    private func selectServer(_ server: AuthService.SavedServer) {
        guard server.target != auth.serverTarget else { return }
        if auth.isLoggedIn {
            pendingSwitch = server
        } else {
            auth.switchToServer(server)
            probeStatus = nil
            ToastCenter.shared.show("已切换至 \(server.displayName)")
            dismiss()
        }
    }

    private func probeCurrent() {
        isProbing = true
        probeStatus = nil
        let target = auth.serverTarget
        Task {
            switch await auth.probeServer(target) {
            case .success(let result):
                probeStatus = "连接成功 · \(result.latency) ms"
            case .failure(let error):
                probeStatus = error.localizedDescription
            }
            isProbing = false
        }
    }
}

/// 新增或编辑单台服务器配置。
private struct ServerEditorSheet: View {
    var existing: AuthService.SavedServer?
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var draft: AuthService.ServerTarget
    @State private var port: String
    @State private var signalPort: String
    @State private var relayPort: String
    @State private var switchImmediately: Bool
    @State private var probeStatus: String?
    @State private var isProbing = false
    private var auth: AuthService { .shared }

    init(existing: AuthService.SavedServer?) {
        self.existing = existing
        var target = existing?.target ?? AuthService.ServerTarget(host: "", useHTTPS: true)
        if existing == nil {
            target.apiPort = 21118
            target.signalPort = 21116
            target.relayPort = 21117
        }
        _name = State(initialValue: existing?.name ?? "")
        _draft = State(initialValue: target)
        _port = State(initialValue: String(target.effectiveAPIPort))
        _signalPort = State(initialValue: String(target.effectiveSignalPort))
        _relayPort = State(initialValue: String(target.effectiveRelayPort))
        _switchImmediately = State(initialValue: existing == nil && !AuthService.shared.isLoggedIn)
    }

    private var validation: String? {
        let host = draft.host.trimmingCharacters(in: .whitespacesAndNewlines)
        if host.isEmpty { return "请输入主机名或 IP。" }
        if host.contains(where: { $0.isWhitespace || "/?#@".contains($0) }) {
            return "只填主机名或 IP，不含协议或路径。"
        }
        guard (UInt16(port) ?? 0) > 0 else { return "API 端口必须是 1–65535 的整数。" }
        guard (UInt16(signalPort) ?? 0) > 0 else { return "信令端口必须是 1–65535 的整数。" }
        guard (UInt16(relayPort) ?? 0) > 0 else { return "中继端口必须是 1–65535 的整数。" }
        return nil
    }
    private var valid: Bool { validation == nil }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("备注名称（选填，如 公司 / 家里）", text: $name)
                    TextField("服务器主机名或 IP", text: $draft.host)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    LabeledContent("API 端口") {
                        TextField("21118", text: $port).keyboardType(.numberPad).multilineTextAlignment(.trailing)
                    }
                    LabeledContent("信令端口") {
                        TextField("21116", text: $signalPort).keyboardType(.numberPad).multilineTextAlignment(.trailing)
                            .accessibilityIdentifier("server.editor.signalPort")
                    }
                    LabeledContent("中继端口") {
                        TextField("21117", text: $relayPort).keyboardType(.numberPad).multilineTextAlignment(.trailing)
                            .accessibilityIdentifier("server.editor.relayPort")
                    }
                    Toggle("使用 HTTPS", isOn: $draft.useHTTPS)
                } header: { Text("服务器信息") } footer: {
                    Text(validation ?? "主机和端口分开填写。测试连接不会保存修改。")
                        .foregroundStyle(validation == nil ? Color.secondary : Color.red)
                }

                if draft.caCertPem != nil || draft.caFingerprintSha256 != nil {
                    Section("TLS 证书信任固定（TOFU）") {
                        if let fp = draft.caFingerprintSha256, !fp.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("已固定 SHA-256 指纹")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(fp)
                                    .font(.caption2.monospaced())
                                    .textSelection(.enabled)
                            }
                        } else {
                            Text("已锚定服务端自签 CA 证书")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Button("清除已固定证书并重新信任", role: .destructive) {
                            draft.caCertPem = nil
                            draft.caFingerprintSha256 = nil
                            probeStatus = nil
                        }
                    }
                }

                if !auth.isLoggedIn {
                    Section {
                        Toggle("保存后设为当前服务器", isOn: $switchImmediately)
                    }
                }

                Section {
                    Button {
                        probe()
                    } label: {
                        HStack {
                            Text("测试连接")
                            Spacer()
                            if isProbing { ProgressView() }
                        }
                    }
                    .disabled(!valid || isProbing)
                    .accessibilityIdentifier("server.editor.testConnection")
                    if let probeStatus {
                        Text(probeStatus)
                            .font(.footnote)
                            .foregroundStyle(probeStatus.hasPrefix("连接成功") ? Color.green : Color.red)
                    }
                }
            }
            .navigationTitle(existing == nil ? "添加服务器" : "编辑服务器")
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: draft.useHTTPS) { probeStatus = nil }
            .onChange(of: draft.host) { probeStatus = nil; draft.caCertPem = nil; draft.caFingerprintSha256 = nil }
            .onChange(of: port) { draft.apiPort = UInt16(port); draft.caCertPem = nil; draft.caFingerprintSha256 = nil; probeStatus = nil }
            .onChange(of: signalPort) { draft.signalPort = UInt16(signalPort) }
            .onChange(of: relayPort) { draft.relayPort = UInt16(relayPort) }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .accessibilityIdentifier("server.editor.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        var finalTarget = draft
                        finalTarget.host = finalTarget.host.trimmingCharacters(in: .whitespacesAndNewlines)
                        finalTarget.apiPort = UInt16(port)
                        finalTarget.signalPort = UInt16(signalPort)
                        finalTarget.relayPort = UInt16(relayPort)
                        auth.saveServer(name: name, target: finalTarget, replacing: existing)
                        if switchImmediately && !auth.isLoggedIn {
                            auth.serverTarget = finalTarget
                        }
                        dismiss()
                    }
                    .disabled(!valid || isProbing)
                    .accessibilityIdentifier("server.editor.save")
                }
            }
        }
    }

    private func probe() {
        isProbing = true
        probeStatus = nil
        var target = draft
        target.host = target.host.trimmingCharacters(in: .whitespacesAndNewlines)
        target.apiPort = UInt16(port)
        target.signalPort = UInt16(signalPort)
        target.relayPort = UInt16(relayPort)
        Task {
            switch await auth.probeServer(target) {
            case .success(let result):
                var updated = result.target
                updated.signalPort = target.signalPort
                updated.relayPort = target.relayPort
                draft = updated
                let regTag = auth.isRegistrationAllowed(for: updated) ? "" : " · 已关闭注册"
                probeStatus = "连接成功 · \(result.latency) ms\(regTag)"
            case .failure(let error):
                probeStatus = error.localizedDescription
            }
            isProbing = false
        }
    }
}
