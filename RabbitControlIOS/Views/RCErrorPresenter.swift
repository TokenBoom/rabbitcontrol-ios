import SwiftUI
import UIKit

/// `RCErrorAction` 在 iOS 端的标准按钮文案。
extension RCErrorAction {
    var buttonTitle: String? {
        switch self {
        case .none: nil
        case .retry: "重试"
        case .relogin: "重新登录"
        case .changePassword: "修改密码"
        case .openSettings: "打开设置"
        case .openPermissions: "前往权限设置"
        case .contactAdmin: "复制详情"
        }
    }
}

/// 统一四级结构化错误调度中心（`inline` / `toast` / `banner` / `modal`）。
@Observable
final class RCErrorCenter {
    static let shared = RCErrorCenter()

    struct PresentedItem: Identifiable, Equatable {
        let id = UUID()
        let error: RCUiError
        fileprivate let handlerID: UUID?

        static func == (lhs: PresentedItem, rhs: PresentedItem) -> Bool {
            lhs.id == rhs.id && lhs.error == rhs.error
        }
    }

    private(set) var banner: PresentedItem?
    private(set) var modal: PresentedItem?
    var showChangePasswordSheet = false
    var showServerSettingsSheet = false

    private var actionHandlers: [UUID: (RCErrorAction) -> Bool] = [:]

    private init() {}

    /// 按 `error.presentation`（或调用方显式覆盖级别）分发结构化错误。
    /// `onAction` 返回 `true` 表示已由业务页自行消费该动作；返回 `false` 时走全局默认动作处理。
    func present(
        _ error: RCUiError,
        override presentationOverride: RCErrorPresentation? = nil,
        onAction: ((RCErrorAction) -> Bool)? = nil
    ) {
        let level = presentationOverride ?? error.presentation
        switch level {
        case .toast:
            ToastCenter.shared.show(error)
        case .banner, .inline:
            let hid = registerHandler(onAction)
            withAnimation(.snappy(duration: 0.22)) {
                banner = PresentedItem(error: error, handlerID: hid)
            }
        case .modal:
            // 基线 §8.3：弹出阻塞模态框期间立即释放并暂停远程键鼠输入防穿透
            SessionService.shared.releasePressedInput()
            let hid = registerHandler(onAction)
            withAnimation(.easeOut(duration: 0.18)) {
                modal = PresentedItem(error: error, handlerID: hid)
            }
        }
    }

    func dismissBanner(id: UUID? = nil) {
        guard id == nil || banner?.id == id else { return }
        if let hid = banner?.handlerID { actionHandlers.removeValue(forKey: hid) }
        withAnimation(.easeOut(duration: 0.18)) {
            banner = nil
        }
    }

    func dismissModal(id: UUID? = nil) {
        guard id == nil || modal?.id == id else { return }
        if let hid = modal?.handlerID { actionHandlers.removeValue(forKey: hid) }
        withAnimation(.easeOut(duration: 0.16)) {
            modal = nil
        }
    }

    func triggerAction(for item: PresentedItem, isModal: Bool) {
        let action = item.error.action
        let hid = item.handlerID
        if isModal { dismissModal(id: item.id) } else { dismissBanner(id: item.id) }
        if let hid, let custom = actionHandlers.removeValue(forKey: hid), custom(action) {
            return
        }
        performDefaultAction(action, for: item.error)
    }

    func performDefaultAction(_ action: RCErrorAction, for error: RCUiError) {
        switch action {
        case .none, .retry:
            break
        case .relogin:
            AuthService.shared.logout()
        case .changePassword:
            if AuthService.shared.isLoggedIn {
                showChangePasswordSheet = true
            }
        case .openSettings:
            showServerSettingsSheet = true
        case .openPermissions:
            if error.code.hasPrefix("platform.ios."),
               let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        case .contactAdmin:
            let summary = "[\(error.code)] \(error.message)"
            UIPasteboard.general.string = summary
            ToastCenter.shared.show("已复制错误码与说明")
        }
    }

    private func registerHandler(_ handler: ((RCErrorAction) -> Bool)?) -> UUID? {
        guard let handler else { return nil }
        let id = UUID()
        actionHandlers[id] = handler
        return id
    }
}

// MARK: - 严重级别视觉配色

private struct RCSeverityStyle {
    let tint: Color
    let background: Color
    let border: Color
    let icon: RabbitIcon.Name

    static func resolve(_ severity: RCErrorSeverity, onDarkStage: Bool = false) -> RCSeverityStyle {
        switch severity {
        case .info:
            return RCSeverityStyle(
                tint: RCColor.accent,
                background: RCColor.accent.opacity(onDarkStage ? 0.18 : 0.10),
                border: RCColor.accent.opacity(onDarkStage ? 0.36 : 0.24),
                icon: .devices
            )
        case .warning:
            return RCSeverityStyle(
                tint: RCColor.warning,
                background: RCColor.warning.opacity(onDarkStage ? 0.18 : 0.10),
                border: RCColor.warning.opacity(onDarkStage ? 0.36 : 0.26),
                icon: .warning
            )
        case .error, .critical:
            return RCSeverityStyle(
                tint: RCColor.danger,
                background: RCColor.danger.opacity(onDarkStage ? 0.20 : 0.10),
                border: RCColor.danger.opacity(onDarkStage ? 0.38 : 0.24),
                icon: .warning
            )
        }
    }
}

// MARK: - Level 1: Inline 内联错误视图

struct RCInlineErrorView: View {
    var error: RCUiError
    var onDarkStage = false
    var actionLabelOverride: String? = nil
    var onAction: ((RCErrorAction) -> Void)? = nil
    var onDismiss: (() -> Void)? = nil

    @State private var showDiagnostics = false

    private var style: RCSeverityStyle { .resolve(error.severity, onDarkStage: onDarkStage) }
    private var primaryTextColor: Color { onDarkStage ? .white : RCColor.textPrimary }
    private var secondaryTextColor: Color { onDarkStage ? .white.opacity(0.72) : RCColor.textSecondary }

    private var actionTitle: String? {
        if let actionLabelOverride, !actionLabelOverride.isEmpty { return actionLabelOverride }
        return error.action.buttonTitle
    }

    private var hasDiagnostics: Bool {
        let d = error.detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (!d.isEmpty && d != error.message) || error.status != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                RabbitIcon(style.icon, size: 16)
                    .foregroundStyle(style.tint)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 3) {
                    if !error.title.isEmpty && error.title != error.message {
                        Text(error.title)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(primaryTextColor)
                    }
                    Text(error.message.isEmpty ? error.title : error.message)
                        .font(.footnote)
                        .foregroundStyle(onDarkStage ? .white.opacity(0.92) : style.tint)
                        .fixedSize(horizontal: false, vertical: true)

                    let suggestion = error.suggestion.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !suggestion.isEmpty && suggestion != error.message {
                        Text(suggestion)
                            .font(.caption)
                            .foregroundStyle(secondaryTextColor)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if let onDismiss {
                    Button(action: onDismiss) {
                        RabbitIcon(.close, size: 12)
                            .foregroundStyle(secondaryTextColor)
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("关闭错误提示")
                }
            }

            if (actionTitle != nil && onAction != nil) || hasDiagnostics {
                HStack(spacing: 8) {
                    if hasDiagnostics {
                        Button {
                            withAnimation(.easeOut(duration: 0.15)) { showDiagnostics.toggle() }
                        } label: {
                            Text(showDiagnostics ? "收起详情" : "错误码 \(error.code)")
                                .font(.caption2.monospaced())
                                .foregroundStyle(secondaryTextColor)
                        }
                        .buttonStyle(.plain)
                    }

                    Spacer(minLength: 0)

                    if let actionTitle, let onAction {
                        Button {
                            onAction(error.action)
                        } label: {
                            Text(actionTitle)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(onDarkStage ? .white : RCColor.accent)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(
                                    (onDarkStage ? Color.white : RCColor.accent).opacity(0.14),
                                    in: Capsule()
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("error.inline.action")
                    }
                }
            }

            if showDiagnostics {
                VStack(alignment: .leading, spacing: 2) {
                    Text("代码：\(error.code)\(error.status.map { " (HTTP \($0))" } ?? "")")
                    if let detail = error.detail, !detail.isEmpty {
                        Text("详情：\(detail)")
                            .textSelection(.enabled)
                    }
                }
                .font(.caption2.monospaced())
                .foregroundStyle(secondaryTextColor)
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(style.background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(style.border, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("error.inline")
    }
}

// MARK: - Level 3 & 4: Banner 横幅与 Modal 模态弹窗根浮层

struct RCErrorRootOverlay: View {
    var center: RCErrorCenter

    var body: some View {
        ZStack {
            if let bannerItem = center.banner {
                RCBannerErrorCard(
                    item: bannerItem,
                    onAction: { center.triggerAction(for: bannerItem, isModal: false) },
                    onDismiss: { center.dismissBanner(id: bannerItem.id) }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.horizontal, 14)
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            if let modalItem = center.modal {
                RCModalErrorDialog(
                    item: modalItem,
                    onAction: { center.triggerAction(for: modalItem, isModal: true) },
                    onDismiss: { center.dismissModal(id: modalItem.id) }
                )
                .transition(.scale(scale: 0.96).combined(with: .opacity))
            }
        }
        .sheet(isPresented: Bindable(center).showChangePasswordSheet) {
            ChangePasswordSheet()
        }
        .sheet(isPresented: Bindable(center).showServerSettingsSheet) {
            ServerConfigSheet()
        }
    }
}

private struct RCBannerErrorCard: View {
    var item: RCErrorCenter.PresentedItem
    var onAction: () -> Void
    var onDismiss: () -> Void

    private var error: RCUiError { item.error }
    private var style: RCSeverityStyle { .resolve(error.severity) }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RabbitIcon(style.icon, size: 18)
                .foregroundStyle(style.tint)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                Text(error.title.isEmpty ? "提示" : error.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(RCColor.textPrimary)
                if !error.message.isEmpty && error.message != error.title {
                    Text(error.message)
                        .font(.caption)
                        .foregroundStyle(RCColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                let suggestion = error.suggestion.trimmingCharacters(in: .whitespacesAndNewlines)
                if !suggestion.isEmpty && suggestion != error.message {
                    Text(suggestion)
                        .font(.caption2)
                        .foregroundStyle(RCColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let actionLabel = error.action.buttonTitle {
                    Button(actionLabel, action: onAction)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(RCColor.accent)
                        .padding(.top, 2)
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("error.banner.action")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onDismiss) {
                RabbitIcon(.close, size: 13)
                    .foregroundStyle(RCColor.textSecondary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭横幅提示")
            .accessibilityIdentifier("error.banner.close")
        }
        .padding(14)
        .frame(maxWidth: 460)
        .background(RCColor.bgWindow, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(style.border, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.12), radius: 16, y: 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("error.banner")
    }
}

private struct RCModalErrorDialog: View {
    var item: RCErrorCenter.PresentedItem
    var onAction: () -> Void
    var onDismiss: () -> Void

    @State private var showDetail = false
    private var error: RCUiError { item.error }
    private var style: RCSeverityStyle { .resolve(error.severity) }

    var body: some View {
        ZStack {
            RCColor.modalMask
                .ignoresSafeArea()
                .onTapGesture {
                    if error.severity != .critical { onDismiss() }
                }

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    RabbitIcon(style.icon, size: 20)
                        .foregroundStyle(style.tint)
                        .frame(width: 36, height: 36)
                        .background(style.background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(error.title.isEmpty ? "操作受阻" : error.title)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(RCColor.textPrimary)
                        Text(error.code)
                            .font(.caption2.monospaced())
                            .foregroundStyle(RCColor.textSecondary)
                    }
                    Spacer()
                }

                Text(error.message.isEmpty ? error.title : error.message)
                    .font(.subheadline)
                    .foregroundStyle(RCColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                let suggestion = error.suggestion.trimmingCharacters(in: .whitespacesAndNewlines)
                if !suggestion.isEmpty {
                    Text(suggestion)
                        .font(.footnote)
                        .foregroundStyle(RCColor.textSecondary)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RCColor.bgPage, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }

                if let detail = error.detail, !detail.isEmpty, detail != error.message {
                    DisclosureGroup(isExpanded: $showDetail) {
                        Text(detail)
                            .font(.caption2.monospaced())
                            .foregroundStyle(RCColor.textSecondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 4)
                    } label: {
                        Text("诊断详情")
                            .font(.caption)
                            .foregroundStyle(RCColor.textSecondary)
                    }
                }

                HStack(spacing: 10) {
                    Spacer()
                    Button("关闭", action: onDismiss)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(RCColor.textPrimary)
                        .padding(.horizontal, 14)
                        .frame(height: 36)
                        .background(RCColor.bgPage, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(RCColor.stroke, lineWidth: 0.5)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("error.modal.close")

                    if let actionTitle = error.action.buttonTitle {
                        Button(actionTitle, action: onAction)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .frame(height: 36)
                            .background(RCColor.accent, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("error.modal.action")
                    }
                }
                .padding(.top, 4)
            }
            .padding(22)
            .frame(maxWidth: 360)
            .background(RCColor.bgWindow, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(RCColor.popoverStroke, lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.15), radius: 32, y: 12)
            .padding(.horizontal, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityIdentifier("error.modal")
    }
}
