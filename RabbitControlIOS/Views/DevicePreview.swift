import SwiftUI

struct DevicePreview: View {
    let device: Device
    var showsCaption = false
    var body: some View {
        ZStack {
            Rectangle().fill(Color.secondary.opacity(0.12))
            if let image = AuthService.shared.previews[device.id] {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
                    .clipped()
                    .accessibilityLabel("最近会话画面")
            } else {
                VStack(spacing: 8) {
                    RabbitIcon(device.kind.icon, size: 28)
                    if showsCaption { Text("连接后显示最近画面").font(.footnote) }
                }.foregroundStyle(.secondary).accessibilityElement(children: .ignore).accessibilityLabel("暂无设备预览")
            }
        }
    }
}
