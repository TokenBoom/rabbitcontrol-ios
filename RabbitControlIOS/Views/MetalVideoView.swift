import MetalKit
import CoreImage
import CoreVideo
import SwiftUI
import RabbitControlCore

/// 缩放/平移共享状态:SwiftUI 手势层写入,Metal 渲染层与输入映射层读取。
/// 1x 为等比铺满宽度；平移以视图中的点为单位。
@Observable final class ZoomPanState {
    var hasPresentedFrame = false
    @ObservationIgnored
    var videoSize = CGSize.zero
    @ObservationIgnored
    var scale: CGFloat = 1
    @ObservationIgnored
    var pan = CGPoint.zero

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
}

final class MetalVideoRenderer: NSObject, MTKViewDelegate {
    private let renderer: RCMetalRenderer?
    private let zoomPan: ZoomPanState
    private var latestFrame: CVPixelBuffer?
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

    func draw(in view: MTKView) {
        if let newFrame = Self.takeLatestFrame() {
            if let id = previewDeviceID, ProcessInfo.processInfo.systemUptime >= previewAt {
                previewAt = ProcessInfo.processInfo.systemUptime + 15
                let image = CIImage(cvPixelBuffer: newFrame)
                let scale = min(1, 240 / max(image.extent.width, image.extent.height))
                let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                if let cg = previewContext.createCGImage(small, from: small.extent) {
                    AuthService.shared.rememberPreview(UIImage(cgImage: cg), deviceID: id)
                }
            }
            latestFrame = newFrame
            lastViewport = nil
            zoomPan.videoSize = CGSize(width: CVPixelBufferGetWidth(newFrame), height: CVPixelBufferGetHeight(newFrame))
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

    private static func takeLatestFrame() -> CVPixelBuffer? {
        guard let json = rc_apple_media_frame_take() else { return nil }
        defer { rc_string_free(json) }
        guard let obj = try? JSONSerialization.jsonObject(with: Data(String(cString: json).utf8)) as? [String: Any],
              let ptr = obj["ptr"] as? NSNumber,
              let raw = UnsafeRawPointer(bitPattern: UInt(ptr.uint64Value)) else { return nil }
        defer { rc_apple_media_frame_release(ptr.uint64Value) }
        return Unmanaged<CVPixelBuffer>.fromOpaque(raw).takeUnretainedValue()
    }
}

/// SwiftUI 包装。`frameCovered` 比例留给上层做安全区/纵横比适配,本视图铺满即裁剪。
struct MetalVideoView: UIViewRepresentable {
    let zoomPan: ZoomPanState
    var previewDeviceID: String?

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.delegate = context.coordinator.renderer
        context.coordinator.renderer.previewDeviceID = previewDeviceID
        view.preferredFramesPerSecond = 60
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.contentMode = .scaleAspectFit
        view.colorPixelFormat = .bgra8Unorm

        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.onPinch(_:)))
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.onPan(_:)))
        pan.minimumNumberOfTouches = 2
        pan.maximumNumberOfTouches = 2
        // 双指平移不抢占单指鼠标操控;双指双击复位缩放
        let reset = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.onReset(_:)))
        reset.numberOfTouchesRequired = 2
        reset.numberOfTapsRequired = 2
        view.addGestureRecognizer(pinch)
        view.addGestureRecognizer(pan)
        view.addGestureRecognizer(reset)
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        context.coordinator.renderer.previewDeviceID = previewDeviceID
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(zoomPan: zoomPan)
    }

    final class Coordinator: NSObject {
        // MTKView.delegate 是弱引用；渲染器必须与 UIKit 视图同寿命。
        let renderer: MetalVideoRenderer
        let zoomPan: ZoomPanState
        private var baseScale: CGFloat = 1
        private var basePan = CGPoint.zero
        init(zoomPan: ZoomPanState) {
            self.zoomPan = zoomPan
            renderer = MetalVideoRenderer(zoomPan: zoomPan)
        }

        @objc func onPinch(_ g: UIPinchGestureRecognizer) {
            switch g.state {
            case .began:
                baseScale = zoomPan.scale
            case .changed:
                // 1x 为适配下限,8x 上限;双指捏合的质心移动天然兼顾部分平移
                zoomPan.scale = min(8, max(1, baseScale * g.scale))
                if zoomPan.scale == 1 {
                    zoomPan.pan = .zero
                }
            default:
                break
            }
        }

        @objc func onPan(_ g: UIPanGestureRecognizer) {
            switch g.state {
            case .began:
                guard let size = g.view?.bounds.size else { return }
                let rect = zoomPan.videoRect(in: size)
                basePan = CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2)
            case .changed:
                let t = g.translation(in: g.view)
                zoomPan.pan = CGPoint(x: basePan.x + t.x, y: basePan.y + t.y)
            default:
                break
            }
        }

        @objc func onReset(_ g: UITapGestureRecognizer) {
            zoomPan.reset()
        }
    }
}
