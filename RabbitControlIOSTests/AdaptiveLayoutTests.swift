import CoreGraphics
import SwiftUI
import Testing
import UIKit
@testable import RabbitControlIOS

struct AdaptiveLayoutTests {
    @Test("iPad 全局强制锁定横屏方向掩码，iPhone 保留会话方向偏好")
    func iPadForcesLandscapeOrientationMask() {
        #expect(SessionOrientationLock.resolvedMask(for: .auto, isPad: true) == .landscape)
        #expect(SessionOrientationLock.resolvedMask(for: .landscape, isPad: true) == .landscape)
        #expect(SessionOrientationLock.resolvedMask(for: .portrait, isPad: true) == .landscape)

        #expect(SessionOrientationLock.resolvedMask(for: .auto, isPad: false) == .allButUpsideDown)
        #expect(SessionOrientationLock.resolvedMask(for: .landscape, isPad: false) == .landscape)
        #expect(SessionOrientationLock.resolvedMask(for: .portrait, isPad: false) == .portrait)
    }

    @Test("仅 regular 水平尺寸类启用 iPad 工作台分栏框架，窄分屏自动回退手机布局")
    func workspaceSplitFollowsHorizontalSizeClass() {
        #expect(RCLayout.usesWorkspaceSplit(.regular) == true)
        #expect(RCLayout.usesWorkspaceSplit(.compact) == false)
        #expect(RCLayout.usesWorkspaceSplit(nil) == false)
    }

    @Test("登录页在 iPad 横竖屏与 iPhone 横屏启用双栏，无障碍超大字号回退单栏")
    func loginTwoColumnBreakpoints() {
        // iPad 11 寸竖屏
        #expect(
            RCLayout.prefersTwoColumnLogin(
                horizontalSizeClass: .regular,
                verticalSizeClass: .regular,
                viewportSize: CGSize(width: 834, height: 1194),
                isAccessibilityType: false
            ) == true
        )
        // iPad 1/3 Split View 窄窗
        #expect(
            RCLayout.prefersTwoColumnLogin(
                horizontalSizeClass: .compact,
                verticalSizeClass: .regular,
                viewportSize: CGSize(width: 375, height: 834),
                isAccessibilityType: false
            ) == false
        )
        // iPhone 横屏
        #expect(
            RCLayout.prefersTwoColumnLogin(
                horizontalSizeClass: .compact,
                verticalSizeClass: .compact,
                viewportSize: CGSize(width: 852, height: 393),
                isAccessibilityType: false
            ) == true
        )
        // 无障碍字号强制单列防截断
        #expect(
            RCLayout.prefersTwoColumnLogin(
                horizontalSizeClass: .regular,
                verticalSizeClass: .regular,
                viewportSize: CGSize(width: 1194, height: 834),
                isAccessibilityType: true
            ) == false
        )
    }

    @Test("远程协助页根据内容区实际宽度切换双栏与堆叠")
    func assistTwoColumnFollowsContainerWidth() {
        #expect(
            RCLayout.prefersTwoColumnAssist(
                verticalSizeClass: .regular,
                containerWidth: 960,
                isAccessibilityType: false
            ) == true
        )
        #expect(
            RCLayout.prefersTwoColumnAssist(
                verticalSizeClass: .regular,
                containerWidth: 608,
                isAccessibilityType: false
            ) == false
        )
    }

    @Test("远控会话分屏触控板仅在竖屏视口生效，iPad 横屏绝不误触发")
    func sessionSplitTrackpadDoesNotFireInIPadLandscape() {
        // iPad 横屏：verticalSizeClass 仍为 .regular，但 width > height，不应弹出竖屏触控板分屏栏
        #expect(
            RCLayout.shouldUseSessionSplitTrackpad(
                portraitLayout: .auto,
                touchMode: .trackpad,
                watchOnly: false,
                verticalSizeClass: .regular,
                viewportSize: CGSize(width: 1194, height: 834)
            ) == false
        )
        #expect(
            RCLayout.shouldUseSessionSplitTrackpad(
                portraitLayout: .splitTrackpad,
                touchMode: .directTouch,
                watchOnly: false,
                verticalSizeClass: .regular,
                viewportSize: CGSize(width: 1194, height: 834)
            ) == false
        )
        // iPhone / iPad 竖屏视口：触控板模式下自动启用上下分屏
        #expect(
            RCLayout.shouldUseSessionSplitTrackpad(
                portraitLayout: .auto,
                touchMode: .trackpad,
                watchOnly: false,
                verticalSizeClass: .regular,
                viewportSize: CGSize(width: 393, height: 852)
            ) == true
        )
        // 仅查看模式始终全屏
        #expect(
            RCLayout.shouldUseSessionSplitTrackpad(
                portraitLayout: .splitTrackpad,
                touchMode: .trackpad,
                watchOnly: true,
                verticalSizeClass: .regular,
                viewportSize: CGSize(width: 834, height: 1194)
            ) == false
        )
    }

    @Test("会话右侧工具抽屉与单行键盘扩展条按实时舞台宽度自适应")
    func sessionSideInspectorAndKeyboardBarBreakpoints() {
        #expect(
            RCLayout.prefersSessionSideInspector(
                horizontalSizeClass: .regular,
                viewportSize: CGSize(width: 1194, height: 834)
            ) == true
        )
        #expect(
            RCLayout.prefersSessionSideInspector(
                horizontalSizeClass: .regular,
                viewportSize: CGSize(width: 580, height: 834)
            ) == false
        )
        // iPad 横屏展开右侧抽屉后左侧舞台仍有 ~818pt，保持单行胶囊键盘条
        #expect(
            RCLayout.prefersSingleRowKeyboardBar(
                verticalSizeClass: .regular,
                availableWidth: 818
            ) == true
        )
        // iPad 竖屏展开右侧抽屉后左侧舞台缩窄至 ~500pt，自动切换双行面板避免截断按键
        #expect(
            RCLayout.prefersSingleRowKeyboardBar(
                verticalSizeClass: .regular,
                availableWidth: 500
            ) == false
        )
    }

    @MainActor
    @Test("设备缩略图在 16:9、21:9 超宽与 9:16 竖屏截图下均严格锁死 16:10 容器尺寸，绝不撑破详情布局")
    func devicePreviewNeverExpandsParentContainerWithThumbnails() {
        let sampleDevice = MockData.devices[0]
        let sampleSizes = [
            CGSize(width: 1920, height: 1080), // 16:9 标准桌面
            CGSize(width: 3440, height: 1440), // 21:9 带鱼屏
            CGSize(width: 1080, height: 1920), // 9:16 竖屏副屏
        ]

        for imgSize in sampleSizes {
            let renderer = UIGraphicsImageRenderer(size: imgSize)
            let image = renderer.image { ctx in
                UIColor.systemBlue.setFill()
                ctx.fill(CGRect(origin: .zero, size: imgSize))
            }

            for fullDesktop in [false, true] {
                let probe = VStack(spacing: 0) {
                    DevicePreview(
                        device: sampleDevice,
                        showsCaption: true,
                        fitsFullDesktop: fullDesktop,
                        overrideImage: image
                    )
                    .frame(maxWidth: .infinity)
                    .aspectRatio(16.0 / 10.0, contentMode: .fit)
                }
                let host = UIHostingController(rootView: probe)
                let measured = host.sizeThatFits(in: CGSize(width: 578, height: 1000))
                #expect(abs(measured.width - 578) < 1.0)
                #expect(abs(measured.height - 361.25) < 1.0)
            }
        }
    }
}
