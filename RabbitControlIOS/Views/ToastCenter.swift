import SwiftUI

/// 全局 Toast:HUD 半透明黑底白字,底部居中,自动消失,新消息顶替旧消息(设计规范 §4 Toast)。
/// 同时支持纯文本提示与带严重级别圆点的 `RCUiError` 轻提示。
@Observable
final class ToastCenter {
    static let shared = ToastCenter()

    private(set) var message: String?
    private(set) var severity: RCErrorSeverity?
    private var generation = 0

    func show(_ message: String, severity: RCErrorSeverity? = nil, durationSeconds: Double = 1.8) {
        generation += 1
        let current = generation
        self.message = message
        self.severity = severity
        Task {
            try? await Task.sleep(for: .seconds(durationSeconds))
            guard generation == current else { return }
            self.message = nil
            self.severity = nil
        }
    }

    func show(_ error: RCUiError) {
        let msg = error.message.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = error.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let primary = msg.isEmpty ? title : msg
        let suggestion = error.suggestion.trimmingCharacters(in: .whitespacesAndNewlines)
        let combined: String
        if !suggestion.isEmpty, primary != suggestion, primary.count + suggestion.count <= 46 {
            combined = "\(primary) · \(suggestion)"
        } else {
            combined = primary
        }
        show(combined, severity: error.severity, durationSeconds: 2.6)
    }
}

/// 挂在根视图上的 Toast 浮层。
struct ToastOverlay: View {
    var center: ToastCenter

    private var indicatorColor: Color? {
        switch center.severity {
        case .info: RCColor.accent
        case .warning: RCColor.warning
        case .error, .critical: RCColor.danger
        case nil: nil
        }
    }

    var body: some View {
        if let message = center.message {
            HStack(spacing: 8) {
                if let indicatorColor {
                    Circle()
                        .fill(indicatorColor)
                        .frame(width: 7, height: 7)
                }
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .frame(minHeight: 36)
            .background(RCColor.hudBg, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, 120)
            .transition(.opacity)
            .accessibilityIdentifier("toast")
        }
    }
}
