import MetalKit
import RabbitControlCore
import SwiftUI
import Testing
@testable import RabbitControlIOS

struct MetalVideoViewTests {
    @MainActor
    @Test("媒体库在模拟器渲染无 IOSurface 的 NV12 帧，不需要 Mac 屏幕权限")
    func mediaLibraryDrawsNV12() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let renderer = try #require(RCMetalRenderer(device: device))
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let host = UIViewController()
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: 64, height: 64), device: device)
        view.isPaused = true
        host.view.addSubview(view)
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        for format in [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange] {
            var buffer: CVPixelBuffer?
            try #require(CVPixelBufferCreate(nil, 64, 64, format, nil, &buffer) == kCVReturnSuccess)
            let frame = try #require(buffer)
            #expect(renderer.draw(frame: frame, in: view, viewport: view.bounds))
        }
    }

    @MainActor
    @Test("竖屏 1x 按手机宽度等比显示完整桌面，仅上下留黑")
    func portraitFitsWidth() {
        let zoom = ZoomPanState()
        zoom.videoSize = CGSize(width: 960, height: 720)
        #expect(zoom.videoRect(in: CGSize(width: 400, height: 860))
                == CGRect(x: 0, y: 280, width: 400, height: 300))
    }

    @MainActor
    @Test("横屏 1x 等比完整显示不裁切，放大后可平移，复位回到居中")
    func landscapeFitsWidthAndPans() {
        let zoom = ZoomPanState()
        zoom.videoSize = CGSize(width: 1280, height: 720)
        let size = CGSize(width: 800, height: 400)
        // 16:9 视频放进 2:1 视口:按高度适配,左右留边居中,不裁切画面
        let centered = CGRect(x: 400.0 - 400.0 * 16.0 / 9.0 / 2.0, y: 0, width: 400.0 * 16.0 / 9.0, height: 400)
        #expect(zoom.videoRect(in: size) == centered)
        // 1x 已完整显示,平移不生效(无越界可移)
        zoom.pan = CGPoint(x: 100, y: -200)
        #expect(zoom.videoRect(in: size) == centered)
        // 放大后可平移,且边缘 clamp 不露出视频外区域
        zoom.scale = 2
        #expect(zoom.videoRect(in: size).width == centered.width * 2)
        zoom.pan = CGPoint(x: 10000, y: 10000)
        let rect = zoom.videoRect(in: size)
        #expect(rect.maxX >= size.width && rect.maxY >= size.height)
        zoom.reset()
        #expect(zoom.videoRect(in: size) == centered)
    }

    @MainActor
    @Test("竖屏与横屏在 1x 与放大平移下，触控映射与渲染矩形严格一致")
    func touchMappingMatchesRenderedRect() {
        let cases: [(CGSize, CGFloat, CGPoint)] = [
            (CGSize(width: 393, height: 852), 1.0, .zero),
            (CGSize(width: 393, height: 852), 2.5, CGPoint(x: 120, y: -80)),
            (CGSize(width: 852, height: 393), 1.0, .zero),
            (CGSize(width: 852, height: 393), 3.0, CGPoint(x: -240, y: 150)),
        ]
        for (viewport, scale, pan) in cases {
            let zoom = ZoomPanState()
            zoom.videoSize = CGSize(width: 2560, height: 1600)
            zoom.scale = scale
            zoom.pan = pan
            let rect = zoom.videoRect(in: viewport)
            for (ux, uy) in [(0.0, 0.0), (0.25, 0.75), (0.5, 0.5), (1.0, 1.0)] {
                let viewPt = CGPoint(x: rect.minX + rect.width * ux, y: rect.minY + rect.height * uy)
                let mapped = zoom.normalizedPoint(for: viewPt, in: viewport)
                #expect(abs(mapped.x - ux) < 1e-6)
                #expect(abs(mapped.y - uy) < 1e-6)
            }
        }
    }

    @MainActor
    @Test("SwiftUI 重建视图值后，原 Metal 视图仍由同一渲染器取帧")
    func rendererSurvivesViewUpdate() throws {
        let zoomPan = ZoomPanState()
        let host = UIHostingController(rootView: MetalVideoView(zoomPan: zoomPan))
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        window.layoutIfNeeded()
        host.view.layoutIfNeeded()
        let view = try #require(metalView(in: host.view))
        let rendererID = ObjectIdentifier(try #require(view.delegate))

        host.rootView = MetalVideoView(zoomPan: zoomPan)
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        #expect(metalView(in: host.view) === view)
        #expect(view.delegate.map(ObjectIdentifier.init) == rendererID)
    }

    @Test("ProMotion 高刷动态帧率：60fps 及以下保底 60Hz，90/120fps 拉满屏幕上限")
    func preferredFramesPerSecondAdaptsToProMotion() {
        #expect(MetalVideoView.resolvedPreferredFramesPerSecond(targetFps: 30, screenMaxFps: 60) == 60)
        #expect(MetalVideoView.resolvedPreferredFramesPerSecond(targetFps: 120, screenMaxFps: 60) == 60)
        #expect(MetalVideoView.resolvedPreferredFramesPerSecond(targetFps: 30, screenMaxFps: 120) == 60)
        #expect(MetalVideoView.resolvedPreferredFramesPerSecond(targetFps: 60, screenMaxFps: 120) == 60)
        #expect(MetalVideoView.resolvedPreferredFramesPerSecond(targetFps: 90, screenMaxFps: 120) == 120)
        #expect(MetalVideoView.resolvedPreferredFramesPerSecond(targetFps: 120, screenMaxFps: 120) == 120)
    }

    @Test("v0.1.18 零分配帧接口在无待取帧时直接返回 false")
    func rawFrameTakeFastPathWhenEmpty() {
        var raw = RcAppleFrame()
        if !rc_apple_media_frame_take_raw(&raw) {
            #expect(raw.ptr == 0)
        } else if raw.ptr != 0 {
            rc_apple_media_frame_release(raw.ptr)
        }
    }

    @MainActor
    private func metalView(in view: UIView) -> MTKView? {
        if let metal = view as? MTKView { return metal }
        for child in view.subviews {
            if let metal = metalView(in: child) { return metal }
        }
        return nil
    }
}
