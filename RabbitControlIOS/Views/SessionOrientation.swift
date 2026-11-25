import SwiftUI
import UIKit

/// 会话期间的方向锁定:通过 AppDelegate 支持方向掩码 + windowScene 几何更新共同生效,退出会话时恢复。
@MainActor
enum SessionOrientationLock {
    private(set) static var currentMask: UIInterfaceOrientationMask = .allButUpsideDown
    private static var requestToken = 0

    static func apply(_ preference: SessionOrientation) {
        let mask: UIInterfaceOrientationMask
        switch preference {
        case .auto: mask = .allButUpsideDown
        case .landscape: mask = .landscape
        case .portrait: mask = .portrait
        }
        currentMask = mask
        requestToken += 1
        let token = requestToken
        applyMaskToActiveScene(mask)
        // fullScreenCover 转场动画期间系统可能忽略首次请求,转场落地后再补触发一次。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            guard requestToken == token, currentMask == mask else { return }
            applyMaskToActiveScene(mask)
        }
    }

    static func restore() {
        currentMask = .allButUpsideDown
        requestToken += 1
        applyMaskToActiveScene(.allButUpsideDown)
    }

    private static func applyMaskToActiveScene(_ mask: UIInterfaceOrientationMask) {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
            ?? UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
        for window in scene.windows {
            var vc = window.rootViewController
            while let current = vc {
                current.setNeedsUpdateOfSupportedInterfaceOrientations()
                vc = current.presentedViewController
            }
        }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
    }
}

/// 首次进入会话时的手势教程浮层:分步展示核心手势,竖屏与横屏分别采用紧凑布局。
struct SessionGestureGuide: View {
    var onFinish: () -> Void
    @State private var step = 0
    @Environment(\.verticalSizeClass) private var verticalClass

    private let pages: [(RabbitIcon.Name, String, String)] = [
        (.cursor, "移动与点击", "直触模式点哪点哪；触控板模式单指滑动移动指针，轻点左键。"),
        (.mouse, "右键与滚动", "长按或双指轻点出右键菜单；双指上下左右滑动即滚轮，松手带惯性。"),
        (.keyboard, "拖动与输入", "轻点后再次触按可拖动窗口/框选；底部键盘条可发功能键和打字。"),
        (.watchScreen, "缩放与布局", "双指捏合放大画面细看；控制中枢里可锁定横屏或切换竖屏分屏触控板。"),
    ]

    var body: some View {
        let page = pages[step]
        let isLandscape = verticalClass == .compact
        ZStack {
            Color.black.opacity(0.76).ignoresSafeArea()
            if isLandscape {
                HStack(spacing: 28) {
                    RabbitIcon(page.0, size: 48).foregroundStyle(RCColor.accent)
                        .frame(width: 72, height: 72)
                        .background(RCColor.accent.opacity(0.16), in: Circle())
                    VStack(alignment: .leading, spacing: 12) {
                        Text(page.1).font(.title3.bold()).foregroundStyle(.white)
                        Text(page.2).font(.subheadline).foregroundStyle(.white.opacity(0.85))
                            .frame(maxWidth: 360, alignment: .leading)
                        HStack(spacing: 14) {
                            dots
                            Spacer()
                            actionButtons
                        }
                    }
                }
                .padding(24)
                .background(RCColor.hudBg, in: RoundedRectangle(cornerRadius: 20))
                .padding(.horizontal, 40)
            } else {
                VStack(spacing: 22) {
                    RabbitIcon(page.0, size: 52).foregroundStyle(RCColor.accent)
                    Text(page.1).font(.title2.bold()).foregroundStyle(.white)
                    Text(page.2).font(.body).foregroundStyle(.white.opacity(0.85))
                        .multilineTextAlignment(.center).frame(maxWidth: 320)
                    dots
                    actionButtons
                }.padding(32)
            }
        }
    }

    private var dots: some View {
        HStack(spacing: 8) {
            ForEach(pages.indices, id: \.self) { idx in
                Circle().fill(idx == step ? Color.white : Color.white.opacity(0.3)).frame(width: 7, height: 7)
            }
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 14) {
            if step < pages.count - 1 {
                Button("跳过") { onFinish() }.foregroundStyle(.white.opacity(0.7))
                Button {
                    withAnimation { step += 1 }
                } label: {
                    Text("下一步").font(.headline).foregroundStyle(.white)
                        .padding(.horizontal, 26).padding(.vertical, 10)
                        .background(RCColor.accent, in: Capsule())
                }
            } else {
                Button {
                    onFinish()
                } label: {
                    Text("开始控制").font(.headline).foregroundStyle(.white)
                        .padding(.horizontal, 26).padding(.vertical, 10)
                        .background(RCColor.accent, in: Capsule())
                }.accessibilityIdentifier("guide.finish")
            }
        }
    }
}
