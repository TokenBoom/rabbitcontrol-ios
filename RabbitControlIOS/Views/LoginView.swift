import SwiftUI
import UIKit

/// 登录与注册表单校验及密码强度评估。
enum LoginValidation {
    enum PasswordStrength: Equatable {
        case empty
        case tooShort(remaining: Int)
        case fair
        case good
        case strong

        var filledSegments: Int {
            switch self {
            case .empty: 0
            case .tooShort: 1
            case .fair: 2
            case .good, .strong: 3
            }
        }

        var hint: String {
            switch self {
            case .empty: "密码至少 8 位"
            case .tooShort(let remaining): "还差 \(remaining) 位（至少 8 位）"
            case .fair: "长度已达标 · 建议混合字母与数字"
            case .good: "密码强度良好"
            case .strong: "密码强度高"
            }
        }

        var tint: Color {
            switch self {
            case .empty: RCColor.textDisabled
            case .tooShort: RCColor.warning
            case .fair: RCColor.accent
            case .good, .strong: RCColor.online
            }
        }
    }

    static func isValidEmail(_ raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(where: \.isWhitespace) else { return false }
        let parts = text.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        let local = parts[0]
        let domain = parts[1]
        guard !local.isEmpty, !domain.isEmpty,
              !domain.hasPrefix("."), !domain.hasSuffix("."),
              !domain.contains("..") else {
            return false
        }
        return true
    }

    static func evaluatePassword(_ password: String) -> PasswordStrength {
        guard !password.isEmpty else { return .empty }
        if password.count < 8 {
            return .tooShort(remaining: 8 - password.count)
        }
        var variety = 0
        if password.contains(where: \.isLowercase) { variety += 1 }
        if password.contains(where: \.isUppercase) { variety += 1 }
        if password.contains(where: \.isNumber) { variety += 1 }
        if password.contains(where: { !$0.isLetter && !$0.isNumber }) { variety += 1 }

        if password.count >= 12 && variety >= 3 { return .strong }
        if variety >= 2 || password.count >= 12 { return .good }
        return .fair
    }
}

/// 登录 / 注册页:邮箱 + 密码,对接本地/远程 rabbitcontrol-server。
struct LoginView: View {
    @State private var email = ""
    @State private var password = ""
    @State private var isRegisterMode = false
    @State private var isPasswordVisible = false
    @State private var emailTouched = false
    @State private var isWorking = false
    @State private var loginUiError: RCUiError?
    @State private var errorShakeTrigger = 0
    @State private var showServer = false
    @State private var observedServerTarget = AuthService.shared.serverTarget

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.dynamicTypeSize) private var typeSize
    @FocusState private var focus: Field?
    @State private var viewportSize = CGSize.zero

    private enum Field: Hashable {
        case email
        case passwordSecure
        case passwordPlain
    }

    private var auth: AuthService { .shared }
    private var landscape: Bool { verticalSizeClass == .compact && !typeSize.isAccessibilitySize }
    private var isPadTwoColumn: Bool {
        horizontalSizeClass == .regular
            && RCLayout.prefersTwoColumnLogin(
                horizontalSizeClass: horizontalSizeClass,
                verticalSizeClass: verticalSizeClass,
                viewportSize: viewportSize,
                isAccessibilityType: typeSize.isAccessibilitySize
            )
    }
    private var trimmedEmail: String { email.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isPasswordFocused: Bool { focus == .passwordSecure || focus == .passwordPlain }
    private var passwordStrength: LoginValidation.PasswordStrength { LoginValidation.evaluatePassword(password) }

    private var showEmailWarning: Bool {
        emailTouched && !trimmedEmail.isEmpty && !LoginValidation.isValidEmail(trimmedEmail)
    }

    private var canSubmit: Bool {
        !isWorking
            && LoginValidation.isValidEmail(trimmedEmail)
            && (isRegisterMode ? password.count >= 8 : !password.isEmpty)
    }

    private var submitTitle: String {
        if isWorking {
            return isRegisterMode ? "正在注册…" : "正在登录…"
        }
        return isRegisterMode ? "注册并登录" : "登录"
    }

    private var currentSavedServer: AuthService.SavedServer? {
        auth.savedServers.first(where: { $0.target == auth.serverTarget })
    }

    private var currentServerTitle: String {
        if let name = currentSavedServer?.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        if auth.serverTarget == .local {
            return "本机默认服务"
        }
        return auth.serverTarget.host
    }

    private var currentServerAddress: String {
        "\(auth.serverTarget.host):\(auth.serverTarget.effectiveAPIPort)"
    }

    private var shouldSuggestServerConfig: Bool {
        guard let err = loginUiError else { return false }
        if auth.serverTarget == .local { return true }
        return err.action == .openSettings
            || err.code.hasPrefix("network.")
            || err.code.hasPrefix("pki.")
            || err.code.hasPrefix("proxy.")
            || err.code.hasPrefix("server.")
    }

    var body: some View {
        ScrollView {
            Group {
                if isPadTwoColumn {
                    padWorkspaceCard
                        .frame(minHeight: max(viewportSize.height - 64, 420))
                } else if landscape {
                    HStack(alignment: .center, spacing: 28) {
                        VStack(alignment: .leading, spacing: 14) {
                            landscapeHeader
                            serverSection
                        }
                        .frame(maxWidth: 268, alignment: .leading)

                        fieldsCard
                            .frame(maxWidth: 380)
                    }
                } else {
                    VStack(spacing: focus == nil ? 22 : 14) {
                        portraitHeader
                        fieldsCard
                        serverSection
                    }
                    .frame(maxWidth: 420)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, isPadTwoColumn ? 32 : (landscape ? 12 : (focus != nil ? 16 : 32)))
            .frame(maxWidth: .infinity)
        }
        .onGeometryChange(for: CGSize.self) { geo in
            geo.size
        } action: { newSize in
            viewportSize = newSize
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollDismissesKeyboard(.interactively)
        .contentShape(Rectangle())
        .onTapGesture {
            if focus != nil { focus = nil }
        }
        .sheet(isPresented: $showServer) { ServerConfigSheet() }
        .onAppear {
            observedServerTarget = auth.serverTarget
            if email.isEmpty, let remembered = auth.rememberedEmail {
                email = remembered
            }
            refreshServerRegistrationPolicy()
        }
        .onChange(of: showServer) {
            guard !showServer else { return }
            syncServerSelectionIfNeeded()
        }
        .onChange(of: auth.isRegistrationAllowed()) { _, allowed in
            if !allowed && isRegisterMode {
                isRegisterMode = false
            }
        }
        .onChange(of: focus) { oldValue, newValue in
            if oldValue == .email, newValue != .email, !trimmedEmail.isEmpty {
                withAnimation(.easeOut(duration: 0.16)) {
                    emailTouched = true
                }
            }
        }
        .onChange(of: email) {
            if trimmedEmail.isEmpty { emailTouched = false }
            if loginUiError != nil { loginUiError = nil }
        }
        .onChange(of: password) {
            if loginUiError != nil { loginUiError = nil }
        }
        .animation(.snappy(duration: 0.22), value: focus != nil)
        .background(RCColor.bgPage.ignoresSafeArea())
    }

    // MARK: - 顶部品牌区

    private var portraitHeader: some View {
        VStack(spacing: focus == nil ? 10 : 6) {
            brandBadge(size: focus == nil ? 58 : 42, cornerRadius: focus == nil ? 14 : 10)

            Text("RabbitControl")
                .font(focus == nil ? .title.bold() : .title2.bold())
                .foregroundStyle(RCColor.textPrimary)

            Text(isRegisterMode ? "创建账号，在多台设备间使用远程协助" : "登录以查看和控制账号下的设备")
                .font(.subheadline)
                .foregroundStyle(RCColor.textSecondary)
                .multilineTextAlignment(.center)
                .contentTransition(.opacity)
        }
        .padding(.top, focus == nil ? 4 : 0)
    }

    private var landscapeHeader: some View {
        HStack(spacing: 12) {
            brandBadge(size: 44, cornerRadius: 11)
            VStack(alignment: .leading, spacing: 3) {
                Text("RabbitControl")
                    .font(.title3.bold())
                    .foregroundStyle(RCColor.textPrimary)
                Text(isRegisterMode ? "创建账号，跨设备远程协助" : "登录以查看和控制账号下的设备")
                    .font(.footnote)
                    .foregroundStyle(RCColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var padWorkspaceCard: some View {
        HStack(alignment: .center, spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                brandBadge(size: 56, cornerRadius: 14)

                VStack(alignment: .leading, spacing: 6) {
                    Text("RabbitControl")
                        .font(.title.bold())
                        .foregroundStyle(RCColor.textPrimary)
                    Text(isRegisterMode ? "创建账号后，即可在 iPad 上统一管理并远程操控多台电脑。" : "登录你的账号，在大屏工作台中查看设备状态、启动高清远控或打开终端。")
                        .font(.subheadline)
                        .foregroundStyle(RCColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                RCColor.divider.frame(height: 0.5)

                VStack(alignment: .leading, spacing: 8) {
                    Text("当前连接服务器")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(RCColor.textSecondary)
                    serverSection
                }
            }
            .padding(28)
            .frame(maxWidth: 330, alignment: .leading)

            RCColor.divider
                .frame(width: 0.5)
                .padding(.vertical, 24)

            VStack(alignment: .leading, spacing: 14) {
                Text(isRegisterMode ? "注册账号" : "账号登录")
                    .font(.title3.bold())
                    .foregroundStyle(RCColor.textPrimary)

                emailInputSection
                passwordInputSection

                if let loginUiError {
                    RCInlineErrorView(
                        error: loginUiError,
                        actionLabelOverride: shouldSuggestServerConfig ? "检查服务器" : nil,
                        onAction: shouldSuggestServerConfig ? { _ in
                            focus = nil
                            showServer = true
                        } : nil
                    )
                    .accessibilityIdentifier("login.errorBanner")
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                submitButton
                    .padding(.top, 4)

                switchModeButton
            }
            .padding(28)
            .frame(maxWidth: 420)
            .keyframeAnimator(initialValue: CGFloat.zero, trigger: errorShakeTrigger) { content, offset in
                content.offset(x: offset)
            } keyframes: { _ in
                CubicKeyframe(-8, duration: 0.055)
                CubicKeyframe(7, duration: 0.055)
                CubicKeyframe(-5, duration: 0.055)
                CubicKeyframe(4, duration: 0.055)
                CubicKeyframe(0, duration: 0.07)
            }
        }
        .background(RCColor.bgWindow, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(RCColor.popoverStroke, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.06), radius: 18, y: 6)
    }

    private func brandBadge(size: CGFloat, cornerRadius: CGFloat) -> some View {
        Group {
            if let icon = Self.bundledAppIcon {
                Image(uiImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
                    .scaleEffect(1.06)
            } else {
                ZStack {
                    LinearGradient(
                        colors: [Color(hex: 0x3C8CE7), RCColor.accent],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    RabbitIcon(.devices, size: size * 0.52)
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .shadow(color: RCColor.accent.opacity(0.20), radius: 10, y: 4)
        .accessibilityHidden(true)
    }

    private static let bundledAppIcon: UIImage? = {
        if let icons = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any],
           let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
           let files = primary["CFBundleIconFiles"] as? [String],
           let name = files.last,
           let image = UIImage(named: name) {
            return image
        }
        return UIImage(named: "AppIcon")
    }()

    // MARK: - 登录 / 注册表单卡

    private var fieldsCard: some View {
        VStack(spacing: landscape ? 10 : 12) {
            emailInputSection
            passwordInputSection

            if let loginUiError {
                RCInlineErrorView(
                    error: loginUiError,
                    actionLabelOverride: shouldSuggestServerConfig ? "检查服务器" : nil,
                    onAction: shouldSuggestServerConfig ? { _ in
                        focus = nil
                        showServer = true
                    } : nil
                )
                .accessibilityIdentifier("login.errorBanner")
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            submitButton
                .padding(.top, 2)

            if auth.isRegistrationAllowed() {
                switchModeButton
            } else {
                Text("当前服务器已关闭新用户自助注册，请联系管理员开通账号")
                    .font(.caption)
                    .foregroundStyle(RCColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, minHeight: landscape ? 28 : 32)
                    .accessibilityIdentifier("login.registrationDisabledHint")
            }
        }
        .padding(landscape ? 16 : 18)
        .background(RCColor.bgWindow, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(RCColor.popoverStroke, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.05), radius: 14, y: 5)
        .keyframeAnimator(initialValue: CGFloat.zero, trigger: errorShakeTrigger) { content, offset in
            content.offset(x: offset)
        } keyframes: { _ in
            CubicKeyframe(-8, duration: 0.055)
            CubicKeyframe(7, duration: 0.055)
            CubicKeyframe(-5, duration: 0.055)
            CubicKeyframe(4, duration: 0.055)
            CubicKeyframe(0, duration: 0.07)
        }
    }

    private var emailInputSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                RabbitIcon(.mail, size: 18)
                    .foregroundStyle(focus == .email ? RCColor.accent : RCColor.textSecondary)

                TextField("邮箱", text: $email)
                    .textContentType(.username)
                    .focused($focus, equals: .email)
                    .submitLabel(.next)
                    .onSubmit(focusPassword)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .disabled(isWorking)
                    .accessibilityIdentifier("login.email")

                if !email.isEmpty && !isWorking {
                    Button {
                        email = ""
                        emailTouched = false
                        focus = .email
                    } label: {
                        RabbitIcon(.close, size: 12)
                            .foregroundStyle(RCColor.textSecondary)
                            .frame(width: 24, height: 24)
                            .background(Color.secondary.opacity(0.14), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("清除邮箱")
                    .accessibilityIdentifier("login.clearEmail")
                } else if email.isEmpty, let remembered = auth.rememberedEmail, !remembered.isEmpty, !isWorking {
                    Button {
                        email = remembered
                        focusPassword()
                    } label: {
                        Text("最近账号")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(RCColor.accent)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(RCColor.accent.opacity(0.12), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("填入最近登录邮箱 \(remembered)")
                    .accessibilityIdentifier("login.fillRememberedEmail")
                }
            }
            .padding(.horizontal, 12)
            .frame(minHeight: landscape ? 44 : 48)
            .background(RCColor.bgPage, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(emailBorderColor, lineWidth: focus == .email || showEmailWarning ? 1.5 : 0.5)
            }

            if showEmailWarning {
                Text("请输入有效的邮箱地址（如 name@example.com）")
                    .font(.caption)
                    .foregroundStyle(RCColor.danger)
                    .transition(.opacity)
            }
        }
    }

    private var emailBorderColor: Color {
        if showEmailWarning { return RCColor.danger.opacity(0.75) }
        if focus == .email { return RCColor.accent }
        return RCColor.stroke.opacity(0.35)
    }

    private var passwordInputSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                RabbitIcon(.lock, size: 18)
                    .foregroundStyle(isPasswordFocused ? RCColor.accent : RCColor.textSecondary)

                // 同时保留 SecureField 与明文 TextField 在视图树中，避免切换显隐时 SecureField 卸载误触系统「保存密码？」弹窗
                ZStack {
                    SecureField(isRegisterMode ? "设置密码（至少 8 位）" : "密码", text: $password)
                        .textContentType(isRegisterMode ? .newPassword : .password)
                        .focused($focus, equals: .passwordSecure)
                        .submitLabel(.go)
                        .onSubmit(submit)
                        .opacity(isPasswordVisible ? 0 : 1)
                        .allowsHitTesting(!isPasswordVisible)
                        .accessibilityHidden(isPasswordVisible)
                        .accessibilityIdentifier("login.password")

                    TextField(isRegisterMode ? "设置密码（至少 8 位）" : "密码", text: $password)
                        .textContentType(isRegisterMode ? .newPassword : .password)
                        .focused($focus, equals: .passwordPlain)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.go)
                        .onSubmit(submit)
                        .opacity(isPasswordVisible ? 1 : 0)
                        .allowsHitTesting(isPasswordVisible)
                        .accessibilityHidden(!isPasswordVisible)
                        .accessibilityIdentifier("login.password")
                }
                .disabled(isWorking)

                Button {
                    togglePasswordVisibility()
                } label: {
                    RabbitIcon(isPasswordVisible ? .eyeOff : .eye, size: 18)
                        .foregroundStyle(isPasswordVisible ? RCColor.accent : RCColor.textSecondary)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isWorking)
                .accessibilityLabel(isPasswordVisible ? "隐藏密码" : "显示密码")
                .accessibilityIdentifier("login.togglePassword")
            }
            .padding(.horizontal, 12)
            .frame(minHeight: landscape ? 44 : 48)
            .background(RCColor.bgPage, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        isPasswordFocused ? RCColor.accent : RCColor.stroke.opacity(0.35),
                        lineWidth: isPasswordFocused ? 1.5 : 0.5
                    )
            }

            if isRegisterMode && !password.isEmpty {
                passwordStrengthBar
                    .transition(.opacity)
            }
        }
    }

    private var passwordStrengthBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                ForEach(1...3, id: \.self) { index in
                    Capsule()
                        .fill(index <= passwordStrength.filledSegments ? passwordStrength.tint : Color.secondary.opacity(0.20))
                        .frame(width: 22, height: 4)
                }
            }
            Text(passwordStrength.hint)
                .font(.caption)
                .foregroundStyle(passwordStrength == .tooShort(remaining: 8 - password.count) ? RCColor.warning : RCColor.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .animation(.easeOut(duration: 0.18), value: passwordStrength)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("login.passwordStrength")
    }

    private var submitButton: some View {
        Button(action: submit) {
            HStack(spacing: 8) {
                if isWorking {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                    Text(submitTitle)
                        .fontWeight(.semibold)
                } else {
                    Text(submitTitle)
                        .fontWeight(.semibold)
                    RabbitIcon(.arrowRight, size: 16)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: landscape ? 44 : 48)
        }
        .buttonStyle(RCLoginPrimaryButtonStyle(enabled: canSubmit))
        .disabled(!canSubmit)
        .accessibilityLabel(submitTitle)
        .accessibilityIdentifier("login.submit")
    }

    private var switchModeButton: some View {
        Button {
            focus = nil
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation(.snappy(duration: 0.22)) {
                isRegisterMode.toggle()
                loginUiError = nil
            }
        } label: {
            HStack(spacing: 4) {
                Text(isRegisterMode ? "已有账号？" : "没有账号？")
                    .foregroundStyle(RCColor.textSecondary)
                Text(isRegisterMode ? "去登录" : "去注册")
                    .fontWeight(.semibold)
                    .foregroundStyle(RCColor.accent)
            }
            .font(.subheadline)
            .frame(maxWidth: .infinity, minHeight: landscape ? 32 : 38)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isWorking)
        .accessibilityLabel(isRegisterMode ? "已有账号？去登录" : "没有账号？去注册")
        .accessibilityIdentifier("login.switchMode")
    }

    // MARK: - 服务器状态与快速切换

    private var serverSection: some View {
        VStack(alignment: (landscape || isPadTwoColumn) ? .leading : .center, spacing: 8) {
            Button {
                focus = nil
                showServer = true
            } label: {
                HStack(spacing: 10) {
                    RabbitIcon(.server, size: 16)
                        .foregroundStyle(RCColor.accent)
                        .frame(width: 30, height: 30)
                        .background(RCColor.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                    VStack(alignment: .leading, spacing: 1.5) {
                        HStack(spacing: 6) {
                            Text(currentServerTitle)
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(RCColor.textPrimary)
                                .lineLimit(1)

                            Text(auth.serverTarget.useHTTPS ? "HTTPS" : "HTTP")
                                .font(.system(size: 10, weight: .semibold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1.5)
                                .background(
                                    (auth.serverTarget.useHTTPS ? RCColor.online : RCColor.warning).opacity(0.15),
                                    in: Capsule()
                                )
                                .foregroundStyle(auth.serverTarget.useHTTPS ? RCColor.online : RCColor.warning)
                        }

                        Text(currentServerAddress)
                            .font(.caption2.monospaced())
                            .foregroundStyle(RCColor.textSecondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 6)

                    HStack(spacing: 2) {
                        Text("设置")
                            .font(.caption.weight(.medium))
                        RabbitIcon(.chevronRight, size: 13)
                    }
                    .foregroundStyle(RCColor.textSecondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(RCColor.bgWindow, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(RCColor.popoverStroke, lineWidth: 1)
                }
            }
            .buttonStyle(RCSurfacePressButtonStyle())
            .disabled(isWorking)
            .accessibilityLabel("服务器设置")
            .accessibilityValue("\(currentServerTitle), \(currentServerAddress), \(auth.serverTarget.useHTTPS ? "HTTPS" : "HTTP")")
            .accessibilityIdentifier("服务器设置")

            if auth.savedServers.count > 1 {
                savedServersStrip
            }
        }
    }

    private var savedServersStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(auth.savedServers) { server in
                    let selected = server.target == auth.serverTarget
                    Button {
                        guard !selected else { return }
                        focus = nil
                        auth.switchToServer(server)
                        observedServerTarget = auth.serverTarget
                        if let remembered = server.email, !remembered.isEmpty {
                            email = remembered
                        }
                        loginUiError = nil
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        ToastCenter.shared.show("已切换至 \(server.displayName)")
                    } label: {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(selected ? RCColor.accent : RCColor.textDisabled)
                                .frame(width: 6, height: 6)
                            Text(server.displayName)
                                .font(.caption.weight(selected ? .semibold : .regular))
                                .lineLimit(1)
                        }
                        .foregroundStyle(selected ? RCColor.accent : RCColor.textSecondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            selected ? RCColor.accent.opacity(0.12) : RCColor.bgWindow,
                            in: Capsule()
                        )
                        .overlay {
                            Capsule()
                                .strokeBorder(selected ? RCColor.accent.opacity(0.35) : RCColor.popoverStroke, lineWidth: 1)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(isWorking)
                    .accessibilityLabel("切换到服务器 \(server.displayName)")
                }
            }
            .padding(.horizontal, 2)
        }
    }

    // MARK: - 动作处理

    private func focusPassword() {
        focus = isPasswordVisible ? .passwordPlain : .passwordSecure
    }

    private func togglePasswordVisibility() {
        let wasPasswordFocused = isPasswordFocused
        isPasswordVisible.toggle()
        if wasPasswordFocused {
            let nextField: Field = isPasswordVisible ? .passwordPlain : .passwordSecure
            Task { @MainActor in
                focus = nextField
            }
        }
    }

    private func syncServerSelectionIfNeeded() {
        let serverChanged = auth.serverTarget != observedServerTarget
        observedServerTarget = auth.serverTarget
        if serverChanged {
            loginUiError = nil
            if let remembered = auth.rememberedEmail {
                email = remembered
            }
            if !auth.isRegistrationAllowed() && isRegisterMode {
                isRegisterMode = false
            }
            refreshServerRegistrationPolicy()
        } else if email.isEmpty, let remembered = auth.rememberedEmail {
            email = remembered
        }
    }

    private func refreshServerRegistrationPolicy() {
        guard !AuthService.uiTestingMock, auth.serverTarget != .local else { return }
        let target = auth.serverTarget
        Task {
            _ = await auth.probeServer(target)
            if !auth.isRegistrationAllowed(for: target), isRegisterMode {
                isRegisterMode = false
            }
        }
    }

    private func submit() {
        emailTouched = true
        guard canSubmit else { return }
        focus = nil
        let cleanEmail = trimmedEmail
        email = cleanEmail
        isWorking = true
        loginUiError = nil
        Task {
            do {
                if isRegisterMode {
                    try await auth.register(email: cleanEmail, password: password)
                } else {
                    try await auth.login(email: cleanEmail, password: password)
                }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch {
                let resolved = (error as? AuthService.AuthError)?.uiError
                    ?? RCUiErrorCodec.fromError(error)
                withAnimation(.easeOut(duration: 0.18)) {
                    loginUiError = resolved
                }
                if resolved.presentation == .modal {
                    RCErrorCenter.shared.present(resolved)
                }
                errorShakeTrigger += 1
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
            isWorking = false
        }
    }
}

private struct RCLoginPrimaryButtonStyle: ButtonStyle {
    var enabled: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .background(
                backgroundColor(pressed: configuration.isPressed),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .scaleEffect(configuration.isPressed && enabled ? 0.985 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }

    private func backgroundColor(pressed: Bool) -> Color {
        guard enabled else { return RCColor.accent.opacity(0.38) }
        return pressed ? RCColor.accentPressed : RCColor.accent
    }
}

private struct RCSurfacePressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.78 : 1.0)
            .scaleEffect(configuration.isPressed ? 0.99 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

#Preview {
    LoginView()
}
