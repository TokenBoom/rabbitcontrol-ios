import SwiftUI
import UIKit

/// 会话与全局方向锁定:iPad 全程固定横屏,iPhone 在会话期间按偏好锁定并在退出时恢复。
@MainActor
enum SessionOrientationLock {
    static var isPad: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
    }

    nonisolated static func resolvedMask(
        for preference: SessionOrientation,
        isPad: Bool
    ) -> UIInterfaceOrientationMask {
        if isPad {
            return .landscape
        }
        switch preference {
        case .auto: return .allButUpsideDown
        case .landscape: return .landscape
        case .portrait: return .portrait
        }
    }

    static var defaultMask: UIInterfaceOrientationMask {
        isPad ? .landscape : .allButUpsideDown
    }

    private(set) static var currentMask: UIInterfaceOrientationMask =
        UIDevice.current.userInterfaceIdiom == .pad ? .landscape : .allButUpsideDown
    private static var requestToken = 0

    static func apply(_ preference: SessionOrientation) {
        let mask = resolvedMask(for: preference, isPad: isPad)
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
        let mask = defaultMask
        currentMask = mask
        requestToken += 1
        applyMaskToActiveScene(mask)
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
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask), errorHandler: nil)
    }
}

/// 首次进入会话时的手势教程浮层:支持左右滑动与分步点按切换,竖屏与横屏自适应卡片布局。
struct SessionGestureGuide: View {
    var onFinish: () -> Void
    @State private var step = 0
    @Environment(\.horizontalSizeClass) private var horizontalClass
    @Environment(\.verticalSizeClass) private var verticalClass

    private let pages: [(RabbitIcon.Name, String, String, String)] = [
        (.cursor, "移动与点击", "直触模式点哪点哪，双击自动防抖精准选中；触控板模式单指滑动驱动本地精准光标，轻点即左键。", "顶部胶囊可一键切换「直触 / 触控板」"),
        (.mouse, "长按拖拽与右键", "按住后滑动即可左键拖拽窗口与选区；长按震动后原地松手或双指轻点唤出右键，双指滑动即惯性滚轮。", "右侧悬浮鼠标条支持左/中/右键与拖拽锁"),
        (.keyboard, "二次触按拖拽与修饰键", "轻点后立即二次触按滑动或三指滑动同样可拖拽；修饰键单击配合下一次键鼠生效，双击常驻自锁。", "支持 ⌘/⌃/⇧ 配合桌面点选及中文拼音输入"),
        (
            .watchScreen,
            "画面缩放与工具面板",
            "双指捏合最高 8× 放大细看，放大后单指快速滑动可平移视野，顶部倍率按钮一键还原 1:1。",
            UIDevice.current.userInterfaceIdiom == .pad
                ? "右侧控制面板可并排打开终端与文件工具"
                : "竖屏可切换下方专属触控板与按住左键栏"
        ),
    ]

    var body: some View {
        let page = pages[step]
        let isLandscape = verticalClass == .compact || horizontalClass == .regular
        ZStack {
            Color.black.opacity(0.74)
                .ignoresSafeArea()
                .onTapGesture {}

            Group {
                if isLandscape {
                    HStack(spacing: 24) {
                        iconBadge(page.0, size: 36, frame: 68)
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(page.1).font(.title3.bold()).foregroundStyle(.white)
                                Spacer()
                                stepCounter
                            }
                            Text(page.2)
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.86))
                                .fixedSize(horizontal: false, vertical: true)
                            tipTag(page.3)
                            HStack(spacing: 12) {
                                dots
                                Spacer()
                                actionButtons
                            }
                            .padding(.top, 4)
                        }
                    }
                    .frame(maxWidth: 500)
                } else {
                    VStack(spacing: 16) {
                        HStack {
                            Spacer()
                            stepCounter
                        }
                        iconBadge(page.0, size: 40, frame: 76)
                        Text(page.1).font(.title3.bold()).foregroundStyle(.white)
                        Text(page.2)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.86))
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                        tipTag(page.3)
                        dots.padding(.top, 2)
                        actionButtons.padding(.top, 4)
                    }
                    .frame(maxWidth: 340)
                }
            }
            .padding(24)
            .background(RCColor.hudBg, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(.white.opacity(0.14), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.4), radius: 24, y: 10)
            .padding(.horizontal, 24)
            .gesture(
                DragGesture(minimumDistance: 24)
                    .onEnded { value in
                        if value.translation.width < -30, step < pages.count - 1 {
                            withAnimation(.easeOut(duration: 0.2)) { step += 1 }
                        } else if value.translation.width > 30, step > 0 {
                            withAnimation(.easeOut(duration: 0.2)) { step -= 1 }
                        }
                    }
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("session.gestureGuide")
    }

    private var stepCounter: some View {
        Text("\(step + 1) / \(pages.count)")
            .font(.caption.monospacedDigit().weight(.semibold))
            .foregroundStyle(.white.opacity(0.55))
    }

    private func iconBadge(_ icon: RabbitIcon.Name, size: CGFloat, frame: CGFloat) -> some View {
        RabbitIcon(icon, size: size)
            .foregroundStyle(RCColor.accent)
            .frame(width: frame, height: frame)
            .background(RCColor.accent.opacity(0.18), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(RCColor.accent.opacity(0.35), lineWidth: 1)
            }
    }

    private func tipTag(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(Color(hex: 0x8AB4FF))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(RCColor.accent.opacity(0.16), in: Capsule())
    }

    private var dots: some View {
        HStack(spacing: 7) {
            ForEach(pages.indices, id: \.self) { idx in
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { step = idx }
                } label: {
                    Capsule()
                        .fill(idx == step ? RCColor.accent : Color.white.opacity(0.28))
                        .frame(width: idx == step ? 18 : 7, height: 7)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("第 \(idx + 1) 步")
            }
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 12) {
            if step < pages.count - 1 {
                Button("跳过") { onFinish() }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.72))
                    .padding(.horizontal, 10)
                    .frame(minHeight: 38)
            }
            if step > 0 {
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { step -= 1 }
                } label: {
                    Text("上一步")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 38)
                        .background(Color.white.opacity(0.12), in: Capsule())
                }
            }
            if step < pages.count - 1 {
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { step += 1 }
                } label: {
                    Text("下一步")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 22)
                        .frame(minHeight: 38)
                        .background(RCColor.accent, in: Capsule())
                }
            } else {
                Button {
                    onFinish()
                } label: {
                    Text("开始控制")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 24)
                        .frame(minHeight: 38)
                        .background(RCColor.accent, in: Capsule())
                }
                .accessibilityIdentifier("guide.finish")
            }
        }
    }
}
