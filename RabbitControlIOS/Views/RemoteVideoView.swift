import SwiftUI

/// 远端画面视图:Metal 视图驱动取帧,触控层负责手势与归一化输入映射。
struct RemoteVideoView: View {
    var session: SessionService
    var watchOnly: Bool
    var showMouseTools: Bool
    var zoomPan: ZoomPanState
    var inputEnabled = true
    var previewDeviceID: String?

    @State private var showCaptureHint = false
    @Environment(\.scenePhase) private var phase

    var body: some View {
        GeometryReader { geo in
            ZStack {
                RCColor.stageBg
                MetalVideoView(zoomPan: zoomPan, previewDeviceID: previewDeviceID)
                if inputEnabled {
                    TouchInputView(session: session, zoomPan: zoomPan, watchOnly: watchOnly)
                }
                if !zoomPan.hasPresentedFrame {
                    VStack(spacing: 10) {
                        ProgressView().tint(.white)
                        Text("已连接，等待桌面画面…").font(.headline)
                        if showCaptureHint {
                            Text("长时间没有画面？请在 Mac 上检查屏幕录制权限。").font(.footnote)
                        }
                    }.foregroundStyle(.white).multilineTextAlignment(.center).padding()
                        .allowsHitTesting(false)
                        .task {
                            try? await Task.sleep(for: .seconds(8))
                            if !Task.isCancelled { showCaptureHint = true }
                        }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .overlay(alignment: .trailing) {
                if !watchOnly && showMouseTools {
                    VStack(spacing: 8) {
                        Button { session.sendWheel(delta: 3) } label: { RabbitIcon(.arrowUp, size: 18).frame(width: 36, height: 36) }
                            .accessibilityLabel("向上滚动")
                        Divider().frame(width: 20).overlay(.white.opacity(0.25))
                        Button { session.sendWheel(delta: -3) } label: { RabbitIcon(.arrowDown, size: 18).frame(width: 36, height: 36) }
                            .accessibilityLabel("向下滚动")
                    }
                    .padding(6)
                    .foregroundStyle(.white)
                    .background(RCColor.hudBg, in: Capsule())
                    .safeAreaPadding(.trailing, 10)
                }
            }
            .onDisappear {
                session.releasePressedInput()
            }
            .onChange(of: phase) {
                if phase != .active { session.releasePressedInput() }
            }
        }
    }
}
