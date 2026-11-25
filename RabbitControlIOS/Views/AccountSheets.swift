import SwiftUI

/// 修改密码弹层。
struct ChangePasswordSheet: View {
    @Environment(\.dismiss) private var dismiss
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
                SecureField("新密码(至少 8 位)", text: $new)
                SecureField("确认新密码", text: $confirm)
                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 12))
                        .foregroundStyle(RCColor.danger)
                }
            }
            .navigationTitle("修改密码")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
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
    @State private var host: String = ""
    @State private var useHTTPS = false
    @State private var probeStatus: String?
    @State private var isProbing = false

    private var auth: AuthService { .shared }

    var body: some View {
        NavigationStack {
            Form {
                Section("服务器地址") {
                    TextField("例如 127.0.0.1 或 rc.example.com", text: $host)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Toggle("使用 HTTPS", isOn: $useHTTPS)
                }
                Section {
                    Button {
                        probe()
                    } label: {
                        HStack {
                            Text("测试连接")
                            Spacer()
                            if isProbing {
                                ProgressView()
                            } else if let probeStatus {
                                Text(probeStatus)
                                    .font(.system(size: 13))
                                    .foregroundStyle(RCColor.textSecondary)
                            }
                        }
                    }
                    .disabled(host.isEmpty || isProbing)
                }
            }
            .navigationTitle("服务器设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        auth.serverTarget = .init(host: host, useHTTPS: useHTTPS)
                        dismiss()
                    }
                    .disabled(host.isEmpty)
                }
            }
            .onAppear {
                host = auth.serverTarget.host
                useHTTPS = auth.serverTarget.useHTTPS
            }
        }
    }

    private func probe() {
        isProbing = true
        probeStatus = nil
        let target = AuthService.ServerTarget(host: host, useHTTPS: useHTTPS)
        Task {
            let original = auth.serverTarget
            auth.serverTarget = target
            let result = await auth.probeServer()
            switch result {
            case .success(let ms):
                probeStatus = "连接成功 \(ms)ms"
            case .failure(let error):
                probeStatus = error.localizedDescription
                auth.serverTarget = original
            }
            isProbing = false
        }
    }
}
