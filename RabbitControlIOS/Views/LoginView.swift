import SwiftUI

/// 登录 / 注册页:邮箱 + 密码,对接本地/远程 rabbitcontrol-server。
struct LoginView: View {
    var openAssist: () -> Void
    @State private var email = ""
    @State private var password = ""
    @State private var isRegisterMode = false
    @State private var isWorking = false
    @State private var errorMessage: String?

    @State private var showServer = false
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.dynamicTypeSize) private var typeSize
    @FocusState private var focus: Field?
    private enum Field { case email, password }
    private var auth: AuthService { .shared }

    private var landscape: Bool { verticalSizeClass == .compact && !typeSize.isAccessibilitySize }

    var body: some View {
        let layout = landscape ? AnyLayout(HStackLayout(spacing: 32)) : AnyLayout(VStackLayout(spacing: 24))
        ScrollView {
            layout {
                VStack(spacing: 12) {
                    header
                    if landscape { serverButton }
                }
                fields.disabled(isWorking)
                if !landscape { serverButton }
            }
            .frame(maxWidth: 720)
            .padding(.horizontal, 24).padding(.vertical, landscape || focus != nil ? 12 : 32)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .sheet(isPresented: $showServer) { ServerConfigSheet() }
        .background(RCColor.bgPage)
    }

    private var serverButton: some View {
        Button("服务器设置") { focus = nil; showServer = true }.disabled(isWorking)
    }

    private var header: some View {
        VStack(spacing: 8) {
            if focus == nil {
                RabbitIcon(.devices, size: landscape ? 34 : 48)
                    .foregroundStyle(.tint)
            }
            Text("RabbitControl")
                .font(.title.bold())
                .foregroundStyle(RCColor.textPrimary)
            Button("免登录直连", action: openAssist)
                .disabled(isWorking)
                .buttonStyle(.bordered).accessibilityIdentifier("devices.assist")
            Text(isRegisterMode ? "创建账号，在多台设备间使用远程协助" : "登录以查看和控制账号下的设备")
                .font(.subheadline)
                .foregroundStyle(RCColor.textSecondary)
        }
    }

    private var fields: some View {
        VStack(spacing: 12) {
            TextField("邮箱", text: $email)
                .textContentType(.username).focused($focus, equals: .email)
                .submitLabel(.next).onSubmit { focus = .password }
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(12)
                .background(RCColor.bgWindow, in: RoundedRectangle(cornerRadius: 10))

            SecureField(isRegisterMode ? "新密码（至少 8 位）" : "密码", text: $password)
                .textContentType(isRegisterMode ? .newPassword : .password).focused($focus, equals: .password)
                .submitLabel(.go).onSubmit(submit)
                .padding(12)
                .background(RCColor.bgWindow, in: RoundedRectangle(cornerRadius: 10))

            if isRegisterMode && (1..<8).contains(password.count) {
                Text("密码至少需要 8 位").font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(RCColor.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button {
                submit()
            } label: {
                Group {
                    if isWorking {
                        ProgressView(isRegisterMode ? "正在注册…" : "正在登录…")
                    } else {
                        Text(isRegisterMode ? "注册并登录" : "登录")
                            .fontWeight(.semibold)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(minHeight: 48)
            }
            .buttonStyle(.borderedProminent)
            .tint(RCColor.accent)
            .disabled(!canSubmit)
            .accessibilityIdentifier("login.submit")

            Button(isRegisterMode ? "已有账号?去登录" : "没有账号?去注册") {
                focus = nil
                isRegisterMode.toggle()
                errorMessage = nil
            }
            .disabled(isWorking)
            .accessibilityIdentifier("login.switchMode")
            .font(.subheadline)
            .foregroundStyle(RCColor.accent)
        }
    }

    private var canSubmit: Bool {
        !isWorking && email.contains("@") && (isRegisterMode ? password.count >= 8 : !password.isEmpty)
    }

    private func submit() {
        guard canSubmit else { return }
        focus = nil
        email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        isWorking = true
        errorMessage = nil
        Task {
            do {
                if isRegisterMode {
                    try await auth.register(email: email, password: password)
                } else {
                    try await auth.login(email: email, password: password)
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }
}

#Preview {
    LoginView(openAssist: {})
}
