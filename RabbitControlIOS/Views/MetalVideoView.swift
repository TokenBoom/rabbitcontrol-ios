import MetalKit
import CoreImage
import CoreVideo
import SwiftUI
import RabbitControlCore

/// CoreVideo 像素缓冲是不可变引用类型,跨队列传递由底层引用计数保证生命周期。
private nonisolated struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
}

/// 缩放/平移共享状态:SwiftUI 手势层写入,Metal 渲染层与输入映射层读取。
/// 1x 为等比铺满宽度；平移以视图中的点为单位。
@Observable final class ZoomPanState {
    var hasPresentedFrame = false
    /// 量化到 0.05 步进的可见缩放倍率,供顶部胶囊显示与一键复位,避免捏合时逐帧刷新整棵 SwiftUI 树。
    private(set) var displayScale: CGFloat = 1
    var isZoomed: Bool { displayScale > 1.02 }

    @ObservationIgnored
    var videoSize = CGSize.zero
    @ObservationIgnored
    var scale: CGFloat = 1 {
        didSet {
            let next = scale <= 1.02 ? 1.0 : ((scale * 20).rounded() / 20)
            if next == 1.0 && displayScale != 1.0 {
                displayScale = 1.0
            } else if abs(next - displayScale) >= 0.04 {
                displayScale = next
            }
        }
    }
    @ObservationIgnored
    var pan = CGPoint.zero
    /// 跨触控模式与竖屏分屏共享的远端归一化光标坐标（避免切换直触/触控板或横竖屏旋转时光标跳回屏幕中心）。
    @ObservationIgnored
    var cursor = CGPoint(x: 0.5, y: 0.5)
    /// 零 SwiftUI 重绘开销的光标位置同步回调（供分屏顶部画面浮层以 CoreAnimation 实时绘制虚拟光标）。
    @ObservationIgnored
    var onCursorVisualUpdate: ((CGPoint, Bool, Bool) -> Void)?

    func updateSharedCursor(_ normalized: CGPoint, leftHeld: Bool, active: Bool) {
        cursor = CGPoint(
            x: min(max(normalized.x, 0), 1),
            y: min(max(normalized.y, 0), 1)
        )
        onCursorVisualUpdate?(cursor, leftHeld, active)
    }

    /// 等比完整适配(aspect-contain)后的视频矩形,缩放以它为基准放大。
    /// 竖屏看横屏桌面时自然等价于宽度充满;横屏或竖长视频不会裁切桌面边缘,
    /// 保证画面上每个可见点的输入映射与显示一一对应。
    func videoRect(in size: CGSize) -> CGRect {
        guard videoSize.width > 0, videoSize.height > 0, size.width > 0, size.height > 0 else {
            return CGRect(origin: .zero, size: size)
        }
        let ratio = videoSize.width / videoSize.height
        let baseWidth = min(size.width, size.height * ratio)
        let width = baseWidth * scale
        let height = width / ratio
        func origin(_ extent: CGFloat, _ viewport: CGFloat, _ offset: CGFloat) -> CGFloat {
            let center = (viewport - extent) / 2
            return center >= 0 ? center : center + min(-center, max(center, offset))
        }
        return CGRect(x: origin(width, size.width, pan.x), y: origin(height, size.height, pan.y),
                      width: width, height: height)
    }

    func reset() {
        scale = 1
        pan = .zero
    }

    /// 将视图坐标按当前缩放/平移后的视频矩形反算为 [0, 1] 归一化坐标。
    func normalizedPoint(for viewPoint: CGPoint, in viewportSize: CGSize) -> CGPoint {
        let rect = videoRect(in: viewportSize)
        let nx = (viewPoint.x - rect.minX) / max(rect.width, 1)
        let ny = (viewPoint.y - rect.minY) / max(rect.height, 1)
        return CGPoint(x: min(max(nx, 0), 1), y: min(max(ny, 0), 1))
    }

    /// 按当前缩放与视口尺寸限制平移范围,避免拖动超过画面边缘后产生回拉死区。
    func clampPan(in size: CGSize) {
        guard videoSize.width > 0, videoSize.height > 0, size.width > 0, size.height > 0 else { return }
        if scale <= 1 {
            pan = .zero
            return
        }
        let ratio = videoSize.width / videoSize.height
        let baseWidth = min(size.width, size.height * ratio)
        let width = baseWidth * scale
        let height = width / ratio
        let maxX = max(0, (width - size.width) / 2)
        let maxY = max(0, (height - size.height) / 2)
        pan = CGPoint(
            x: min(maxX, max(-maxX, pan.x)),
            y: min(maxY, max(-maxY, pan.y))
        )
    }
}

final class MetalVideoRenderer: NSObject, MTKViewDelegate {
    private struct TakenFrame {
        let pixelBuffer: CVPixelBuffer
        let width: Int
        let height: Int
        let seq: UInt64
    }

    private let renderer: RCMetalRenderer?
    private let zoomPan: ZoomPanState
    private var latestFrame: CVPixelBuffer?
    private var lastFrameSeq: UInt64 = 0
    private var lastViewport: CGRect?
    var previewDeviceID: String?
    private lazy var previewContext = CIContext()
    private var previewAt: TimeInterval = 0

    init(zoomPan: ZoomPanState) {
        self.zoomPan = zoomPan
        renderer = MTLCreateSystemDefaultDevice().flatMap { RCMetalRenderer(device: $0) }
        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    private static let previewQueue = DispatchQueue(label: "com.rabbitcontrol.preview", qos: .utility)

    func draw(in view: MTKView) {
        if let taken = Self.takeLatestFrame(), taken.seq == 0 || taken.seq != lastFrameSeq {
            let newFrame = taken.pixelBuffer
            lastFrameSeq = taken.seq
            if let id = previewDeviceID, ProcessInfo.processInfo.systemUptime >= previewAt {
                previewAt = ProcessInfo.processInfo.systemUptime + 15
                let frameCopy = UncheckedSendable(value: newFrame)
                let context = previewContext
                Self.previewQueue.async {
                    let image = CIImage(cvPixelBuffer: frameCopy.value)
                    let maxDim = max(image.extent.width, image.extent.height)
                    let scale = min(1, 1080 / max(maxDim, 1))
                    let output: CIImage
                    if scale < 1 {
                        output = image.applyingFilter("CILanczosScaleTransform", parameters: [
                            kCIInputScaleKey: scale,
                            kCIInputAspectRatioKey: 1.0,
                        ])
                    } else {
                        output = image
                    }
                    if let cg = context.createCGImage(output, from: output.extent) {
                        let uiImage = UIImage(cgImage: cg)
                        Task { @MainActor in
                            AuthService.shared.rememberPreview(uiImage, deviceID: id)
                        }
                    }
                }
            }
            latestFrame = newFrame
            lastViewport = nil
            zoomPan.videoSize = CGSize(width: taken.width, height: taken.height)
        }
        guard let pixelBuffer = latestFrame else {
            _ = renderer?.draw(frame: nil, in: view, viewport: .zero)
            return
        }
        let size = view.bounds.size
        guard size.width > 0, size.height > 0,
              view.drawableSize.width > 0, view.drawableSize.height > 0 else { return }
        let rect = zoomPan.videoRect(in: size)
        let viewport = rect.applying(CGAffineTransform(scaleX: view.drawableSize.width / size.width,
                                                       y: view.drawableSize.height / size.height))
        // 桌面静止时可能没有新帧；旋转、缩放或平移仍要重画上一帧。
        guard viewport != lastViewport else { return }
        if renderer?.draw(frame: pixelBuffer, in: view, viewport: viewport) == true {
            lastViewport = viewport
            if !zoomPan.hasPresentedFrame { zoomPan.hasPresentedFrame = true }
        }
    }

    /// 零分配拉取最新解码帧：无新帧时底层仅一次原子读取即返回 false，无锁无 JSON 开销。
    private static func takeLatestFrame() -> TakenFrame? {
        var raw = RcAppleFrame()
        guard rc_apple_media_frame_take_raw(&raw),
              raw.ptr != 0,
              let opaque = UnsafeRawPointer(bitPattern: UInt(raw.ptr)) else {
            return nil
        }
        // Unmanaged.takeUnretainedValue() 桥接为强引用时由 ARC 先执行 CFRetain(+1)，
        // 再调用 rc_apple_media_frame_release 归还 Rust 侧移交的 +1 引用计数。
        let buffer = Unmanaged<CVPixelBuffer>.fromOpaque(opaque).takeUnretainedValue()
        rc_apple_media_frame_release(raw.ptr)
        let width = raw.width > 0 ? Int(raw.width) : CVPixelBufferGetWidth(buffer)
        let height = raw.height > 0 ? Int(raw.height) : CVPixelBufferGetHeight(buffer)
        return TakenFrame(pixelBuffer: buffer, width: width, height: height, seq: raw.seq)
    }
}

/// SwiftUI 包装。`frameCovered` 比例留给上层做安全区/纵横比适配,本视图铺满即裁剪。
struct MetalVideoView: UIViewRepresentable {
    let zoomPan: ZoomPanState
    var previewDeviceID: String?
    var targetFps: Int = 60

    nonisolated static func resolvedPreferredFramesPerSecond(targetFps: Int, screenMaxFps: Int) -> Int {
        let cap = max(60, min(120, screenMaxFps))
        guard targetFps > 60, cap > 60 else { return 60 }
        // ProMotion 120Hz 屏幕下 CADisplayLink 按整数分频(120/60/40/30)，
        // 高于 60fps(如 90/120fps)时拉满屏幕高刷上限，避免 90fps 被向下分频回 60Hz。
        return cap
    }

    private func preferredFps(for view: MTKView) -> Int {
        let screenMax = view.window?.windowScene?.screen.maximumFramesPerSecond
            ?? UIApplication.shared.connectedScenes
                .compactMap { ($0 as? UIWindowScene)?.screen.maximumFramesPerSecond }
                .max()
            ?? 60
        return Self.resolvedPreferredFramesPerSecond(targetFps: targetFps, screenMaxFps: screenMax)
    }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.delegate = context.coordinator.renderer
        context.coordinator.renderer.previewDeviceID = previewDeviceID
        view.preferredFramesPerSecond = preferredFps(for: view)
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.contentMode = .scaleAspectFit
        view.colorPixelFormat = .bgra8Unorm

        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.onPinch(_:)))
        pinch.delegate = context.coordinator
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.onPan(_:)))
        pan.minimumNumberOfTouches = 2
        pan.maximumNumberOfTouches = 2
        pan.delegate = context.coordinator
        // 放大态(>1x)下允许单指拖动平移画面（分屏触控板上方画面查看用）
        let singlePan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.onSingleFingerPan(_:)))
        singlePan.minimumNumberOfTouches = 1
        singlePan.maximumNumberOfTouches = 1
        singlePan.delegate = context.coordinator
        context.coordinator.singleFingerPan = singlePan
        // 双指双击复位缩放
        let reset = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.onReset(_:)))
        reset.numberOfTouchesRequired = 2
        reset.numberOfTapsRequired = 2
        view.addGestureRecognizer(pinch)
        view.addGestureRecognizer(pan)
        view.addGestureRecognizer(singlePan)
        view.addGestureRecognizer(reset)
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        context.coordinator.renderer.previewDeviceID = previewDeviceID
        let desired = preferredFps(for: uiView)
        if uiView.preferredFramesPerSecond != desired {
            uiView.preferredFramesPerSecond = desired
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(zoomPan: zoomPan)
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        // MTKView.delegate 是弱引用；渲染器必须与 UIKit 视图同寿命。
        let renderer: MetalVideoRenderer
        let zoomPan: ZoomPanState
        weak var singleFingerPan: UIPanGestureRecognizer?
        private var baseScale: CGFloat = 1
        private var lastPinchCenter: CGPoint = .zero
        private var basePan = CGPoint.zero
        init(zoomPan: ZoomPanState) {
            self.zoomPan = zoomPan
            renderer = MetalVideoRenderer(zoomPan: zoomPan)
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            if gestureRecognizer === singleFingerPan {
                return zoomPan.scale > 1.01
            }
            return true
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            if gestureRecognizer === singleFingerPan || otherGestureRecognizer === singleFingerPan {
                return false
            }
            return (gestureRecognizer is UIPinchGestureRecognizer && otherGestureRecognizer is UIPanGestureRecognizer)
                || (gestureRecognizer is UIPanGestureRecognizer && otherGestureRecognizer is UIPinchGestureRecognizer)
        }

        @objc func onPinch(_ g: UIPinchGestureRecognizer) {
            guard let view = g.view else { return }
            let size = view.bounds.size
            let center = g.location(in: view)
            switch g.state {
            case .began:
                baseScale = zoomPan.scale
                lastPinchCenter = center
            case .changed:
                let oldScale = max(zoomPan.scale, 1)
                let newScale = min(8, max(1, baseScale * g.scale))
                let factor = newScale / oldScale
                let delta = CGPoint(x: center.x - lastPinchCenter.x, y: center.y - lastPinchCenter.y)
                lastPinchCenter = center
                zoomPan.scale = newScale
                if newScale <= 1 {
                    zoomPan.pan = .zero
                } else {
                    let anchorX = center.x - size.width / 2
                    let anchorY = center.y - size.height / 2
                    zoomPan.pan = CGPoint(
                        x: (zoomPan.pan.x - anchorX) * factor + anchorX + delta.x,
                        y: (zoomPan.pan.y - anchorY) * factor + anchorY + delta.y
                    )
                    zoomPan.clampPan(in: size)
                }
                zoomPan.onCursorVisualUpdate?(zoomPan.cursor, false, false)
            default:
                break
            }
        }

        @objc func onPan(_ g: UIPanGestureRecognizer) {
            guard let view = g.view else { return }
            let size = view.bounds.size
            switch g.state {
            case .began:
                let rect = zoomPan.videoRect(in: size)
                basePan = CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2)
            case .changed:
                guard !(g.view?.gestureRecognizers?.contains(where: { $0 is UIPinchGestureRecognizer && $0.state == .changed }) ?? false) else {
                    return
                }
                let t = g.translation(in: view)
                zoomPan.pan = CGPoint(x: basePan.x + t.x, y: basePan.y + t.y)
                zoomPan.clampPan(in: size)
                zoomPan.onCursorVisualUpdate?(zoomPan.cursor, false, false)
            default:
                break
            }
        }

        @objc func onSingleFingerPan(_ g: UIPanGestureRecognizer) {
            guard let view = g.view, zoomPan.scale > 1.01 else { return }
            let size = view.bounds.size
            switch g.state {
            case .began:
                basePan = zoomPan.pan
            case .changed:
                let t = g.translation(in: view)
                zoomPan.pan = CGPoint(x: basePan.x + t.x, y: basePan.y + t.y)
                zoomPan.clampPan(in: size)
                zoomPan.onCursorVisualUpdate?(zoomPan.cursor, false, false)
            default:
                break
            }
        }

        @objc func onReset(_ g: UITapGestureRecognizer) {
            zoomPan.reset()
            zoomPan.onCursorVisualUpdate?(zoomPan.cursor, false, false)
        }
    }
}
