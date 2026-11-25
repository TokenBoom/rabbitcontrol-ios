import SwiftUI

struct RootView: View {
    enum Tab { case devices, assist, profile }
    @State private var assistFlow = AssistFlow.shared
    @State private var inputPrefs = InteractionPrefs.shared
    @State private var selection: Tab = .devices
    private var auth: AuthService { .shared }

    var body: some View {
        Group {
            if auth.isLoggedIn { home } else { LoginView() }
        }
        .preferredColorScheme(inputPrefs.themeMode.colorScheme)
        .overlay { ToastOverlay(center: .shared).allowsHitTesting(false).animation(.easeInOut(duration: 0.2), value: ToastCenter.shared.message) }
        .onChange(of: auth.isLoggedIn) {
            if !auth.isLoggedIn { selection = .devices }
        }
    }

    /// 登录后的主页;未登录时与 Android 一致,只显示登录/注册。
    private var home: some View {
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
