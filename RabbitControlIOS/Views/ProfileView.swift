import SwiftUI

struct ProfileView: View {
    let openLogin: () -> Void
    @State private var showChangePassword = false
    @State private var showServerConfig = false
    @State private var showLogoutConfirm = false
    private var auth: AuthService { .shared }

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    RabbitIcon(.person, size: 42).foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(auth.session?.displayName.nonEmpty ?? "RabbitControl 账户").font(.headline)
                        Text(auth.session?.email ?? "未登录").font(.subheadline).foregroundStyle(.secondary)
                            .accessibilityIdentifier("profile.phone")
                    }
                }.padding(.vertical, 6)
                if !auth.isLoggedIn { Button("前往登录", action: openLogin) }
            }
            Section("偏好与连接") {
                NavigationLink { SettingsView() } label: { Label("设置", rabbitIcon: .settings) }
                    .accessibilityIdentifier("profile.设置")
                Button { showServerConfig = true } label: { Label("服务器设置", rabbitIcon: .server) }
                    .accessibilityIdentifier("profile.服务器设置")
            }
            if auth.isLoggedIn {
                Section("账号安全") {
                    Button { showChangePassword = true } label: { Label("修改密码", rabbitIcon: .security) }
                        .accessibilityIdentifier("profile.修改密码")
                    Button("退出登录", role: .destructive) { showLogoutConfirm = true }
                        .accessibilityIdentifier("profile.退出登录")
                }
            }
            Section("关于") {
                LabeledContent("RabbitControl", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
            }
        }
        .navigationTitle("我的")
        .sheet(isPresented: $showChangePassword) { ChangePasswordSheet() }
        .sheet(isPresented: $showServerConfig) { ServerConfigSheet() }
        .confirmationDialog("退出当前账号？", isPresented: $showLogoutConfirm, titleVisibility: .visible) {
            Button("退出登录", role: .destructive) { auth.logout(); openLogin() }
            Button("取消", role: .cancel) {}
        } message: { Text("将断开当前会话并清除本机账号信息，不会解绑设备。") }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
