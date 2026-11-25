import MetalKit
import CoreVideo
import SwiftUI
import RabbitControlCore

/// Metal 零拷贝视频渲染:CVPixelBuffer → CVMetalTextureCache 直接映射,
/// 无 CPU 拷贝。VT 解码输出 NV12 双平面(Y + UV),shader 内做 BT.709 色彩转换。
/// 帧获取仍走 rc-media-apple 的帧泵(rc_apple_media_frame_take/release)。
final class MetalVideoRenderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var textureCache: CVMetalTextureCache?
    private let pipeline: MTLRenderPipelineState
    private var hasFrame = false

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

    func draw(in view: MTKView) {
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

        func makeTexture(_ plane: Int, _ pw: Int, _ ph: Int, _ fmt: MTLPixelFormat) -> MTLTexture? {
            var texOut: CVMetalTexture?
            let ok = CVMetalTextureCacheCreateTextureFromImage(
                nil, cache, pixelBuffer, nil, fmt, pw, ph, plane, &texOut)
            guard ok == kCVReturnSuccess, let t = texOut else { return nil }
            return CVMetalTextureGetTexture(t)
        }

        guard let texY = makeTexture(0, w, h, .r8Unorm),
              let texUV = makeTexture(1, w / 2, h / 2, .rg8Unorm),
              let buf = commandQueue.makeCommandBuffer(),
              let enc = buf.makeRenderCommandEncoder(descriptor: pass) else { return }

        enc.setRenderPipelineState(pipeline)
        enc.setFragmentTexture(texY, index: 0)
        enc.setFragmentTexture(texUV, index: 1)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        buf.present(drawable)
        buf.commit()
        hasFrame = true
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

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.delegate = renderer
        view.preferredFramesPerSecond = 60
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.contentMode = .scaleAspectFit
        view.colorPixelFormat = .bgra8Unorm
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {}
}
