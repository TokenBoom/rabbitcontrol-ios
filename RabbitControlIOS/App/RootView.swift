import SwiftUI

/// 应用根视图。接入 `rabbitcontrol-core` 之前先显示占位内容。
struct RootView: View {
    var body: some View {
        VStack(spacing: 8) {
            Text("RabbitControl")
                .font(.largeTitle.weight(.bold))
                .accessibilityIdentifier("root.title")
            Text("iOS 客户端")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
