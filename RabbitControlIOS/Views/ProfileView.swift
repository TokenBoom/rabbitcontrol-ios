import SwiftUI
import UIKit

struct ProfileView: View {
    @State private var showChangePassword = false
    @State private var showServerConfig = false
    @State private var showAboutSheet = false
    @State private var showLogoutConfirm = false
    @State private var showThemeDialog = false
    @State private var input = InteractionPrefs.shared
    @State private var lockStore = AppLockStore.shared
    private var auth: AuthService { .shared }
    private var runtime: RuntimeService { .shared }

    private var serverSummary: String {
        let host = auth.serverTarget.host.isEmpty ? "未配置" : auth.serverTarget.host
        return auth.savedServers.count > 1 ? "\(host) (\(auth.savedServers.count))" : host
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("我的")
                    .font(.largeTitle.bold())
                    .padding(.top, 8)

                accountCard

                cardGroup {
                    rowButton(icon: .server, title: "服务器管理", trailing: serverSummary) {
                        showServerConfig = true
                    }
                    .accessibilityIdentifier("profile.服务器设置")

                    Divider().padding(.leading, 44)

                    NavigationLink {
                        ProxySettingsView()
                    } label: {
                        rowContent(icon: .portMap, title: "网络代理", trailing: ProxyConfigStore.shared.config.summaryText)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("profile.网络代理")

                    Divider().padding(.leading, 44)

                    NavigationLink {
                        SettingsView()
                    } label: {
                        rowContent(icon: .settings, title: "远控默认设置", trailing: input.touchMode.label)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("profile.设置")

                    Divider().padding(.leading, 44)

                    NavigationLink {
                        AppLockSettingsView()
                    } label: {
                        rowContent(icon: .lock, title: "本地应用锁", trailing: lockStore.isEnabled ? "已启用" : "未启用")
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("profile.应用锁")

                    Divider().padding(.leading, 44)

                    rowButton(icon: .display, title: "外观主题", trailing: input.themeMode.label) {
                        showThemeDialog = true
                    }
                    .accessibilityIdentifier("profile.外观主题")
                }

                cardGroup {
                    if auth.isLoggedIn {
                        rowButton(icon: .security, title: "修改密码") {
                            showChangePassword = true
                        }
                        .accessibilityIdentifier("profile.修改密码")

                        Divider().padding(.leading, 44)
                    }

                    rowButton(
                        icon: .devices,
                        title: "关于与版本诊断",
                        trailing: "v\(appVersion) · Core \(CoreClient.coreVersion)"
                    ) {
                        showAboutSheet = true
                    }
                    .accessibilityIdentifier("profile.关于")
                }

                if auth.isLoggedIn {
                    Button(role: .destructive) {
                        showLogoutConfirm = true
                    } label: {
                        Text("退出登录")
                            .font(.body.weight(.medium))
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, minHeight: 50)
                            .background(RCColor.bgWindow, in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("profile.退出登录")
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(RCColor.bgPage)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showChangePassword) { ChangePasswordSheet() }
        .sheet(isPresented: $showServerConfig) { ServerConfigSheet() }
        .sheet(isPresented: $showAboutSheet) { AboutDiagnosticsSheet(appVersion: appVersion) }
        .confirmationDialog("外观主题", isPresented: $showThemeDialog, titleVisibility: .visible) {
            Button(AppThemeMode.system == input.themeMode ? "跟随系统（当前）" : "跟随系统") { input.themeMode = .system }
            Button(AppThemeMode.light == input.themeMode ? "浅色（当前）" : "浅色") { input.themeMode = .light }
            Button(AppThemeMode.dark == input.themeMode ? "深色（当前）" : "深色") { input.themeMode = .dark }
            Button("取消", role: .cancel) {}
        }
        .confirmationDialog("退出当前账号？", isPresented: $showLogoutConfirm, titleVisibility: .visible) {
            Button("退出登录", role: .destructive) { auth.logout() }
            Button("取消", role: .cancel) {}
        } message: { Text("将断开当前会话并清除本机账号信息，不会解绑设备。") }
    }

    private var accountCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                RabbitIcon(.person, size: 24)
                    .foregroundStyle(RCColor.accent)
                    .frame(width: 48, height: 48)
                    .background(RCColor.accent.opacity(0.12), in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text(auth.session?.displayName.nonEmpty ?? "RabbitControl 账户")
                        .font(.headline)
                        .foregroundStyle(RCColor.textPrimary)
                    Text(auth.session?.email ?? "未登录")
                        .font(.subheadline)
                        .foregroundStyle(RCColor.textSecondary)
                        .accessibilityIdentifier("profile.phone")
                }
                Spacer()
            }

            if auth.isLoggedIn {
                Divider()
                HStack(spacing: 8) {
                    Circle()
                        .fill(runtime.signalRunning ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                    Text(signalStatusText)
                        .font(.caption)
                        .foregroundStyle(RCColor.textSecondary)
                        .lineLimit(1)
                    Spacer()
                    if let ownID = runtime.deviceID, !ownID.isEmpty {
                        Button {
                            UIPasteboard.general.string = ownID
                            ToastCenter.shared.show("已复制本机码")
                        } label: {
                            HStack(spacing: 4) {
                                Text(AssistView.display(ownID.replacingOccurrences(of: " ", with: "")))
                                    .font(.caption.monospaced())
                                RabbitIcon(.clipboard, size: 13)
                            }
                            .foregroundStyle(RCColor.textSecondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(16)
        .background(RCColor.bgWindow, in: RoundedRectangle(cornerRadius: 12))
    }

    private var signalStatusText: String {
        if runtime.signalRunning { return "信令在线" }
        if let err = runtime.lastError, !err.isEmpty { return "信令异常：\(err)" }
        return "信令连接中…"
    }

    private func cardGroup<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            content()
        }
        .background(RCColor.bgWindow, in: RoundedRectangle(cornerRadius: 12))
    }

    private func rowButton(icon: RabbitIcon.Name, title: String, trailing: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            rowContent(icon: icon, title: title, trailing: trailing)
        }
        .buttonStyle(.plain)
    }

    private func rowContent(icon: RabbitIcon.Name, title: String, trailing: String? = nil) -> some View {
        HStack(spacing: 12) {
            RabbitIcon(icon, size: 20)
                .foregroundStyle(RCColor.accent)
                .frame(width: 24)
            Text(title)
                .foregroundStyle(RCColor.textPrimary)
            Spacer()
            if let trailing, !trailing.isEmpty {
                Text(trailing)
                    .font(.subheadline)
                    .foregroundStyle(RCColor.textSecondary)
                    .lineLimit(1)
            }
            RabbitIcon(.chevronRight, size: 14)
                .foregroundStyle(RCColor.textSecondary.opacity(0.6))
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 50)
        .contentShape(Rectangle())
    }
}

/// 版本与构建协议诊断弹层（对齐基线 §9.3 & §12.5 `CoreBuildInfo` 四端一致性核对）。
struct AboutDiagnosticsSheet: View {
    var appVersion: String
    var embeddedInSplit = false
    @Environment(\.dismiss) private var dismiss

    private let buildInfo = CoreClient.buildInfo

    private var diagnosticReportText: String {
        var lines: [String] = [
            "RabbitControl iOS v\(appVersion)",
            "Core Version: \(buildInfo?.coreVersion ?? CoreClient.coreVersion)",
        ]
        if let info = buildInfo {
            lines.append("Git Commit: \(info.gitCommit)")
            lines.append("Build Timestamp: \(info.buildTimestamp)")
            lines.append("ABI Version: \(info.abiVersion)")
            lines.append("Session Protocol: v\(info.sessionProtocolVersion)")
            lines.append("Punch Protocol: v\(info.punchVersion)")
            lines.append("Beacon Protocol: v\(info.beaconVersion)")
        }
        let target = AuthService.shared.serverTarget
        lines.append("Server: \(target.host) (API :\(target.effectiveAPIPort), Signal :\(target.effectiveSignalPort), Relay :\(target.effectiveRelayPort), HTTPS=\(target.useHTTPS))")
        lines.append("Connection Mode: \(PrefsStore.shared.connectionMode.rawValue)")
        lines.append("Proxy: \(ProxyConfigStore.shared.config.summaryText)")
        lines.append("AV1 HW Decode: \(VideoCodec.isHardwareAV1DecodeSupported)")
        return lines.joined(separator: "\n")
    }

    var body: some View {
        if embeddedInSplit {
            diagnosticsList
        } else {
            NavigationStack {
                diagnosticsList
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("完成") { dismiss() }
                        }
                    }
            }
        }
    }

    private var diagnosticsList: some View {
        List {
                Section("客户端与核心引擎") {
                    LabeledContent("iOS 应用版本", value: "v\(appVersion)")
                    LabeledContent("核心库版本 (Core)", value: buildInfo?.coreVersion ?? CoreClient.coreVersion)
                        .font(.body.monospacedDigit())
                    if let info = buildInfo {
                        LabeledContent("核心 Git Commit", value: info.gitCommit)
                            .font(.subheadline.monospaced())
                        LabeledContent("核心构建时间", value: info.buildTimestamp)
                            .font(.caption.monospacedDigit())
                    }
                }

                if let info = buildInfo {
                    Section("跨端协议与 ABI 契约") {
                        LabeledContent("FFI ABI 版本", value: "v\(info.abiVersion)")
                            .font(.body.monospacedDigit())
                        LabeledContent("会话协议版本 (Session)", value: "v\(info.sessionProtocolVersion)")
                            .font(.body.monospacedDigit())
                        LabeledContent("打洞协议版本 (Punch)", value: "v\(info.punchVersion)")
                            .font(.body.monospacedDigit())
                        LabeledContent("局域网信标版本 (Beacon)", value: "v\(info.beaconVersion)")
                            .font(.body.monospacedDigit())
                    }
                }

                Section("硬件媒体与网络能力") {
                    LabeledContent("VideoToolbox H.265 硬解", value: "支持")
                    LabeledContent("VideoToolbox AV1 硬解", value: VideoCodec.isHardwareAV1DecodeSupported ? "支持" : "当前机型不支持（自动降级）")
                    LabeledContent("默认路由模式", value: PrefsStore.shared.connectionMode.shortLabel)
                    LabeledContent("出站网络代理", value: ProxyConfigStore.shared.config.summaryText)
                }

                Section {
                    Button {
                        UIPasteboard.general.string = diagnosticReportText
                        ToastCenter.shared.show("已复制完整诊断信息")
                    } label: {
                        HStack {
                            Spacer()
                            Label("复制完整诊断报告", rabbitIcon: .clipboard)
                                .fontWeight(.semibold)
                            Spacer()
                        }
                    }
                    .accessibilityIdentifier("about.copyDiagnostics")
                }
            }
        .navigationTitle("关于与版本诊断")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
