import SwiftUI

/// 「我的」页(O3 账户移动端适配):账户卡片 + 设置入口列表。
struct ProfileView: View {
    @State private var showChangePassword = false
    @State private var showServerConfig = false
    @State private var showLogoutConfirm = false

    private var auth: AuthService { .shared }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("我的")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(RCColor.textPrimary)
                    .accessibilityAddTraits(.isHeader)

                // 账户卡片
                HStack(spacing: 14) {
                    Image(systemName: "person.circle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(RCColor.accent)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(auth.session?.email ?? MockData.accountPhone)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(RCColor.textPrimary)
                            .accessibilityIdentifier("profile.phone")
                        Text(auth.session?.displayName.isEmpty == false ? auth.session?.displayName ?? "" : "RabbitControl 账户")
                            .font(.system(size: 13))
                            .foregroundStyle(RCColor.textSecondary)
                    }
                    Spacer()
                }
                .padding(20)
                .background(.white, in: RoundedRectangle(cornerRadius: 12))

                if auth.isLoggedIn {
                    Button(role: .destructive) {
                        showLogoutConfirm = true
                    } label: {
                        Text("退出登录")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(RCColor.danger)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(.white, in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("profile.退出登录")
                }

                // 入口列表
                VStack(spacing: 0) {
                    NavigationLink {
                        SettingsView()
                    } label: {
                        rowContent(icon: "gearshape", title: "设置")
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("profile.设置")
                    divider
                    if auth.isLoggedIn {
                        Button {
                            showChangePassword = true
                        } label: {
                            rowContent(icon: "lock.shield", title: "修改密码")
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("profile.修改密码")
                        divider
                        Button {
                            showServerConfig = true
                        } label: {
                            rowContent(icon: "server.rack", title: "服务器设置")
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("profile.服务器设置")
                        divider
                    }
                    row(icon: "bell", title: "消息通知")
                    divider
                    row(icon: "info.circle", title: "关于 RabbitControl")
                }
                .background(.white, in: RoundedRectangle(cornerRadius: 12))
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 110)
        }
        .background(RCColor.bgPage)
        .navigationBarHidden(true)
        .sheet(isPresented: $showChangePassword) {
            ChangePasswordSheet()
        }
        .sheet(isPresented: $showServerConfig) {
            ServerConfigSheet()
        }
        .confirmationDialog("确定退出登录?", isPresented: $showLogoutConfirm, titleVisibility: .visible) {
            Button("退出登录", role: .destructive) {
                auth.logout()
            }
        }
    }

    private var divider: some View {
        RCColor.divider
            .frame(height: 1)
            .padding(.leading, 56)
    }

    private func rowContent(icon: String, title: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(RCColor.accent)
                .frame(width: 24)
            Text(title)
                .font(.system(size: 14))
                .foregroundStyle(RCColor.textPrimary)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 12))
                .foregroundStyle(RCColor.textDisabled)
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
    }

    private func row(icon: String, title: String) -> some View {
        Button {
            ToastCenter.shared.show("功能开发中")
        } label: {
            rowContent(icon: icon, title: title)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("profile.\(title)")
    }
}
