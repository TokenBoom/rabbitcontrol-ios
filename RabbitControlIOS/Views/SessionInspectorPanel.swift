import SwiftUI
import UIKit

/// iPad 宽屏远控会话右侧并排抽屉：支持不遮挡远端桌面画面，同屏切换「会话控制 / 终端 / 文件传输 / 端口映射 / 远程键盘」。
struct SessionInspectorPanel: View {
    enum InspectorTab: String, CaseIterable, Identifiable {
        case hub
        case terminal
        case files
        case portMapping
        case keyboard

        var id: String { rawValue }

        var title: String {
            switch self {
            case .hub: "控制"
            case .terminal: "终端"
            case .files: "文件"
            case .portMapping: "端口"
            case .keyboard: "键盘"
            }
        }

        var icon: RabbitIcon.Name {
            switch self {
            case .hub: .settings
            case .terminal: .terminal
            case .files: .fileTransfer
            case .portMapping: .portMap
            case .keyboard: .keyboard
            }
        }

        init(quickTool: DeviceDetailView.QuickTool?) {
            switch quickTool {
            case .terminal: self = .terminal
            case .files: self = .files
            case .portMapping: self = .portMapping
            case .hub, nil: self = .hub
            }
        }
    }

    var session: SessionService
    var device: Device
    var watchOnly: Bool
    @Binding var showMouseTools: Bool
    var initialTool: DeviceDetailView.QuickTool?
    var onSwitchConnectionMode: ((ConnectionMode) -> Void)? = nil
    var onReplayGuide: (() -> Void)?
    var onClosePanel: () -> Void
    var onExitSession: () -> Void

    @State private var selectedTab: InspectorTab = .hub
    @State private var confirmExit = false

    private var effectiveWatchOnly: Bool { watchOnly || session.effectiveWatchOnly }

    var body: some View {
        VStack(spacing: 0) {
            inspectorHeader

            if !effectiveWatchOnly {
                inspectorTabStrip
                RCColor.divider.frame(height: 0.5)
            }

            Group {
                if effectiveWatchOnly || selectedTab == .hub {
                    SessionControlHub(
                        session: session,
                        device: device,
                        watchOnly: watchOnly,
                        showMouseTools: $showMouseTools,
                        initialTool: nil,
                        embeddedInInspector: true,
                        onSelectInspectorTool: { tool in
                            withAnimation(.snappy(duration: 0.18)) {
                                selectedTab = InspectorTab(quickTool: tool)
                            }
                        },
                        onSelectKeyboardInspector: {
                            withAnimation(.snappy(duration: 0.18)) {
                                selectedTab = .keyboard
                            }
                        },
                        onSwitchConnectionMode: onSwitchConnectionMode,
                        onReplayGuide: onReplayGuide,
                        onExit: onExitSession
                    )
                } else {
                    NavigationStack {
                        Group {
                            switch selectedTab {
                            case .terminal:
                                if session.toolPermissions.allowTerminal {
                                    TerminalView()
                                        .modifier(ConnectedTool(session: session))
                                } else {
                                    forbiddenToolPlaceholder(title: "远程终端已禁用")
                                }
                            case .files:
                                if session.toolPermissions.allowFileTransfer {
                                    FileTransferView(device: device)
                                        .modifier(ConnectedTool(session: session))
                                } else {
                                    forbiddenToolPlaceholder(title: "文件传输已禁用")
                                }
                            case .portMapping:
                                if session.toolPermissions.allowPortMap {
                                    PortMappingView(device: device)
                                        .modifier(ConnectedTool(session: session))
                                } else {
                                    forbiddenToolPlaceholder(title: "端口映射已禁用")
                                }
                            case .keyboard:
                                RemoteKeyboard(session: session, deviceKind: device.kind)
                                    .modifier(ConnectedTool(session: session))
                            case .hub:
                                EmptyView()
                            }
                        }
                        .toolbar(.hidden, for: .navigationBar)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(RCColor.bgPage)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color.white.opacity(0.12))
                .frame(width: 0.5)
        }
        .confirmationDialog("结束本次远程协助？", isPresented: $confirmExit, titleVisibility: .visible) {
            Button("结束会话", role: .destructive, action: onExitSession)
            Button("取消", role: .cancel) {}
        }
        .onAppear {
            if !watchOnly, let sid = session.sessionID, session.isConnected {
                ToolService.shared.start(sessionID: sid)
            }
            if !watchOnly {
                selectedTab = InspectorTab(quickTool: initialTool)
            }
        }
        .onChange(of: initialTool) { _, newTool in
            if !watchOnly, let newTool {
                selectedTab = InspectorTab(quickTool: newTool)
            }
        }
    }

    private var inspectorHeader: some View {
        HStack(spacing: 10) {
            Button("结束", role: .destructive) {
                confirmExit = true
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(RCColor.danger)
            .accessibilityLabel("结束远程协助")

            Spacer()

            Text(effectiveWatchOnly ? "观看设置" : headerTitle)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(RCColor.textPrimary)

            Spacer()

            Button("完成") {
                onClosePanel()
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(RCColor.accent)
            .accessibilityIdentifier("inspector.close")
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
        .background(RCColor.bgWindow)
        .overlay(alignment: .bottom) {
            RCColor.divider.frame(height: 0.5)
        }
    }

    private var headerTitle: String {
        switch selectedTab {
        case .hub: "会话控制"
        case .terminal: "远程终端"
        case .files: "文件传输"
        case .portMapping: "端口映射"
        case .keyboard: "远程键盘"
        }
    }

    private var inspectorTabStrip: some View {
        HStack(spacing: 4) {
            ForEach(InspectorTab.allCases) { tab in
                let active = selectedTab == tab
                Button {
                    guard selectedTab != tab else { return }
                    UISelectionFeedbackGenerator().selectionChanged()
                    withAnimation(.snappy(duration: 0.18)) {
                        selectedTab = tab
                    }
                } label: {
                    VStack(spacing: 3) {
                        RabbitIcon(tab.icon, size: 15)
                        Text(tab.title)
                            .font(.system(size: 11, weight: active ? .semibold : .medium))
                            .lineLimit(1)
                    }
                    .foregroundStyle(active ? RCColor.accent : RCColor.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(
                        active ? RCColor.accent.opacity(0.12) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("inspector.tab.\(tab.rawValue)")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RCColor.bgWindow)
    }

    private func forbiddenToolPlaceholder(title: String) -> some View {
        VStack(spacing: 12) {
            RCInlineErrorView(error: CoreClient.resolveUiError(code: RCErrorCodes.toolForbidden))
                .padding(.horizontal, 16)
            Text(title)
                .font(.caption)
                .foregroundStyle(RCColor.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RCColor.bgPage)
    }
}
