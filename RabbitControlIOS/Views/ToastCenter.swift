import SwiftUI

/// 全局 Toast:HUD 半透明黑底白字,底部居中,1.8s 自动消失,新消息顶替旧消息(设计规范 §4 Toast)。
@Observable
final class ToastCenter {
    static let shared = ToastCenter()

    private(set) var message: String?
    private var generation = 0

    func show(_ message: String) {
        generation += 1
        let current = generation
        self.message = message
        Task {
            try? await Task.sleep(for: .seconds(1.8))
            guard generation == current else { return }
            self.message = nil
        }
    }
}

/// 挂在根视图上的 Toast 浮层。
struct ToastOverlay: View {
    var center: ToastCenter

    var body: some View {
        if let message = center.message {
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .frame(height: 36)
                .background(RCColor.hudBg, in: RoundedRectangle(cornerRadius: 8))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 120)
                .transition(.opacity)
                .accessibilityIdentifier("toast")
        }
    }
}
