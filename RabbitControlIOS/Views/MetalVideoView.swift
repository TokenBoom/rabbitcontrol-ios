import MetalKit
import CoreVideo
import SwiftUI
import RabbitControlCore

/// Metal 零拷贝视频渲染:CVPixelBuffer → CVMetalTextureCache 直接映射,
/// 无 CPU 拷贝。VT 解码输出 NV12 双平面(Y + UV),shader 内做 BT.709 色彩转换。
/// 帧获取仍走 rc-media-apple 的帧泵(rc_apple_media_frame_take/release)。
/// 缩放/平移共享状态:SwiftUI 手势层写入,Metal 渲染层与输入映射层读取。
/// scale=1 为 aspect-fit 刚好适配;pan 为相对居中位置的偏移(单位:点)。
final class ZoomPanState {
    nonisolated(unsafe) var scale: CGFloat = 1
    nonisolated(unsafe) var panX: CGFloat = 0
    nonisolated(unsafe) var panY: CGFloat = 0

    func reset() {
        scale = 1
        panX = 0
        panY = 0
    }
}

final class MetalVideoRenderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var textureCache: CVMetalTextureCache?
    private let pipeline: MTLRenderPipelineState
    private var hasFrame = false
    var zoomPan: ZoomPanState?

    override init() {
        guard let dev = MTLCreateSystemDefaultDevice(),
              let queue = dev.makeCommandQueue() else {
            fatalError("Metal 不可用")
        }
        device = dev
        commandQueue = queue
        CVMetalTextureCacheCreate(nil, nil, dev, nil, &textureCache)

        let src = """
        #include <metal_stdlib>
        using namespace metal;
        struct VOut { float4 pos [[position]]; float2 uv; };
        vertex VOut vmain(uint vid [[vertex_id]]) {
            float2 p[3] = { float2(-1,-1), float2(3,-1), float2(-1,3) };
            VOut o;
            o.pos = float4(p[vid], 0, 1);
            o.uv = float2((p[vid].x + 1.0) * 0.5, (1.0 - p[vid].y) * 0.5);
            return o;
        }
        fragment float4 fmain(VOut in [[stage_in]],
                              texture2d<float> texY [[texture(0)]],
                              texture2d<float> texUV [[texture(1)]]) {
            constexpr sampler s(filter::linear);
            float y = texY.sample(s, in.uv).r;
            float2 uv = texUV.sample(s, in.uv).rg - 0.5;
            // BT.709 视频范围扩展
            y = (y - 0.0625) * 1.164;
            float r = y + 1.792 * uv.y;
            float g = y - 0.213 * uv.x - 0.533 * uv.y;
            float b = y + 2.112 * uv.x;
            return float4(r, g, b, 1.0);
        }
        """
        // swiftlint:disable:next force_try — shader 为编译期常量,失败即编程错误
        let lib = try! dev.makeLibrary(source: src, options: nil)
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = lib.makeFunction(name: "vmain")
        desc.fragmentFunction = lib.makeFunction(name: "fmain")
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        // swiftlint:disable:next force_try
        pipeline = try! dev.makeRenderPipelineState(descriptor: desc)
        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    private var drawCount = 0
    private var fallbackY: MTLTexture?
    private var fallbackUV: MTLTexture?
    private var fallbackSize = CGSize.zero
    private static var pixelFormatLogged = false
    nonisolated(unsafe) static var diagInfo = ""
    nonisolated(unsafe) static var diagError = ""

    func draw(in view: MTKView) {
        // 帧链路诊断:每 ~2s 把 Rust 侧计数写到 Documents,供联调读取
        drawCount += 1
        if drawCount % 120 == 1 {
            Self.writeFrameStats()
        }
        // 取最新帧(所有权转入本函数,用毕归还)
        guard let json = Self.takeFrameJSON(),
              let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ptr = obj["ptr"] as? NSNumber, ptr.uint64Value != 0 else {
            // 无帧:清屏一次避免残影
            if !hasFrame, let drawable = view.currentDrawable,
               let pass = view.currentRenderPassDescriptor,
               let buf = commandQueue.makeCommandBuffer(),
               let enc = buf.makeRenderCommandEncoder(descriptor: pass) {
                enc.endEncoding()
                buf.present(drawable)
                buf.commit()
            }
            return
        }
        let pixelBuffer = Unmanaged<CVPixelBuffer>.fromOpaque(
            UnsafeRawPointer(bitPattern: UInt(ptr.uint64Value))!
        ).takeUnretainedValue()
        defer { rc_apple_media_frame_release(ptr.uint64Value) }

        guard let cache = textureCache,
              let drawable = view.currentDrawable,
              let pass = view.currentRenderPassDescriptor else { return }

        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)

        // 一次性诊断:记录像素格式/平面数/纹理创建结果,定位模拟器黑屏
        if !Self.pixelFormatLogged {
            Self.pixelFormatLogged = true
            let fmt4cc = CVPixelBufferGetPixelFormatType(pixelBuffer)
            let planes = CVPixelBufferGetPlaneCount(pixelBuffer)
            let iosurface = CVPixelBufferGetIOSurface(pixelBuffer) != nil
            let cc = String(format: "%c%c%c%c", (fmt4cc >> 24) & 0xff, (fmt4cc >> 16) & 0xff, (fmt4cc >> 8) & 0xff, fmt4cc & 0xff)
            Self.diagInfo = "fmt=\(cc)(\(fmt4cc)) planes=\(planes) iosurface=\(iosurface) \(w)x\(h)"
        }

        func makeTexture(_ plane: Int, _ pw: Int, _ ph: Int, _ fmt: MTLPixelFormat) -> MTLTexture? {
            var texOut: CVMetalTexture?
            let ok = CVMetalTextureCacheCreateTextureFromImage(
                nil, cache, pixelBuffer, nil, fmt, pw, ph, plane, &texOut)
            if ok != kCVReturnSuccess {
                Self.diagError = "plane\(plane) err=\(ok)"
                return nil
            }
            guard let t = texOut else { return nil }
            return CVMetalTextureGetTexture(t)
        }

        // 零拷贝优先;模拟器 VT 输出非 IOSurface 支撑(err -6660)时回退 CPU 上传
        var texY = makeTexture(0, w, h, .r8Unorm)
        var texUV = makeTexture(1, w / 2, h / 2, .rg8Unorm)
        if texY == nil || texUV == nil {
            (texY, texUV) = uploadViaCPU(pixelBuffer, w: w, h: h)
        }

        guard let texY, let texUV,
              let buf = commandQueue.makeCommandBuffer(),
              let enc = buf.makeRenderCommandEncoder(descriptor: pass) else { return }

        // 等比适配 + 用户缩放/平移:aspect-fit 基础上乘 zoom,pan 以点为单位换算到像素。
        let dw = view.drawableSize.width, dh = view.drawableSize.height
        if dw > 0, dh > 0, w > 0, h > 0 {
            let zp = zoomPan ?? ZoomPanState()
            let csf = view.contentScaleFactor
            let scale = min(dw / CGFloat(w), dh / CGFloat(h)) * zp.scale
            let vpW = CGFloat(w) * scale, vpH = CGFloat(h) * scale
            enc.setViewport(MTLViewport(
                originX: Double((dw - vpW) / 2 + zp.panX * csf),
                originY: Double((dh - vpH) / 2 + zp.panY * csf),
                width: Double(vpW), height: Double(vpH), znear: 0, zfar: 1))
        }
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentTexture(texY, index: 0)
        enc.setFragmentTexture(texUV, index: 1)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        buf.present(drawable)
        buf.commit()
        hasFrame = true
    }

    /// CPU 上传回退:直接锁像素缓冲拷进普通 MTLTexture(不依赖 IOSurface)。
    /// 模拟器 VT 解码输出非 IOSurface 支撑缓冲,零拷贝纹理缓存拒绝(err -6660),走此路径。
    private func uploadViaCPU(_ pb: CVPixelBuffer, w: Int, h: Int) -> (MTLTexture?, MTLTexture?) {
        if fallbackSize.width != CGFloat(w) || fallbackSize.height != CGFloat(h) {
            let descY = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .r8Unorm, width: w, height: h, mipmapped: false)
            descY.usage = .shaderRead
            let descUV = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rg8Unorm, width: w / 2, height: h / 2, mipmapped: false)
            descUV.usage = .shaderRead
            fallbackY = device.makeTexture(descriptor: descY)
            fallbackUV = device.makeTexture(descriptor: descUV)
            fallbackSize = CGSize(width: w, height: h)
        }
        guard let ty = fallbackY, let tuv = fallbackUV else { return (nil, nil) }

        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }

        guard let baseY = CVPixelBufferGetBaseAddressOfPlane(pb, 0),
              let baseUV = CVPixelBufferGetBaseAddressOfPlane(pb, 1) else { return (nil, nil) }
        let strideY = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        let strideUV = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
        ty.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0,
                   withBytes: baseY, bytesPerRow: strideY)
        tuv.replace(region: MTLRegionMake2D(0, 0, w / 2, h / 2), mipmapLevel: 0,
                    withBytes: baseUV, bytesPerRow: strideUV)
        return (ty, tuv)
    }

    private static func writeFrameStats() {
        guard let ptr = rc_apple_media_stats() else { return }
        let stats = String(cString: ptr)
        rc_string_free(ptr)
        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let line = stats + " | " + diagInfo + " | " + diagError
        try? line.write(to: dir.appendingPathComponent("frame-stats.txt"), atomically: true, encoding: .utf8)
    }

    private static func takeFrameJSON() -> String? {
        guard let ptr = rc_apple_media_frame_take() else { return nil }
        defer { rc_string_free(ptr) }
        return String(cString: ptr)
    }
}

/// SwiftUI 包装。`frameCovered` 比例留给上层做安全区/纵横比适配,本视图铺满即裁剪。
struct MetalVideoView: UIViewRepresentable {
    let renderer = MetalVideoRenderer()
    let zoomPan: ZoomPanState

    init(zoomPan: ZoomPanState) {
        renderer.zoomPan = zoomPan
        self.zoomPan = zoomPan
    }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.delegate = renderer
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

    func updateUIView(_ uiView: MTKView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(zoomPan: zoomPan)
    }

    final class Coordinator: NSObject {
        let zoomPan: ZoomPanState
        private var baseScale: CGFloat = 1
        private var basePan = CGPoint.zero

        init(zoomPan: ZoomPanState) {
            self.zoomPan = zoomPan
        }

        @objc func onPinch(_ g: UIPinchGestureRecognizer) {
            switch g.state {
            case .began:
                baseScale = zoomPan.scale
            case .changed:
                // 1x 为适配下限,8x 上限;双指捏合的质心移动天然兼顾部分平移
                zoomPan.scale = min(8, max(1, baseScale * g.scale))
                if zoomPan.scale == 1 {
                    zoomPan.panX = 0
                    zoomPan.panY = 0
                }
            default:
                break
            }
        }

        @objc func onPan(_ g: UIPanGestureRecognizer) {
            switch g.state {
            case .began:
                basePan = CGPoint(x: zoomPan.panX, y: zoomPan.panY)
            case .changed:
                let t = g.translation(in: g.view)
                guard zoomPan.scale > 1, let view = g.view else { return }
                // 平移范围钳制:放大后的画面边缘不越过视图中心太多
                let maxX = view.bounds.width * zoomPan.scale / 2
                let maxY = view.bounds.height * zoomPan.scale / 2
                zoomPan.panX = min(maxX, max(-maxX, basePan.x + t.x))
                zoomPan.panY = min(maxY, max(-maxY, basePan.y + t.y))
            default:
                break
            }
        }

        @objc func onReset(_ g: UITapGestureRecognizer) {
            zoomPan.reset()
        }
    }
}
