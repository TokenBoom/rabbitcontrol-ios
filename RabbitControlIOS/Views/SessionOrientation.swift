import SwiftUI
import UIKit

/// 会话期间的方向锁定:iOS 16+ 通过 windowScene 几何更新请求实现,退出会话时恢复。
enum SessionOrientationLock {
    static func apply(_ preference: SessionOrientation) {
        let mask: UIInterfaceOrientationMask
        switch preference {
        case .auto: mask = .allButUpsideDown
        case .landscape: mask = .landscape
        case .portrait: mask = .portrait
        }
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) ?? UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask))
    }

    static func restore() {
        apply(.auto)
    }
}

/// 首次进入会话时的手势教程浮层:分步展示核心手势,看完不再出现。
struct SessionGestureGuide: View {
    var onFinish: () -> Void
    @State private var step = 0

    private let pages: [(RabbitIcon.Name, String, String)] = [
        (.cursor, "移动与点击", "直触模式点哪点哪；触控板模式单指滑动移动指针，轻点左键。"),
        (.mouse, "右键与滚动", "长按或双指轻点出右键菜单；双指上下左右滑动即滚轮，松手带惯性。"),
        (.keyboard, "拖动与输入", "轻点后再次触按可拖动窗口/框选；底部键盘条可发功能键和打字。"),
        (.watchScreen, "缩放与布局", "双指捏合放大画面细看；控制中枢里可锁定横屏或切换竖屏分屏触控板。"),
    ]

    var body: some View {
        ZStack {
            Color.black.opacity(0.72).ignoresSafeArea()
            VStack(spacing: 22) {
                let page = pages[step]
                RabbitIcon(page.0, size: 52).foregroundStyle(RCColor.accent)
                Text(page.1).font(.title2.bold()).foregroundStyle(.white)
                Text(page.2).font(.body).foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center).frame(maxWidth: 320)
                HStack(spacing: 8) {
                    ForEach(pages.indices, id: \.self) { idx in
                        Circle().fill(idx == step ? Color.white : Color.white.opacity(0.3)).frame(width: 7, height: 7)
                    }
                }
                HStack(spacing: 14) {
                    if step < pages.count - 1 {
                        Button("跳过") { onFinish() }.foregroundStyle(.white.opacity(0.7))
                        Button {
                            withAnimation { step += 1 }
                        } label: {
                            Text("下一步").font(.headline).foregroundStyle(.white)
                                .padding(.horizontal, 30).padding(.vertical, 12)
                                .background(RCColor.accent, in: Capsule())
                        }
                    } else {
                        Button {
                            onFinish()
                        } label: {
                            Text("开始控制").font(.headline).foregroundStyle(.white)
                                .padding(.horizontal, 30).padding(.vertical, 12)
                                .background(RCColor.accent, in: Capsule())
                        }.accessibilityIdentifier("guide.finish")
                    }
                }
            }.padding(32)
        }
    }
}
