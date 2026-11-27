import Network
import SwiftUI
import UIKit

/// 手动连接只接受数字 IP:端口或本账号九位设备码。
enum AssistTarget: Identifiable, Equatable {
    case direct(String), account(String)

    init?(_ input: String) {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = text.replacingOccurrences(of: " ", with: "")
        if digits.count == 9, digits.utf8.allSatisfy({ (48...57).contains($0) }) {
            self = .account(digits)
            return
        }
        guard let separator = text.lastIndex(of: ":"),
              let port = UInt16(text[text.index(after: separator)...]), port > 0 else { return nil }
        let host = String(text[..<separator])
        guard IPv4Address(host) != nil || (host.hasPrefix("[") && host.hasSuffix("]") && IPv6Address(String(host.dropFirst().dropLast())) != nil) else { return nil }
        self = .direct(text)
    }

    var id: String {
        switch self { case .direct(let value), .account(let value): value }
    }
    var address: String? { if case .direct(let addr) = self { addr } else { nil } }

    /// 当用户已输入合法 IP 但尚未填写端口时，返回补全默认端口 9901 后的地址。
    static func portCompletion(for raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, Self(text) == nil else { return nil }
        if text.hasSuffix(":") {
            let host = String(text.dropLast())
            if IPv4Address(host) != nil
                || (host.hasPrefix("[") && host.hasSuffix("]") && IPv6Address(String(host.dropFirst().dropLast())) != nil) {
                return "\(text)9901"
            }
            return nil
        }
        if !text.contains(":"), text.filter({ $0 == "." }).count == 3, IPv4Address(text) != nil {
            return "\(text):9901"
        }
        return nil
    }

    /// 判断输入是否仍处于合法前缀输入过程中（用于避免首字符即报红）。
    static func isTypingProgress(_ raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, Self(text) == nil else { return false }

        let compact = text.replacingOccurrences(of: " ", with: "")
        if compact.utf8.allSatisfy({ (48...57).contains($0) }) {
            return compact.count < 9
        }

        guard !text.contains(" ") else { return false }
        let allowed = CharacterSet(charactersIn: "0123456789abcdefABCDEF.:[]")
        guard text.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }

        if !text.hasPrefix("[") {
            let colons = text.filter { $0 == ":" }.count
            if colons > 1 { return false }
            if let sep = text.lastIndex(of: ":") {
                let host = String(text[..<sep])
                guard IPv4Address(host) != nil else { return false }
                let portSlice = text[text.index(after: sep)...]
                if !portSlice.isEmpty {
                    guard let port = UInt16(portSlice), port > 0 else { return false }
                }
            }
        }
        return true
    }
}

/// 协助页会话是否正在全屏显示;RootView 据此隐藏悬浮底栏。
@Observable
final class AssistFlow {
    static let shared = AssistFlow()
    var sessionActive = false
}

struct AssistView: View {
    var embeddedInTab = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.dynamicTypeSize) private var typeSize
    @FocusState private var focus: Field?

    @State private var input = ""
    @State private var password = ""
    @State private var isPasswordVisible = false
    @State private var targetTouched = false
    @State private var errorShakeTrigger = 0
    @State private var mode: DeviceDetailView.SessionMode = .control
    @State private var target: AssistTarget?
    @State private var standaloneToolTarget: StandaloneAssistTool?

    private struct StandaloneAssistTool: Identifiable, Equatable {
        let target: AssistTarget
        let tool: DeviceDetailView.QuickTool
        var id: String { "\(target.id)-\(tool.rawValue)" }
    }
    @State private var containerWidth: CGFloat = 0
    @State private var history = TargetHistory.shared

    private enum Field: Hashable {
        case target
        case passwordSecure
        case passwordPlain
    }

    private var auth: AuthService { .shared }
    private var runtime: RuntimeService { .shared }
    private var landscape: Bool { verticalSizeClass == .compact && !typeSize.isAccessibilitySize }
    private var isRegularPad: Bool { horizontalSizeClass == .regular }
    private var isPadTwoColumn: Bool {
        isRegularPad && RCLayout.prefersTwoColumnAssist(
            verticalSizeClass: verticalSizeClass,
            containerWidth: containerWidth,
            isAccessibilityType: typeSize.isAccessibilitySize
        )
    }
    private var isTargetFocused: Bool { focus == .target }
    private var isPasswordFocused: Bool { focus == .passwordSecure || focus == .passwordPlain }
    private var trimmedInput: String { input.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var parsed: AssistTarget? { AssistTarget(input) }
    private var canConnect: Bool { parsed != nil && problem == nil }

    private var digitOnlyCount: Int? {
        guard !trimmedInput.isEmpty else { return nil }
        let compact = trimmedInput.replacingOccurrences(of: " ", with: "")
        guard compact.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return compact.count
    }

    private var matchedAccountDevice: AccountDevice? {
        guard case .account(let id) = parsed else { return nil }
        return auth.devices.first { $0.deviceID.replacingOccurrences(of: " ", with: "") == id }
    }

    private var matchedDeviceIsLAN: Bool {
        guard case .account(let id) = parsed else { return false }
        return LANDiscoveryService.shared.directAddr(forDeviceID: id) != nil
    }

    private var problem: String? {
        guard !trimmedInput.isEmpty else { return nil }
        guard let parsed else { return "请输入九位设备 ID，或 IP 地址和端口（1–65535）。" }
        if case .account(let id) = parsed {
            guard auth.isLoggedIn else { return "请先登录账号以经信令连接九位设备 ID，或使用 IP:端口直连。" }
            if let own = runtime.deviceID?.replacingOccurrences(of: " ", with: ""), !own.isEmpty, own == id {
                return "不能远程连接当前本机设备。"
            }
            if let device = auth.devices.first(where: { $0.deviceID.replacingOccurrences(of: " ", with: "") == id }) {
                if device.disabled { return "设备「\(device.displayName)」已被停用，暂时无法连接。" }
                if !device.online { return "设备「\(device.displayName)」当前离线，请确认远端在线后再试。" }
                if !device.allowRemoteControl && !device.allowRemoteAssist {
                    return "设备「\(device.displayName)」未开启远程控制或远程协助权限。"
                }
            }
            // 不在当前账号设备列表中的 9 位码视为跨账号伙伴协助目标，放行经信令请求连接
        }
        return nil
    }

    /// 避免用户输入首字符时立即出现红色报错：合法前缀输入中且未失焦时不标红。
    private var activeErrorMessage: String? {
        guard let problem else { return nil }
        if parsed != nil { return problem }
        if targetTouched || !isTargetFocused || !AssistTarget.isTypingProgress(trimmedInput) {
            return problem
        }
        return nil
    }

    private var portSuggestion: String? {
        AssistTarget.portCompletion(for: trimmedInput)
    }

    var body: some View {
        scrollableAssistContent
            .navigationBarHidden(embeddedInTab)
            .navigationTitle("远程协助")
            .toolbar {
                if !embeddedInTab {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("关闭") { dismiss() }
                            .accessibilityHidden(target != nil)
                            .accessibilityIdentifier("assist.close")
                    }
                }
            }
            .accessibilityHidden(target != nil || standaloneToolTarget != nil)
            .fullScreenCover(item: $target, onDismiss: {
                AssistFlow.shared.sessionActive = false
                password = ""
                isPasswordVisible = false
                SessionService.shared.close()
            }) { target in
                SessionView(
                    device: resolvedSessionDevice(for: target),
                    mode: mode,
                    directAddr: target.address,
                    connectionPassword: password
                )
            }
            .fullScreenCover(item: $standaloneToolTarget, onDismiss: {
                AssistFlow.shared.sessionActive = false
                SessionService.shared.close()
            }) { item in
                StandaloneToolSessionView(
                    device: resolvedSessionDevice(for: item.target),
                    tool: item.tool,
                    directAddr: item.target.address,
                    initialPassword: password
                )
            }
            .onChange(of: target != nil || standaloneToolTarget != nil) {
                AssistFlow.shared.sessionActive = (target != nil || standaloneToolTarget != nil)
            }
    }

    private var scrollableAssistContent: some View {
        let topPad: CGFloat = isRegularPad ? 20 : (embeddedInTab ? (landscape ? 10 : 12) : 8)
        let bottomPad: CGFloat = isRegularPad ? 32 : (embeddedInTab ? (landscape ? 76 : 110) : 32)
        return ScrollView {
            adaptiveLayoutContent
                .padding(.horizontal, isRegularPad ? 24 : 16)
                .padding(.top, topPad)
                .padding(.bottom, bottomPad)
                .frame(maxWidth: .infinity)
                .background {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if focus != nil { focus = nil }
                        }
                }
        }
        .onGeometryChange(for: CGFloat.self) { geo in
            geo.size.width
        } action: { newWidth in
            containerWidth = newWidth
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(RCColor.bgPage)
        .scrollDismissesKeyboard(.interactively)
        .onChange(of: focus) { oldValue, newValue in
            if oldValue == .target, newValue != .target, !trimmedInput.isEmpty {
                withAnimation(.easeOut(duration: 0.16)) {
                    targetTouched = true
                }
            }
        }
        .onChange(of: input) {
            if trimmedInput.isEmpty { targetTouched = false }
        }
        .animation(.snappy(duration: 0.2), value: focus != nil)
    }

    @ViewBuilder
    private var adaptiveLayoutContent: some View {
        if isPadTwoColumn {
            VStack(alignment: .leading, spacing: 20) {
                headerRow
                HStack(alignment: .top, spacing: 20) {
                    connectionConsoleCard
                        .frame(maxWidth: 460)
                    historyAndGuidePanel
                        .frame(maxWidth: 420)
                }
            }
            .frame(maxWidth: 900)
        } else if isRegularPad {
            VStack(alignment: .leading, spacing: 18) {
                headerRow
                connectionConsoleCard
                historyAndGuidePanel
            }
            .frame(maxWidth: 540)
        } else if landscape {
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 14) {
                    headerRow
                    connectionGuideStrip
                }
                .frame(maxWidth: 270, alignment: .leading)

                connectionConsoleCard
                    .frame(maxWidth: 440)
            }
        } else {
            VStack(alignment: .leading, spacing: 16) {
                headerRow
                connectionConsoleCard
                if focus == nil {
                    connectionGuideStrip
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: 480)
        }
    }

    // MARK: - 顶部栏

    private var headerRow: some View {
        HStack(alignment: .center, spacing: 12) {
            Text("远程协助")
                .font(landscape ? .title.bold() : .largeTitle.bold())
                .foregroundStyle(RCColor.textPrimary)
                .accessibilityAddTraits(.isHeader)

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                Circle()
                    .fill(runtime.signalRunning ? RCColor.online : RCColor.warning)
                    .frame(width: 8, height: 8)
                Text(runtime.signalRunning ? "信令在线" : "未连信令")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(RCColor.textSecondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5.5)
            .background(RCColor.bgWindow, in: Capsule())
            .overlay {
                Capsule().strokeBorder(RCColor.popoverStroke, lineWidth: 0.5)
            }
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: - 一体化连接控制台

    private var connectionConsoleCard: some View {
        VStack(alignment: .leading, spacing: landscape ? 14 : 16) {
            targetSection

            RCColor.divider.frame(height: 0.5)

            modeSection

            passwordSection

            connectButton

            if canConnect, mode == .control, let parsed {
                HStack(spacing: 8) {
                    quickAssistToolButton("文件传输", icon: .fileTransfer, id: "assist.tool.files") {
                        focus = nil
                        standaloneToolTarget = StandaloneAssistTool(target: parsed, tool: .files)
                    }
                    quickAssistToolButton("远程终端", icon: .terminal, id: "assist.tool.terminal") {
                        focus = nil
                        standaloneToolTarget = StandaloneAssistTool(target: parsed, tool: .terminal)
                    }
                    quickAssistToolButton("端口映射", icon: .portMap, id: "assist.tool.portmap") {
                        focus = nil
                        standaloneToolTarget = StandaloneAssistTool(target: parsed, tool: .portMapping)
                    }
                }
                .transition(.opacity)
            }
        }
        .padding(landscape ? 16 : 18)
        .background(RCColor.bgWindow, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(RCColor.popoverStroke, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.04), radius: 12, y: 4)
        .keyframeAnimator(initialValue: CGFloat.zero, trigger: errorShakeTrigger) { content, offset in
            content.offset(x: offset)
        } keyframes: { _ in
            CubicKeyframe(-7, duration: 0.05)
            CubicKeyframe(6, duration: 0.05)
            CubicKeyframe(-4, duration: 0.05)
            CubicKeyframe(3, duration: 0.05)
            CubicKeyframe(0, duration: 0.06)
        }
    }

    private var targetSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("连接目标")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(RCColor.textPrimary)

                Spacer()

                targetBadgePill
            }

            HStack(spacing: 10) {
                RabbitIcon(targetLeadingIcon, size: 19)
                    .foregroundStyle(targetIconColor)

                TextField("九位设备 ID 或 IP:端口", text: $input)
                    .keyboardType(.numbersAndPunctuation)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focus, equals: .target)
                    .submitLabel(.go)
                    .onSubmit(handleTargetSubmit)
                    .font(.body.monospacedDigit())
                    .accessibilityIdentifier("assist.partnerID")

                if input.isEmpty {
                    PasteButton(payloadType: String.self) { items in
                        guard let raw = items.first else { return }
                        let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                        let compact = clean.replacingOccurrences(of: " ", with: "")
                        input = (compact.count == 9 && compact.allSatisfy(\.isNumber)) ? Self.display(compact) : clean
                        targetTouched = true
                    }
                    .labelStyle(.titleOnly)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                    .tint(RCColor.accent)
                } else {
                    Button {
                        input = ""
                        targetTouched = false
                    } label: {
                        RabbitIcon(.close, size: 12)
                            .foregroundStyle(RCColor.textSecondary)
                            .frame(width: 26, height: 26)
                            .background(Color.secondary.opacity(0.14), in: Circle())
                            .frame(width: 34, height: 34)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("清除连接目标")
                }
            }
            .padding(.leading, 12)
            .padding(.trailing, input.isEmpty ? 10 : 6)
            .frame(minHeight: landscape ? 46 : 50)
            .background(RCColor.bgPage, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(targetBorderColor, lineWidth: isTargetFocused || activeErrorMessage != nil ? 1.5 : 0.5)
            }

            targetFeedbackView
        }
    }

    @ViewBuilder
    private var targetBadgePill: some View {
        if case .account = parsed {
            let isOwnAccount = matchedAccountDevice != nil
            Text(isOwnAccount ? "账号设备" : "伙伴设备")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(RCColor.accent)
                .padding(.horizontal, 8)
                .padding(.vertical, 2.5)
                .background(RCColor.accent.opacity(0.12), in: Capsule())
        } else if case .direct = parsed {
            Text("IP 直连")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(RCColor.accent)
                .padding(.horizontal, 8)
                .padding(.vertical, 2.5)
                .background(RCColor.accent.opacity(0.12), in: Capsule())
        } else if let count = digitOnlyCount, count < 9 {
            Text("\(count) / 9 位")
                .font(.caption2.monospacedDigit().weight(.medium))
                .foregroundStyle(RCColor.textSecondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(RCColor.bgPage, in: Capsule())
        } else {
            Text("设备码 / IP:端口")
                .font(.caption)
                .foregroundStyle(RCColor.textSecondary)
        }
    }

    @ViewBuilder
    private var targetFeedbackView: some View {
        if let error = activeErrorMessage {
            HStack(alignment: .top, spacing: 6) {
                RabbitIcon(.warning, size: 14)
                    .foregroundStyle(RCColor.danger)
                    .padding(.top, 1)
                Text(error)
                    .font(.caption)
                    .foregroundStyle(RCColor.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .transition(.opacity)
        } else if let accountDevice = matchedAccountDevice {
            HStack(spacing: 8) {
                Circle()
                    .fill(RCColor.online)
                    .frame(width: 7, height: 7)
                Text(accountDevice.displayName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(RCColor.textPrimary)
                    .lineLimit(1)
                Text("· \(Self.display(accountDevice.deviceID.replacingOccurrences(of: " ", with: "")))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(RCColor.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if matchedDeviceIsLAN {
                    Text("LAN 加速")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(RCColor.online)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(RCColor.online.opacity(0.14), in: Capsule())
                } else {
                    Text("在线可连")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(RCColor.online)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RCColor.online.opacity(0.08), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(RCColor.online.opacity(0.22), lineWidth: 0.5)
            }
            .transition(.opacity)
        } else if case .account(let id) = parsed {
            HStack(spacing: 6) {
                RabbitIcon(.remoteAssist, size: 13)
                    .foregroundStyle(RCColor.accent)
                Text("伙伴 ID \(Self.display(id)) · 经信令发起协助（需验证码或对方同意）")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(RCColor.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .transition(.opacity)
        } else if case .direct(let addr) = parsed {
            HStack(spacing: 6) {
                RabbitIcon(.checkmark, size: 13)
                    .foregroundStyle(RCColor.online)
                Text("直连地址已就绪 · \(addr)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(RCColor.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .transition(.opacity)
        } else if let suggested = portSuggestion {
            HStack(spacing: 8) {
                Text("还需输入端口号（1–65535）")
                    .font(.caption)
                    .foregroundStyle(RCColor.textSecondary)
                Spacer(minLength: 4)
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    input = suggested
                } label: {
                    Text("补全 :9901")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(RCColor.accent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3.5)
                        .background(RCColor.accent.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .transition(.opacity)
        } else {
            Text("示例：604 928 235 或 192.168.1.10:9901")
                .font(.caption.monospacedDigit())
                .foregroundStyle(RCColor.textSecondary)
        }
    }

    private var targetLeadingIcon: RabbitIcon.Name {
        if let accountDevice = matchedAccountDevice {
            return Device.Kind(osString: accountDevice.os).icon
        }
        if trimmedInput.contains(":") || trimmedInput.contains(".") || trimmedInput.hasPrefix("[") {
            return .server
        }
        return .computer
    }

    private var targetIconColor: Color {
        if activeErrorMessage != nil { return RCColor.danger }
        if canConnect || isTargetFocused { return RCColor.accent }
        return RCColor.textSecondary
    }

    private var targetBorderColor: Color {
        if activeErrorMessage != nil { return RCColor.danger.opacity(0.75) }
        if isTargetFocused { return RCColor.accent }
        if canConnect { return RCColor.accent.opacity(0.35) }
        return RCColor.stroke.opacity(0.35)
    }

    // MARK: - 会话模式与连接密码

    private var modeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("会话模式")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(RCColor.textPrimary)

            HStack(spacing: 6) {
                modeOptionButton(
                    .control,
                    title: "远程控制",
                    subtitle: "键鼠操控与工具",
                    icon: .cursor,
                    id: "assist.mode.control"
                )
                modeOptionButton(
                    .watch,
                    title: "仅查看",
                    subtitle: "只读观看不操作",
                    icon: .eye,
                    id: "assist.mode.watch"
                )
            }
            .padding(4)
            .background(RCColor.bgPage, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private func modeOptionButton(_ option: DeviceDetailView.SessionMode, title: String, subtitle: String,
                                  icon: RabbitIcon.Name, id: String) -> some View {
        let selected = mode == option
        return Button {
            guard mode != option else { return }
            UISelectionFeedbackGenerator().selectionChanged()
            withAnimation(.snappy(duration: 0.2)) {
                mode = option
            }
        } label: {
            HStack(spacing: 8) {
                RabbitIcon(icon, size: 17)
                    .foregroundStyle(selected ? RCColor.accent : RCColor.textSecondary)
                    .frame(width: 30, height: 30)
                    .background(
                        selected ? RCColor.accent.opacity(0.12) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )

                VStack(alignment: .leading, spacing: 1.5) {
                    Text(title)
                        .font(.subheadline.weight(selected ? .semibold : .medium))
                        .foregroundStyle(selected ? RCColor.textPrimary : RCColor.textSecondary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(RCColor.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(
                selected ? RCColor.bgWindow : Color.clear,
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(RCColor.accent.opacity(0.28), lineWidth: 1)
                }
            }
            .shadow(color: .black.opacity(selected ? 0.04 : 0), radius: 4, y: 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(id)
    }

    private var passwordSection: some View {
        HStack(spacing: 10) {
            RabbitIcon(.lock, size: 18)
                .foregroundStyle(isPasswordFocused ? RCColor.accent : RCColor.textSecondary)

            ZStack {
                SecureField("远端连接密码（无密码留空）", text: $password)
                    .textContentType(.password)
                    .focused($focus, equals: .passwordSecure)
                    .submitLabel(.go)
                    .onSubmit(connect)
                    .opacity(isPasswordVisible ? 0 : 1)
                    .allowsHitTesting(!isPasswordVisible)
                    .accessibilityHidden(isPasswordVisible)
                    .accessibilityIdentifier("assist.password")

                TextField("远端连接密码（无密码留空）", text: $password)
                    .textContentType(.password)
                    .focused($focus, equals: .passwordPlain)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .onSubmit(connect)
                    .opacity(isPasswordVisible ? 1 : 0)
                    .allowsHitTesting(isPasswordVisible)
                    .accessibilityHidden(!isPasswordVisible)
                    .accessibilityIdentifier("assist.password")
            }

            Button {
                togglePasswordVisibility()
            } label: {
                RabbitIcon(isPasswordVisible ? .eyeOff : .eye, size: 18)
                    .foregroundStyle(isPasswordVisible ? RCColor.accent : RCColor.textSecondary)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isPasswordVisible ? "隐藏密码" : "显示密码")
            .accessibilityIdentifier("assist.togglePassword")
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .frame(minHeight: landscape ? 44 : 48)
        .background(RCColor.bgPage, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    isPasswordFocused ? RCColor.accent : RCColor.stroke.opacity(0.35),
                    lineWidth: isPasswordFocused ? 1.5 : 0.5
                )
        }
    }

    private var connectButton: some View {
        Button(action: connect) {
            HStack(spacing: 8) {
                RabbitIcon(mode == .watch ? .eye : .cursor, size: 18)
                Text(mode == .watch ? "查看设备屏幕" : "开始远控")
                    .font(.headline)
            }
            .frame(maxWidth: .infinity, minHeight: landscape ? 46 : 50)
        }
        .buttonStyle(RCAssistPrimaryButtonStyle(enabled: canConnect))
        .disabled(!canConnect)
        .accessibilityIdentifier("assist.connect")
    }

    // MARK: - iPad 右栏：收藏/最近连接历史与直连指南

    private var orderedHistoryTargets: [String] {
        let favs = history.favorites
        let rest = history.recent.filter { !favs.contains($0) }
        return favs + rest
    }

    private var historyAndGuidePanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("收藏与最近连接")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(RCColor.textPrimary)
                    Spacer()
                    if !orderedHistoryTargets.isEmpty {
                        Text("\(orderedHistoryTargets.count)")
                            .font(.caption2.monospacedDigit().weight(.semibold))
                            .foregroundStyle(RCColor.textSecondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(RCColor.bgPage, in: Capsule())
                    }
                }

                if orderedHistoryTargets.isEmpty {
                    VStack(spacing: 6) {
                        RabbitIcon(.star, size: 24)
                            .foregroundStyle(RCColor.textDisabled)
                        Text("暂无最近连接记录")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(RCColor.textSecondary)
                        Text("成功建立远控会话后会自动保存在此，点选即可一键回填目标。")
                            .font(.caption2)
                            .foregroundStyle(RCColor.textDisabled)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                    .background(RCColor.bgPage, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                } else {
                    VStack(spacing: 6) {
                        ForEach(orderedHistoryTargets.prefix(8), id: \.self) { item in
                            historyRow(item)
                        }
                    }
                }
            }
            .padding(18)
            .background(RCColor.bgWindow, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(RCColor.popoverStroke, lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.03), radius: 10, y: 3)

            connectionGuideStrip
        }
    }

    private func historyRow(_ rawTarget: String) -> some View {
        let cleanDigits = rawTarget.replacingOccurrences(of: " ", with: "")
        let isNineDigits = cleanDigits.count == 9 && cleanDigits.allSatisfy(\.isNumber)
        let formattedDisplay = isNineDigits ? Self.display(cleanDigits) : rawTarget
        let matched = isNineDigits
            ? auth.devices.first(where: { $0.deviceID.replacingOccurrences(of: " ", with: "") == cleanDigits })
            : nil
        let isFav = history.isFavorite(rawTarget)
        let isSelected = trimmedInput.replacingOccurrences(of: " ", with: "") == cleanDigits

        return HStack(spacing: 10) {
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                input = formattedDisplay
                targetTouched = true
                focus = nil
            } label: {
                HStack(spacing: 10) {
                    RabbitIcon(
                        matched.map { Device.Kind(osString: $0.os).icon } ?? (isNineDigits ? .computer : .server),
                        size: 17
                    )
                    .foregroundStyle(isSelected ? RCColor.accent : RCColor.textSecondary)
                    .frame(width: 30, height: 30)
                    .background(
                        isSelected ? RCColor.accent.opacity(0.14) : RCColor.bgWindow,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(matched?.displayName ?? formattedDisplay)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(RCColor.textPrimary)
                                .lineLimit(1)
                            if let matched {
                                Circle()
                                    .fill(matched.online ? RCColor.online : RCColor.textDisabled)
                                    .frame(width: 6, height: 6)
                            }
                        }

                        HStack(spacing: 5) {
                            if matched != nil {
                                Text(formattedDisplay)
                                    .font(.caption2.monospacedDigit())
                            } else {
                                Text(isNineDigits ? "九位设备码" : "IP 直连")
                                    .font(.caption2)
                            }
                            if let recency = history.lastConnectedText(rawTarget) {
                                Text("· \(recency)")
                                    .font(.caption2)
                            }
                        }
                        .foregroundStyle(RCColor.textSecondary)
                        .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                UISelectionFeedbackGenerator().selectionChanged()
                history.toggleFavorite(rawTarget)
            } label: {
                RabbitIcon(isFav ? .starFilled : .star, size: 15)
                    .foregroundStyle(isFav ? RCColor.warning : RCColor.textDisabled)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isFav ? "取消收藏 \(formattedDisplay)" : "收藏 \(formattedDisplay)")

            Button {
                if isFav { history.toggleFavorite(rawTarget) }
                history.removeRecent(rawTarget)
            } label: {
                RabbitIcon(.close, size: 11)
                    .foregroundStyle(RCColor.textDisabled)
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("移除记录 \(formattedDisplay)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            isSelected ? RCColor.bgToolTile : RCColor.bgPage,
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isSelected ? RCColor.accent.opacity(0.45) : RCColor.popoverStroke, lineWidth: isSelected ? 1 : 0.5)
        }
    }

    // MARK: - 底部连接说明（去卡片化轻量提示）

    private var connectionGuideStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            guideRow(
                icon: .computer,
                title: "九位设备 ID",
                detail: "连接当前账号下已开启远程协助的在线设备，同局域网自动启用 LAN 加速。"
            )
            guideRow(
                icon: .server,
                title: "IP:端口直连",
                detail: "通过局域网或公网地址直接建立会话，不依赖账号信令状态。"
            )
        }
        .padding(.horizontal, 4)
        .padding(.top, 2)
    }

    private func guideRow(icon: RabbitIcon.Name, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            RabbitIcon(icon, size: 14)
                .foregroundStyle(RCColor.textSecondary)
                .padding(.top, 2)
            Text("\(Text(title).fontWeight(.medium).foregroundStyle(RCColor.textPrimary))  \(detail)")
                .font(.caption)
                .foregroundStyle(RCColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func quickAssistToolButton(_ title: String, icon: RabbitIcon.Name, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                RabbitIcon(icon, size: 14)
                Text(title)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
            }
            .foregroundStyle(RCColor.accent)
            .frame(maxWidth: .infinity, minHeight: 34)
            .background(RCColor.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    // MARK: - 动作与辅助

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

    private func handleTargetSubmit() {
        if canConnect {
            connect()
        } else if !trimmedInput.isEmpty {
            withAnimation(.easeOut(duration: 0.16)) {
                targetTouched = true
            }
            errorShakeTrigger += 1
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }

    private func connect() {
        guard let parsed, problem == nil else { return }
        focus = nil
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        target = parsed
    }

    private func resolvedSessionDevice(for target: AssistTarget) -> Device {
        if case .account(let id) = target,
           let account = auth.devices.first(where: { $0.deviceID.replacingOccurrences(of: " ", with: "") == id }) {
            let isLAN = LANDiscoveryService.shared.directAddr(forDeviceID: id) != nil
            return Device(
                id: account.deviceID,
                name: account.displayName,
                kind: Device.Kind(osString: account.os),
                online: account.online,
                isLocal: isLAN,
                wallpaper: Device.Wallpaper(hashSeed: account.deviceID)
            )
        }
        return Device(
            id: target.id,
            name: target.id,
            kind: .mac,
            online: true,
            isLocal: false,
            wallpaper: .coast
        )
    }

    /// 九位码按 3-3-3 分组显示,直连地址原样。
    static func display(_ item: String) -> String {
        guard item.count == 9, item.allSatisfy(\.isNumber) else { return item }
        let chars = Array(item)
        return "\(String(chars[0..<3])) \(String(chars[3..<6])) \(String(chars[6..<9]))"
    }
}

private struct RCAssistPrimaryButtonStyle: ButtonStyle {
    var enabled: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(enabled ? Color.white : RCColor.textSecondary.opacity(0.65))
            .background(
                backgroundColor(pressed: configuration.isPressed),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay {
                if !enabled {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(RCColor.stroke.opacity(0.28), lineWidth: 0.5)
                }
            }
            .scaleEffect(configuration.isPressed && enabled ? 0.985 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }

    private func backgroundColor(pressed: Bool) -> Color {
        guard enabled else { return RCColor.bgPage }
        return pressed ? RCColor.accentPressed : RCColor.accent
    }
}

