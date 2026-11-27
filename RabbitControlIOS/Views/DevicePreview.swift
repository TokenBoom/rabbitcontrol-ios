import SwiftUI
import UIKit

struct DevicePreview: View {
    let device: Device
    var showsCaption = false
    /// 详情页大图模式：保留完整远端桌面比例不裁切边缘，非 16:10 画幅以同源模糊背景承托。
    var fitsFullDesktop = false
    var overrideImage: UIImage? = nil

    private var resolvedImage: UIImage? {
        overrideImage ?? AuthService.shared.previews[device.id]
    }

    var body: some View {
        Rectangle()
            .fill(fitsFullDesktop && resolvedImage != nil ? Color.black.opacity(0.88) : Color.secondary.opacity(0.12))
            .overlay {
                if let image = resolvedImage {
                    if fitsFullDesktop {
                        Image(uiImage: image)
                            .resizable()
                            .interpolation(.medium)
                            .scaledToFill()
                            .blur(radius: 20)
                            .overlay(Color.black.opacity(0.28))
                    } else {
                        Image(uiImage: image)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFill()
                            .accessibilityLabel("最近会话画面")
                    }
                } else {
                    VStack(spacing: 8) {
                        RabbitIcon(device.kind.icon, size: 28)
                        if showsCaption {
                            Text("连接后显示最近画面")
                                .font(.footnote)
                        }
                    }
                    .foregroundStyle(.secondary)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("暂无设备预览")
                }
            }
            .overlay {
                if let image = resolvedImage, fitsFullDesktop {
                    Image(uiImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .accessibilityLabel("最近会话画面")
                }
            }
            .clipped()
    }
}
