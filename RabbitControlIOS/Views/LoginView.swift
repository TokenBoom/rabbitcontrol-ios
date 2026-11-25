import SwiftUI

/// 登录 / 注册页:邮箱 + 密码,对接本地/远程 rabbitcontrol-server。
struct LoginView: View {
    @State private var email = ""
    @State private var password = ""
    @State private var isRegisterMode = false
    @State private var isWorking = false
    @State private var errorMessage: String?

    private var auth: AuthService { .shared }

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            VStack(spacing: 8) {
                Text("🐇")
                    .font(.system(size: 56))
                Text("RabbitControl")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(RCColor.textPrimary)
                Text("登录以管理你的设备")
                    .font(.system(size: 15))
                    .foregroundStyle(RCColor.textSecondary)
            }

            VStack(spacing: 12) {
                TextField("邮箱", text: $email)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(12)
                    .background(.white, in: RoundedRectangle(cornerRadius: 10))

                SecureField("密码(至少 8 位)", text: $password)
                    .padding(12)
                    .background(.white, in: RoundedRectangle(cornerRadius: 10))

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
                            ProgressView()
                        } else {
                            Text(isRegisterMode ? "注册并登录" : "登录")
                                .fontWeight(.semibold)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                }
                .buttonStyle(.borderedProminent)
                .tint(RCColor.accent)
                .disabled(!canSubmit)
                .accessibilityIdentifier("login.submit")

                Button(isRegisterMode ? "已有账号?去登录" : "没有账号?去注册") {
                    isRegisterMode.toggle()
                    errorMessage = nil
                }
                .font(.system(size: 13))
                .foregroundStyle(RCColor.accent)
            }
            .padding(.horizontal, 24)

            Spacer()
            Spacer()
        }
        .background(RCColor.bgPage.ignoresSafeArea())
    }

    private var canSubmit: Bool {
        !isWorking && email.contains("@") && password.count >= 8
    }

    private func submit() {
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
    LoginView()
}
