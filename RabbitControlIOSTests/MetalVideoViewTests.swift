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

    @MainActor
    private func metalView(in view: UIView) -> MTKView? {
        if let metal = view as? MTKView { return metal }
        for child in view.subviews {
            if let metal = metalView(in: child) { return metal }
        }
        return nil
    }
}
