import SwiftUI
import UIKit

/// 首次登录强制改密门禁页（基线 §2.2：`must_change_password == true` 时阻塞进入主界面）。
struct ForceChangePasswordView: View {
    @FocusState private var focus: Field?
    private enum Field { case current, new, confirm }

    @State private var current = ""
    @State private var newPassword = ""
    @State private var confirm = ""
    @State private var isWorking = false
    @State private var uiError: RCUiError?
    @State private var showLogoutConfirm = false

    private var auth: AuthService { .shared }
    private var strength: LoginValidation.PasswordStrength { LoginValidation.evaluatePassword(newPassword) }
    private var canSubmit: Bool {
        !isWorking && !current.isEmpty && newPassword.count >= 8 && newPassword == confirm && current != newPassword
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(spacing: 10) {
                    RabbitIcon(.security, size: 28)
                        .foregroundStyle(RCColor.warning)
                        .frame(width: 56, height: 56)
                        .background(RCColor.warning.opacity(0.14), in: RoundedRectangle(cornerRadius: 15, style: .continuous))

                    Text("需要修改初始密码")
                        .font(.title2.bold())
                        .foregroundStyle(RCColor.textPrimary)

                    Text("为了保护「\(auth.session?.email ?? "当前账号")」下的设备安全，管理员要求首次登录先设置新密码后方可进入主界面。")
                        .font(.subheadline)
                        .foregroundStyle(RCColor.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 24)

                VStack(alignment: .leading, spacing: 12) {
                    SecureField("当前密码（初始密码）", text: $current)
                        .textContentType(.password)
                        .focused($focus, equals: .current)
                        .submitLabel(.next)
                        .onSubmit { focus = .new }
                        .padding(.horizontal, 12)
                        .frame(minHeight: 46)
                        .background(RCColor.bgPage, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .accessibilityIdentifier("forcePwd.current")

                    SecureField("新密码（至少 8 位，不可与原密码相同）", text: $newPassword)
                        .textContentType(.newPassword)
                        .focused($focus, equals: .new)
                        .submitLabel(.next)
                        .onSubmit { focus = .confirm }
                        .padding(.horizontal, 12)
                        .frame(minHeight: 46)
                        .background(RCColor.bgPage, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .accessibilityIdentifier("forcePwd.new")

                    if !newPassword.isEmpty {
                        Text(current == newPassword ? "新密码不能与当前密码相同" : strength.hint)
                            .font(.caption)
                            .foregroundStyle(current == newPassword ? RCColor.danger : RCColor.textSecondary)
                    }

                    SecureField("确认新密码", text: $confirm)
                        .textContentType(.newPassword)
                        .focused($focus, equals: .confirm)
                        .submitLabel(.go)
                        .onSubmit(submit)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 46)
                        .background(RCColor.bgPage, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .accessibilityIdentifier("forcePwd.confirm")

                    if !confirm.isEmpty && newPassword != confirm {
                        Text("两次输入的新密码不一致")
                            .font(.caption)
                            .foregroundStyle(RCColor.danger)
                    }

                    if let uiError {
                        RCInlineErrorView(error: uiError, onDismiss: { self.uiError = nil })
                    }

                    Button(action: submit) {
                        HStack(spacing: 8) {
                            if isWorking { ProgressView().tint(.white).controlSize(.small) }
                            Text(isWorking ? "正在保存新密码…" : "完成修改并进入")
                                .fontWeight(.semibold)
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(
                            canSubmit ? RCColor.accent : RCColor.accent.opacity(0.38),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSubmit)
                    .accessibilityIdentifier("forcePwd.submit")
                }
                .padding(18)
                .background(RCColor.bgWindow, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(RCColor.popoverStroke, lineWidth: 1)
                }

                Button("退出当前账号") {
                    showLogoutConfirm = true
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(RCColor.danger)
                .disabled(isWorking)
                .accessibilityIdentifier("forcePwd.logout")
            }
            .frame(maxWidth: 420)
            .padding(.horizontal, 20)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(RCColor.bgPage.ignoresSafeArea())
        .confirmationDialog("退出当前账号？", isPresented: $showLogoutConfirm, titleVisibility: .visible) {
            Button("退出登录", role: .destructive) { auth.logout() }
            Button("取消", role: .cancel) {}
        }
    }

    private func submit() {
        guard canSubmit else { return }
        focus = nil
        isWorking = true
        uiError = nil
        Task {
            do {
                try await auth.changePassword(current: current, new: newPassword)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                ToastCenter.shared.show("密码修改成功")
            } catch {
                uiError = (error as? AuthService.AuthError)?.uiError ?? RCUiErrorCodec.fromError(error)
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
            isWorking = false
        }
    }
}

/// 客户端本地锁遮罩层（基线 §2.4 `client_lock`）。
struct AppLockOverlayView: View {
    @State private var lockStore = AppLockStore.shared
    @State private var password = ""
    @State private var uiError: RCUiError?
    @State private var showLogoutConfirm = false
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()
            RCColor.bgPage.opacity(0.92).ignoresSafeArea()

            VStack(spacing: 20) {
                RabbitIcon(.lock, size: 28)
                    .foregroundStyle(RCColor.accent)
                    .frame(width: 58, height: 58)
                    .background(RCColor.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                VStack(spacing: 6) {
                    Text("RabbitControl 已锁定")
                        .font(.title3.bold())
                        .foregroundStyle(RCColor.textPrimary)
                    Text("请输入本地应用锁密码或使用生物识别验证以恢复访问")
                        .font(.footnote)
                        .foregroundStyle(RCColor.textSecondary)
                        .multilineTextAlignment(.center)
                }

                VStack(spacing: 12) {
                    SecureField("应用锁密码", text: $password)
                        .textContentType(.password)
                        .focused($focused)
                        .submitLabel(.go)
                        .onSubmit(unlockWithPassword)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 46)
                        .background(RCColor.bgPage, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .onChange(of: password) {
                            if uiError != nil { uiError = nil }
                        }
                        .accessibilityIdentifier("applock.password")

                    if let uiError {
                        RCInlineErrorView(error: uiError)
                    }

                    Button(action: unlockWithPassword) {
                        Text("解锁")
                            .fontWeight(.semibold)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, minHeight: 46)
                            .background(
                                password.isEmpty ? RCColor.accent.opacity(0.4) : RCColor.accent,
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(password.isEmpty)
                    .accessibilityIdentifier("applock.unlock")

                    if lockStore.biometricsEnabled, let bioLabel = lockStore.biometricTypeLabel {
                        Button {
                            Task { _ = await lockStore.unlockWithBiometrics() }
                        } label: {
                            HStack(spacing: 6) {
                                RabbitIcon(.security, size: 16)
                                Text("使用\(bioLabel)解锁")
                                    .font(.subheadline.weight(.medium))
                            }
                            .foregroundStyle(RCColor.accent)
                            .frame(maxWidth: .infinity, minHeight: 40)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("applock.biometric")
                    }
                }
                .padding(18)
                .background(RCColor.bgWindow, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(RCColor.popoverStroke, lineWidth: 1)
                }

                if AuthService.shared.isLoggedIn {
                    Button("忘记锁定密码？退出账号") {
                        showLogoutConfirm = true
                    }
                    .font(.caption)
                    .foregroundStyle(RCColor.textSecondary)
                }
            }
            .frame(maxWidth: 360)
            .padding(.horizontal, 24)
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityIdentifier("applock.overlay")
        .task {
            if lockStore.biometricsEnabled {
                _ = await lockStore.unlockWithBiometrics()
            }
        }
        .confirmationDialog("退出账号并清除登录会话？", isPresented: $showLogoutConfirm, titleVisibility: .visible) {
            Button("退出账号", role: .destructive) {
                AuthService.shared.logout()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("退出后需要重新输入账号密码登录。")
        }
    }

    private func unlockWithPassword() {
        guard !password.isEmpty else { return }
        switch lockStore.unlock(password: password) {
        case .success:
            password = ""
            uiError = nil
            focused = false
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .failure(let err):
            uiError = err
            password = ""
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }
}

/// 本地应用锁配置页（挂在「我的」与「设置」中）。
struct AppLockSettingsView: View {
    @State private var lockStore = AppLockStore.shared
    @State private var showSetupSheet = false
    @State private var showChangeSheet = false
    @State private var showDisableSheet = false

    var body: some View {
        Form {
            Section {
                HStack {
                    Label("本地应用锁", rabbitIcon: .lock)
                    Spacer()
                    Text(lockStore.isEnabled ? "已启用" : "未启用")
                        .foregroundStyle(lockStore.isEnabled ? RCColor.online : .secondary)
                }

                if lockStore.isEnabled {
                    if let bioLabel = lockStore.biometricTypeLabel {
                        Toggle("允许使用\(bioLabel)解锁", isOn: $lockStore.biometricsEnabled)
                    }
                    Picker("自动锁定时间", selection: $lockStore.autoLockDelay) {
                        ForEach(AppLockStore.AutoLockDelay.allCases) { item in
                            Text(item.label).tag(item)
                        }
                    }
                    Button {
                        lockStore.lockNow()
                    } label: {
                        Label("立即锁定客户端", rabbitIcon: .lock)
                    }
                    .accessibilityIdentifier("applock.lockNow")
                } else {
                    Button {
                        showSetupSheet = true
                    } label: {
                        Text("启用本地应用锁")
                            .fontWeight(.semibold)
                            .foregroundStyle(RCColor.accent)
                    }
                    .accessibilityIdentifier("applock.enable")
                }
            } footer: {
                Text("启用后，客户端锁定时将阻断一切出站远控连接、远程工具调用与敏感配置查看。")
            }

            if lockStore.isEnabled {
                Section("密码管理") {
                    Button("修改应用锁密码") { showChangeSheet = true }
                    Button("关闭本地应用锁", role: .destructive) { showDisableSheet = true }
                }
            }
        }
        .navigationTitle("本地应用锁")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showSetupSheet) {
            AppLockPasswordSheet(mode: .enable)
        }
        .sheet(isPresented: $showChangeSheet) {
            AppLockPasswordSheet(mode: .change)
        }
        .sheet(isPresented: $showDisableSheet) {
            AppLockPasswordSheet(mode: .disable)
        }
    }
}

private struct AppLockPasswordSheet: View {
    enum Mode { case enable, change, disable }
    var mode: Mode

    @Environment(\.dismiss) private var dismiss
    @State private var current = ""
    @State private var newPassword = ""
    @State private var confirm = ""
    @State private var uiError: RCUiError?

    private var titleText: String {
        switch mode {
        case .enable: "设置应用锁密码"
        case .change: "修改应用锁密码"
        case .disable: "关闭本地应用锁"
        }
    }

    private var canSave: Bool {
        switch mode {
        case .enable:
            return (4...32).contains(newPassword.count) && newPassword == confirm
        case .change:
            return !current.isEmpty && (4...32).contains(newPassword.count) && newPassword == confirm
        case .disable:
            return !current.isEmpty
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                if mode != .enable {
                    SecureField("当前应用锁密码", text: $current)
                }
                if mode != .disable {
                    SecureField("新锁定密码（4–32 位）", text: $newPassword)
                    SecureField("确认新锁定密码", text: $confirm)
                    if !confirm.isEmpty && newPassword != confirm {
                        Text("两次输入的密码不一致").foregroundStyle(RCColor.danger)
                    }
                }
                if let uiError {
                    RCInlineErrorView(error: uiError, onDismiss: { self.uiError = nil })
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }
            .navigationTitle(titleText)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("确定", action: submit)
                        .disabled(!canSave)
                }
            }
        }
    }

    private func submit() {
        do {
            switch mode {
            case .enable:
                try AppLockStore.shared.enable(newPassword: newPassword)
                ToastCenter.shared.show("已开启本地应用锁")
            case .change:
                try AppLockStore.shared.changePassword(current: current, newPassword: newPassword)
                ToastCenter.shared.show("已更新应用锁密码")
            case .disable:
                try AppLockStore.shared.disable(current: current)
                ToastCenter.shared.show("已关闭本地应用锁")
            }
            dismiss()
        } catch {
            uiError = RCUiErrorCodec.fromError(error)
        }
    }
}
