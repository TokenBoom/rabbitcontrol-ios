import SwiftUI

/// 修改密码弹层。
struct ChangePasswordSheet: View {
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focus: Field?
    private enum Field { case current, new, confirm }
    @State private var current = ""
    @State private var new = ""
    @State private var confirm = ""
    @State private var isWorking = false
    @State private var errorMessage: String?

    private var auth: AuthService { .shared }

    var body: some View {
        NavigationStack {
            Form {
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
                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 12))
                        .foregroundStyle(RCColor.danger)
                }
            }
            .navigationTitle("修改密码")
            .disabled(isWorking).interactiveDismissDisabled(isWorking)
            .scrollDismissesKeyboard(.interactively)
            .navigationBarTitleDisplayMode(.inline)
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

    private var canSubmit: Bool {
        !isWorking && !current.isEmpty && new.count >= 8 && new == confirm
    }

    private func submit() {
        guard canSubmit else { return }
        focus = nil
        isWorking = true
        errorMessage = nil
        Task {
            do {
                try await auth.changePassword(current: current, new: new)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }
}

/// 服务器设置弹层:地址编辑 + 连通性探测。
struct ServerConfigSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft = AuthService.shared.serverTarget
    @State private var port = String(AuthService.shared.serverTarget.effectiveAPIPort)
    @State private var probeStatus: String?
    @State private var isProbing = false
    private var auth: AuthService { .shared }
    private var validation: String? {
        let host = draft.host.trimmingCharacters(in: .whitespacesAndNewlines)
        if host.isEmpty { return "请输入主机名或 IP。" }
        if host.contains(where: { $0.isWhitespace || "/?#@".contains($0) }) {
            return "只填主机名或 IP，不含协议或路径。"
        }
        return (UInt16(port) ?? 0) > 0 ? nil : "API 端口必须是 1–65535 的整数。"
    }
    private var valid: Bool { validation == nil }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("服务器主机名或 IP", text: $draft.host)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    LabeledContent("API 端口") {
                        TextField("21118", text: $port).keyboardType(.numberPad).multilineTextAlignment(.trailing)
                    }
                    Toggle("使用 HTTPS", isOn: $draft.useHTTPS)
                } header: { Text("服务器地址") } footer: {
                    if auth.isLoggedIn { Text("退出登录后可更换服务器。") }
                    else { Text(validation ?? "主机和端口分别填写。测试连接不会保存修改。") }
                }.disabled(isProbing || auth.isLoggedIn)
                Section {
                    Button("测试连接") { probe() }.disabled(!valid || isProbing)
                    if isProbing { ProgressView("正在测试…") }
                    else if let probeStatus { Text(probeStatus).font(.footnote) }
                }
                if !auth.savedServers.isEmpty {
                    Section {
                        ForEach(auth.savedServers) { server in
                            Button {
                                draft = server.target
                                port = String(server.target.effectiveAPIPort)
                                if !auth.isLoggedIn { auth.switchToServer(server) }
                            } label: {
                                HStack {
                                    Label(server.target.host, rabbitIcon: .server)
                                        .foregroundStyle(.primary)
                                    if server.target.useHTTPS {
                                        Text("HTTPS").font(.caption2).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if server.target == auth.serverTarget {
                                        Text("当前").font(.caption).foregroundStyle(RCColor.accent)
                                    }
                                    if let email = server.email {
                                        Text(email).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                            }
                            .swipeActions {
                                Button(role: .destructive) { auth.removeSavedServer(server) } label: {
                                    Label("删除", rabbitIcon: .trash)
                                }
                            }
                        }
                    } header: { Text("常用服务器") } footer: {
                        Text("登录成功后会自动保存服务器并记住邮箱；点选即可切换。")
                    }
                }
            }
            .navigationTitle("服务器设置").navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: draft.useHTTPS) { probeStatus = nil }
            .onChange(of: draft.host) { probeStatus = nil; draft.caCertPem = nil }
            .onChange(of: port) { draft.apiPort = UInt16(port); draft.caCertPem = nil; probeStatus = nil }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
                if !auth.isLoggedIn {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") {
                            draft.host = draft.host.trimmingCharacters(in: .whitespacesAndNewlines)
                            auth.serverTarget = draft
                            dismiss()
                        }.disabled(!valid || isProbing)
                    }
                }
            }
        }
    }

    private func probe() {
        isProbing = true
        draft.host = draft.host.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            switch await auth.probeServer(draft) {
            case .success(let result):
                draft = result.target
                probeStatus = "连接成功 · \(result.latency) ms"
            case .failure(let error): probeStatus = error.localizedDescription
            }
            isProbing = false
        }
    }
}
