import SwiftUI

struct RootView: View {
    enum Tab: Hashable { case devices, assist, profile }
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    @State private var assistFlow = AssistFlow.shared
    @State private var inputPrefs = InteractionPrefs.shared
    @State private var lockStore = AppLockStore.shared
    @State private var selection: Tab = .devices
    private var auth: AuthService { .shared }

    var body: some View {
        Group {
            if !auth.isLoggedIn {
                LoginView()
            } else if auth.requiresPasswordChange {
                ForceChangePasswordView()
            } else {
                home
            }
        }
        .preferredColorScheme(inputPrefs.themeMode.colorScheme)
        .allowsHitTesting(!lockStore.isLocked)
        .accessibilityHidden(lockStore.isLocked)
        .overlay {
            if lockStore.isLocked {
                AppLockOverlayView()
                    .transition(.opacity)
            }
        }
        .overlay { RCErrorRootOverlay(center: .shared) }
        .overlay { ToastOverlay(center: .shared).allowsHitTesting(false).animation(.easeInOut(duration: 0.2), value: ToastCenter.shared.message) }
        .onAppear {
            if SessionOrientationLock.isPad {
                SessionOrientationLock.restore()
            }
        }
        .onChange(of: auth.isLoggedIn) {
            if !auth.isLoggedIn { selection = .devices }
        }
        .onChange(of: scenePhase) { _, newPhase in
            lockStore.handleScenePhase(newPhase)
        }
    }

    /// 登录后的主页：`compact` 保持单栏 + 底部标签栏，`regular`（iPad 宽屏）切换至侧边栏工作台。
    @ViewBuilder
    private var home: some View {
        if RCLayout.usesWorkspaceSplit(horizontalSizeClass) {
            IPadWorkspaceView(selection: $selection)
        } else {
            phoneHome
        }
    }

    private var phoneHome: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Group {
                    switch selection {
                    case .devices: DeviceListView()
                    case .assist: AssistView(embeddedInTab: true)
                    case .profile: ProfileView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                if auth.isLoggedIn, !AssistFlow.shared.sessionActive {
                    VStack(spacing: 0) {
                        RCColor.divider.frame(height: 0.5)
                        HStack(spacing: 0) {
                            homeAction("我的设备", id: "我的设备", icon: .devices, selected: selection == .devices) { selection = .devices }
                            homeAction("远程协助", id: "远程协助", icon: .remoteAssist, selected: selection == .assist) { selection = .assist }
                            homeAction("我的", id: "我的", icon: .person, selected: selection == .profile) { selection = .profile }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 49)
                    }
                    .frame(maxWidth: .infinity)
                    .background {
                        Rectangle()
                            .fill(.regularMaterial)
                            .ignoresSafeArea(edges: .bottom)
                    }
                }
            }
            .background(RCColor.bgPage.ignoresSafeArea())
        }
    }

    private func homeAction(_ title: String, id: String, icon: RabbitIcon.Name, selected: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                RabbitIcon(icon, size: 22)
                    .frame(width: 42, height: 26)
                    .background(selected ? RCColor.accent.opacity(0.12) : .clear, in: Capsule())
                Text(title).font(.system(size: 11, weight: selected ? .semibold : .regular))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .foregroundStyle(selected ? RCColor.accent : RCColor.textSecondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(id)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("tab.\(id)")
    }
}
