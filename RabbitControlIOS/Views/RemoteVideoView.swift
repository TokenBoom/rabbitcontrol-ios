import SwiftUI

/// 远端画面视图:Metal 视图驱动取帧,手势转为归一化输入事件。
struct RemoteVideoView: View {
    var session: SessionService
    var watchOnly: Bool
    var showMouseTools: Bool
    var previewDeviceID: String?

    @State private var zoomPan = ZoomPanState()
    /// 触控按下期间持续上报移动(模拟鼠标拖拽)。
    @State private var touchActive = false
    @State private var rightClick = false
    @State private var showCaptureHint = false
    @Environment(\.scenePhase) private var phase

    var body: some View {
        GeometryReader { geo in
            ZStack {
                RCColor.stageBg
                MetalVideoView(zoomPan: zoomPan, previewDeviceID: previewDeviceID)
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
            .gesture(dragGesture(in: geo.size), isEnabled: !watchOnly)
            .overlay(alignment: .bottom) {
                if !watchOnly && showMouseTools {
                    HStack {
                        Toggle("下次用右键", isOn: $rightClick).toggleStyle(.button)
                            .accessibilityHint("启用后轻点画面一次以发送右键")
                        Button { session.sendWheel(delta: 3) } label: { RabbitIcon(.arrowUp, size: 18).frame(minWidth: 32, minHeight: 32) }
                            .accessibilityLabel("向上滚动")
                        Button { session.sendWheel(delta: -3) } label: { RabbitIcon(.arrowDown, size: 18).frame(minWidth: 32, minHeight: 32) }
                            .accessibilityLabel("向下滚动")
                    }.buttonStyle(.bordered).padding(8)
                    .foregroundStyle(.white).background(RCColor.hudBg, in: Capsule()).padding(.bottom, 32)
                }
            }
            .onChange(of: showMouseTools) {
                session.releasePressedInput()
                touchActive = false
                rightClick = false
            }
            .onDisappear {
                session.releasePressedInput()
                touchActive = false
            }
            .onChange(of: phase) {
                if phase != .active { session.releasePressedInput(); touchActive = false }
            }
        }
    }

    /// 拖拽:起点按下左键,移动上报归一化坐标,抬起释放。
    private func dragGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let rect = zoomPan.videoRect(in: size)
                guard zoomPan.hasPresentedFrame, rect.contains(value.startLocation) else { return }
                let nx = (value.location.x - rect.minX) / max(rect.width, 1)
                let ny = (value.location.y - rect.minY) / max(rect.height, 1)
                session.sendMouseMove(nx: nx, ny: ny)
                if !touchActive {
                    touchActive = true
                    session.sendMouseButton(button: rightClick ? "right" : "left", pressed: true)
                }
            }
            .onEnded { _ in
                guard touchActive else { return }
                touchActive = false
                session.sendMouseButton(button: rightClick ? "right" : "left", pressed: false)
                rightClick = false
            }
    }
}
