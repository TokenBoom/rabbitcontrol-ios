import SwiftUI

struct RootView: View {
    enum Tab { case devices, profile }
    @State private var selection: Tab = .devices
    @State private var showAssist = false
    private var auth: AuthService { .shared }

    var body: some View {
        Group {
            if auth.isLoggedIn { home } else { LoginView() }
        }
        .overlay { ToastOverlay(center: .shared).allowsHitTesting(false).animation(.easeInOut(duration: 0.2), value: ToastCenter.shared.message) }
        .onChange(of: auth.isLoggedIn) {
            if !auth.isLoggedIn { showAssist = false; selection = .devices }
        }
    }

    /// 登录后的主页;未登录时与 Android 一致,只显示登录/注册。
    private var home: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Group {
                    switch selection {
                    case .devices: DeviceListView { showAssist = true }
                    case .profile: ProfileView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                if !showAssist {
                    HStack(spacing: 0) {
                        homeAction("我的设备", icon: .devices, selected: selection == .devices) { selection = .devices }
                        homeAction("我的", icon: .person, selected: selection == .profile) { selection = .profile }
                    }
                    .padding(6)
                    .background(.regularMaterial, in: Capsule())
                    .frame(maxWidth: 520)
                    .padding(.horizontal, 24)
                }
            }
            .background(RCColor.bgPage.ignoresSafeArea())
        }
        .accessibilityHidden(showAssist)
        .fullScreenCover(isPresented: $showAssist) { NavigationStack { AssistView() } }
    }

    private func homeAction(_ title: String, icon: RabbitIcon.Name, selected: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                RabbitIcon(icon, size: 22)
                Text(title).font(.caption)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .foregroundStyle(selected ? RCColor.accent : RCColor.textPrimary)
            .background(selected ? RCColor.accent.opacity(0.12) : .clear, in: Capsule())
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("tab.\(title)")
    }
}
