import SwiftUI

/// 全局界面状态:推入二级页面时隐藏悬浮 tab 条,避免遮挡内容。
@Observable
final class AppChrome {
    static let shared = AppChrome()
    var tabBarHidden = false
}

/// 应用根视图:三个主 tab(我的设备 / 远程协助 / 我的) + 底部悬浮胶囊 tab 条。
struct RootView: View {
    enum Tab: Int {
        case devices
        case assist
        case profile
    }

    @State private var selection: Tab = .devices

    var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                switch selection {
                case .devices:
                    NavigationStack {
                        DeviceListView()
                    }
                case .assist:
                    NavigationStack {
                        AssistView()
                    }
                case .profile:
                    NavigationStack {
                        ProfileView()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if !AppChrome.shared.tabBarHidden {
                FloatingTabBar(selection: $selection)
                    .padding(.horizontal, 48)
                    .padding(.bottom, 20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            ToastOverlay(center: ToastCenter.shared)
        }
        .animation(.easeInOut(duration: 0.15), value: ToastCenter.shared.message)
        .animation(.easeInOut(duration: 0.2), value: AppChrome.shared.tabBarHidden)
    }
}

/// 底部悬浮胶囊 tab 条(移动端适配,iOS 原生 SF Symbols 对应设计规范 §3.5 的 Lucide 图标语义)。
struct FloatingTabBar: View {
    @Binding var selection: RootView.Tab

    var body: some View {
        HStack(spacing: 0) {
            tabItem(.devices, title: "我的设备", systemImage: "laptopcomputer.and.iphone")
            tabItem(.assist, title: "远程协助", systemImage: "rectangle.2.swap")
            tabItem(.profile, title: "我的", systemImage: "person")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay {
            Capsule().strokeBorder(RCColor.stroke, lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
    }

    private func tabItem(_ tab: RootView.Tab, title: String, systemImage: String) -> some View {
        let selected = selection == tab
        return Button {
            selection = tab
        } label: {
            VStack(spacing: 2) {
                Image(systemName: systemImage)
                    .font(.system(size: 20))
                Text(title)
                    .font(.system(size: 12))
            }
            .foregroundStyle(selected ? RCColor.accent : RCColor.textSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .padding(.horizontal, 4)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 999)
                        .fill(RCColor.accent.opacity(0.12))
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("tab.\(title)")
    }
}
