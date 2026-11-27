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

    private var streamFps: Int {
        if let fps = session.display?.fps, fps > 0 { return fps }
        if case .negotiated(_, _, let fps, _, _) = session.state, fps > 0 { return fps }
        return 60
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                RCColor.stageBg
                MetalVideoView(zoomPan: zoomPan, previewDeviceID: previewDeviceID, targetFps: streamFps)
                if inputEnabled {
                    TouchInputView(session: session, zoomPan: zoomPan, watchOnly: watchOnly)
                } else if !watchOnly {
                    SplitCursorOverlayView(zoomPan: zoomPan, leftHeld: session.isSustainedLeftHold)
                        .allowsHitTesting(false)
                }
                if !zoomPan.hasPresentedFrame {
                    VStack(spacing: 12) {
                        ProgressView().tint(.white)
                        Text("已连接，等待桌面画面…").font(.subheadline.weight(.semibold))
                        if showCaptureHint {
                            Text("长时间没有画面？请在被控端检查「屏幕录制」系统权限。")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.75))
                        }
                    }
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                    .background(RCColor.hudBg, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(.white.opacity(0.1), lineWidth: 1)
                    }
                    .padding(24)
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
                    FloatingMousePalette(session: session)
                        .safeAreaPadding(.trailing, 10)
                        .transition(.scale(scale: 0.92).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.18), value: showMouseTools)
            .onDisappear {
                session.releasePressedInput()
            }
            .onChange(of: phase) {
                if phase != .active { session.releasePressedInput() }
            }
        }
    }
}

/// 支持按住即实时按下鼠标左键、松手自动抬起（兼顾快速单击、无障碍触发与双拇指协同按住拖拽）的左键按钮。
struct HoldableLeftMouseButton<Label: View>: View {
    var session: SessionService
    @ViewBuilder var label: (Bool) -> Label

    @State private var didEngagePress = false
    @State private var pressStartedAt: TimeInterval = 0

    private var isHeldVisually: Bool {
        session.isSustainedLeftHold && !session.isDragLocked
    }

    var body: some View {
        Button {
            if didEngagePress {
                didEngagePress = false
                return
            }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            session.clickMouse("left")
        } label: {
            label(isHeldVisually)
        }
        .buttonStyle(HoldablePressStyle { pressed in
            if pressed {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                didEngagePress = true
                pressStartedAt = ProcessInfo.processInfo.systemUptime
                if session.isDragLocked {
                    session.toggleLeftMouseHold()
                } else {
                    session.sendMouseButton(button: "left", pressed: true)
                }
            } else if didEngagePress {
                let elapsed = ProcessInfo.processInfo.systemUptime - pressStartedAt
                if session.isLeftMouseHeld && !session.isDragLocked {
                    let remaining = max(0, 0.035 - elapsed)
                    if remaining > 0.002 {
                        DispatchQueue.main.asyncAfter(deadline: .now() + remaining) {
                            if !session.isDragLocked {
                                session.sendMouseButton(button: "left", pressed: false)
                            }
                        }
                    } else {
                        session.sendMouseButton(button: "left", pressed: false)
                    }
                }
                DispatchQueue.main.async {
                    didEngagePress = false
                }
            }
        })
    }

    private struct HoldablePressStyle: ButtonStyle {
        var onPressChanged: (Bool) -> Void

        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .opacity(configuration.isPressed ? 0.86 : 1.0)
                .onChange(of: configuration.isPressed) { _, isPressed in
                    onPressChanged(isPressed)
                }
        }
    }
}

/// 桌面悬浮鼠标工具条:提供左键(支持按住协同拖拽)、按住拖拽锁、右键、中键与上下滚轮。
struct FloatingMousePalette: View {
    var session: SessionService
    @State private var dragOffsetY: CGFloat = 0
    @State private var baseOffsetY: CGFloat = 0

    var body: some View {
        VStack(spacing: 4) {
            HoldableLeftMouseButton(session: session) { active in
                Text("左键")
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(width: 40, height: 34)
                    .background(active ? RCColor.accent : Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            .accessibilityLabel("点击或按住鼠标左键")
            .accessibilityIdentifier("mouse.left")

            paletteButton(session.isDragLocked ? "拖拽中" : "拖拽", label: session.isDragLocked ? "释放左键拖拽锁定" : "锁定左键以拖动", id: "mouse.drag", active: session.isDragLocked) {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                session.toggleLeftMouseHold()
            }
            paletteButton("右键", label: "点击鼠标右键", id: "mouse.right") {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                session.clickMouse("right")
            }
            paletteButton("中键", label: "点击鼠标中键", id: "mouse.middle") {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                session.clickMouse("middle")
            }
            Divider().frame(width: 24).overlay(.white.opacity(0.22)).padding(.vertical, 2)
            Button {
                session.sendWheel(delta: 3)
            } label: {
                RabbitIcon(.arrowUp, size: 16)
                    .frame(width: 40, height: 34)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            .accessibilityLabel("向上滚动")
            .accessibilityIdentifier("mouse.scrollUp")
            Button {
                session.sendWheel(delta: -3)
            } label: {
                RabbitIcon(.arrowDown, size: 16)
                    .frame(width: 40, height: 34)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            .accessibilityLabel("向下滚动")
            .accessibilityIdentifier("mouse.scrollDown")
        }
        .padding(6)
        .foregroundStyle(.white)
        .background(RCColor.hudBg, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.28), radius: 12, y: 4)
        .offset(y: dragOffsetY)
        .simultaneousGesture(
            DragGesture(minimumDistance: 18)
                .onChanged { value in
                    dragOffsetY = min(180, max(-180, baseOffsetY + value.translation.height))
                }
                .onEnded { _ in
                    baseOffsetY = dragOffsetY
                }
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("session.mousePalette")
    }

    private func paletteButton(_ text: String, label: String, id: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: 40, height: 34)
                .background(active ? RCColor.accent : Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }
}
