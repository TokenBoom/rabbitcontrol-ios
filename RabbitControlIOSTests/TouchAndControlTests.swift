import CoreGraphics
import Foundation
import Testing
import UIKit
@testable import RabbitControlIOS

@MainActor
struct TouchAndControlTests {
    enum RecordedEvent: Equatable {
        case move(Double, Double)
        case button(String, Bool)
        case click(String)
        case wheel(Int, Bool)
    }

    private func makeConfiguredView(
        mode: TouchInputMode = .directTouch,
        scale: CGFloat = 1.0,
        trackpadOnly: Bool = false
    ) -> (TouchInputUIView, ZoomPanState) {
        let zoom = ZoomPanState()
        zoom.videoSize = CGSize(width: 2000, height: 1000)
        zoom.scale = scale
        let view = TouchInputUIView(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
        view.layoutIfNeeded()
        view.zoomPan = zoom
        view.inputMode = mode
        view.trackpadOnly = trackpadOnly
        return (view, zoom)
    }

    @Test("直触模式长按震动后滑动触发左键拖拽，在 1x 与放大态下均精确从按下起点拖起且不误发右键")
    func directTouchLongPressThenMoveDragsAtAnyScale() {
        for scale in [CGFloat(1.0), CGFloat(2.5)] {
            let (view, _) = makeConfiguredView(mode: .directTouch, scale: scale)
            var events: [RecordedEvent] = []
            view.onMove = { events.append(.move($0, $1)) }
            view.onButton = { events.append(.button($0, $1)) }
            view.onClick = { events.append(.click($0)) }

            let downPt = CGPoint(x: 100, y: 80)
            let dragPt1 = CGPoint(x: 140, y: 110)
            let dragPt2 = CGPoint(x: 200, y: 130)

            view.handleTouchesBegan([.init(id: 1, location: downPt, timestamp: 1.0)])
            // 模拟长按定时器触发震动就绪：此时不应提前发出右键点击
            view.fireScheduledLongPressIfPending()
            #expect(!events.contains(.click("right")))

            // 长按就绪后滑动手指 → 先定位按下起点，按下左键，再移动至目标点
            view.handleTouchesMoved([.init(id: 1, location: dragPt1, timestamp: 1.48)])
            view.handleTouchesMoved([.init(id: 1, location: dragPt2, timestamp: 1.56)])
            view.handleTouchesEnded([.init(id: 1, location: dragPt2, timestamp: 1.65)])

            #expect(!events.contains(.click("right")))
            #expect(!events.contains(.click("left")))
            let leftDownIdx = events.firstIndex(of: .button("left", true))
            let leftUpIdx = events.firstIndex(of: .button("left", false))
            #expect(leftDownIdx != nil && leftUpIdx != nil)
            if let downIdx = leftDownIdx, let upIdx = leftUpIdx {
                #expect(downIdx >= 1, "按下左键前应先将指针移动到精确按下起点")
                #expect(upIdx == events.count - 1)
                if case .move(let startX, let startY) = events[0], scale == 1.0 {
                    #expect(abs(startX - 0.25) < 1e-4 && abs(startY - 0.40) < 1e-4)
                }
            }
        }
    }

    @Test("按住微停顿(>=0.26s)后滑动在直触与触控板模式下均直接进入长按拖拽")
    func briefHoldBeforeSlideTriggersLeftDragInBothModes() {
        for mode in [TouchInputMode.directTouch, TouchInputMode.trackpad] {
            let (view, _) = makeConfiguredView(mode: mode)
            var buttons: [(String, Bool)] = []
            var moveCount = 0
            view.onMove = { _, _ in moveCount += 1 }
            view.onButton = { buttons.append(($0, $1)) }

            view.handleTouchesBegan([.init(id: 1, location: CGPoint(x: 120, y: 100), timestamp: 2.00)])
            view.handleTouchesMoved([.init(id: 1, location: CGPoint(x: 160, y: 120), timestamp: 2.30)])
            view.handleTouchesMoved([.init(id: 1, location: CGPoint(x: 210, y: 140), timestamp: 2.36)])
            view.handleTouchesEnded([.init(id: 1, location: CGPoint(x: 210, y: 140), timestamp: 2.42)])

            #expect(buttons.count == 2)
            #expect(buttons[0].0 == "left" && buttons[0].1 == true)
            #expect(buttons[1].0 == "left" && buttons[1].1 == false)
            #expect(moveCount >= 2)
        }
    }

    @Test("长按震动后原地松手触发右键；中等时长(<0.40s)原地松手正常触发左键无死区")
    func longPressReleaseRightClicksAndMediumTapLeftClicks() {
        let (view, _) = makeConfiguredView(mode: .directTouch)
        var clicks: [String] = []
        view.onClick = { clicks.append($0) }

        // 0.33s 稍慢轻点（旧逻辑 >0.26s 会被静默吞掉）→ 正常触发左键
        view.handleTouchesBegan([.init(id: 1, location: CGPoint(x: 80, y: 60), timestamp: 1.00)])
        view.handleTouchesEnded([.init(id: 1, location: CGPoint(x: 82, y: 61), timestamp: 1.33)])
        #expect(clicks == ["left"])

        // 长按就绪后原地松手 → 触发右键
        view.handleTouchesBegan([.init(id: 2, location: CGPoint(x: 180, y: 90), timestamp: 2.00)])
        view.fireScheduledLongPressIfPending()
        view.handleTouchesEnded([.init(id: 2, location: CGPoint(x: 182, y: 91), timestamp: 2.55)])
        #expect(clicks == ["left", "right"])
    }

    @Test("直触模式双击微偏自动吸附至首击精确坐标，远距离快点不误吸附")
    func directTouchDoubleTapSnapsWithinRadius() {
        let (view, _) = makeConfiguredView(mode: .directTouch)
        var moves: [(Double, Double)] = []
        var clicks: [String] = []
        view.onMove = { moves.append(($0, $1)) }
        view.onClick = { clicks.append($0) }

        // 第一击: (200, 100) -> (0.5, 0.5)
        view.handleTouchesBegan([.init(id: 1, location: CGPoint(x: 200, y: 100), timestamp: 5.00)])
        view.handleTouchesEnded([.init(id: 1, location: CGPoint(x: 200, y: 100), timestamp: 5.06)])

        // 第二击手指微偏 8pt: (206, 105)，双击窗口内应吸附回 (0.5, 0.5)
        view.handleTouchesBegan([.init(id: 2, location: CGPoint(x: 206, y: 105), timestamp: 5.20)])
        view.handleTouchesEnded([.init(id: 2, location: CGPoint(x: 206, y: 105), timestamp: 5.25)])

        #expect(clicks == ["left", "left"])
        #expect(moves.count == 2)
        #expect(abs(moves[0].0 - 0.5) < 1e-6 && abs(moves[0].1 - 0.5) < 1e-6)
        #expect(abs(moves[1].0 - 0.5) < 1e-6 && abs(moves[1].1 - 0.5) < 1e-6)

        // 第三击距离超过双击半径 (320, 40) -> 正常点击新位置
        view.handleTouchesBegan([.init(id: 3, location: CGPoint(x: 320, y: 40), timestamp: 5.38)])
        view.handleTouchesEnded([.init(id: 3, location: CGPoint(x: 320, y: 40), timestamp: 5.42)])
        #expect(abs(moves[2].0 - 0.8) < 1e-6 && abs(moves[2].1 - 0.2) < 1e-6)
    }

    @Test("直触 1x 快速滑动悬停移鼠不误触点击，放大态快速滑动平移画布")
    func directTouchQuickSlideHoversAt1xAndPansWhenZoomed() {
        let (view1x, _) = makeConfiguredView(mode: .directTouch, scale: 1.0)
        var moves1x = 0
        var buttons1x = 0
        view1x.onMove = { _, _ in moves1x += 1 }
        view1x.onButton = { _, _ in buttons1x += 1 }
        view1x.onClick = { _ in buttons1x += 1 }

        view1x.handleTouchesBegan([.init(id: 1, location: CGPoint(x: 100, y: 100), timestamp: 1.00)])
        view1x.handleTouchesMoved([.init(id: 1, location: CGPoint(x: 150, y: 100), timestamp: 1.05)])
        view1x.handleTouchesEnded([.init(id: 1, location: CGPoint(x: 150, y: 100), timestamp: 1.10)])
        #expect(moves1x >= 1 && buttons1x == 0)

        let (viewZoomed, zoom) = makeConfiguredView(mode: .directTouch, scale: 2.0)
        var movesZoom = 0
        viewZoomed.onMove = { _, _ in movesZoom += 1 }
        viewZoomed.handleTouchesBegan([.init(id: 2, location: CGPoint(x: 200, y: 100), timestamp: 2.00)])
        viewZoomed.handleTouchesMoved([.init(id: 2, location: CGPoint(x: 240, y: 120), timestamp: 2.05)])
        viewZoomed.handleTouchesEnded([.init(id: 2, location: CGPoint(x: 240, y: 120), timestamp: 2.10)])
        #expect(movesZoom == 0)
        #expect(zoom.pan.x > 0 && zoom.pan.y > 0)
    }

    @Test("双指自然滚动方向与传统滚动方向正确，且直触滚动前先将光标移至双指中心")
    func twoFingerScrollDirectionAndCursorPrePositioning() {
        let (view, _) = makeConfiguredView(mode: .directTouch)
        var moves: [(Double, Double)] = []
        var wheels: [Int] = []
        view.onMove = { moves.append(($0, $1)) }
        view.onWheel = { delta, horiz in if !horiz { wheels.append(delta) } }

        // 自然滚动开启：双指向上推 (y: 140 -> 60) 应向下浏览页面，发送负滚轮值 (delta < 0)
        view.naturalScroll = true
        view.handleTouchesBegan([
            .init(id: 1, location: CGPoint(x: 280, y: 140), timestamp: 1.00),
            .init(id: 2, location: CGPoint(x: 320, y: 140), timestamp: 1.00),
        ])
        view.handleTouchesMoved([
            .init(id: 1, location: CGPoint(x: 280, y: 120), timestamp: 1.04),
            .init(id: 2, location: CGPoint(x: 320, y: 120), timestamp: 1.04),
        ])
        view.handleTouchesMoved([
            .init(id: 1, location: CGPoint(x: 280, y: 70), timestamp: 1.08),
            .init(id: 2, location: CGPoint(x: 320, y: 70), timestamp: 1.08),
        ])
        view.handleTouchesEnded([
            .init(id: 1, location: CGPoint(x: 280, y: 70), timestamp: 1.12),
            .init(id: 2, location: CGPoint(x: 320, y: 70), timestamp: 1.12),
        ])
        view.cancelAll()

        #expect(!moves.isEmpty, "直触双指滚动前应先将指针移至双指中心 (300, 140)")
        if let firstMove = moves.first {
            #expect(abs(firstMove.0 - 0.75) < 1e-4 && abs(firstMove.1 - 0.70) < 1e-4)
        }
        #expect(!wheels.isEmpty && wheels.allSatisfy { $0 < 0 })

        // 关闭自然滚动：同样双指向上推应发送正滚轮值 (delta > 0)
        wheels.removeAll()
        view.naturalScroll = false
        view.handleTouchesBegan([
            .init(id: 3, location: CGPoint(x: 200, y: 140), timestamp: 2.00),
            .init(id: 4, location: CGPoint(x: 240, y: 140), timestamp: 2.00),
        ])
        view.handleTouchesMoved([
            .init(id: 3, location: CGPoint(x: 200, y: 120), timestamp: 2.04),
            .init(id: 4, location: CGPoint(x: 240, y: 120), timestamp: 2.04),
        ])
        view.handleTouchesMoved([
            .init(id: 3, location: CGPoint(x: 200, y: 70), timestamp: 2.08),
            .init(id: 4, location: CGPoint(x: 240, y: 70), timestamp: 2.08),
        ])
        view.cancelAll()
        #expect(!wheels.isEmpty && wheels.allSatisfy { $0 > 0 })
    }

    @Test("触控板三指交替微动按质心平滑推进，不因多指切换产生光标瞬移")
    func threeFingerDragUsesCentroidWithoutJump() {
        let (view, _) = makeConfiguredView(mode: .trackpad, trackpadOnly: true)
        var xs: [Double] = []
        view.onMove = { x, _ in xs.append(x) }

        view.handleTouchesBegan([
            .init(id: 1, location: CGPoint(x: 60, y: 100), timestamp: 1.00),
            .init(id: 2, location: CGPoint(x: 160, y: 100), timestamp: 1.00),
            .init(id: 3, location: CGPoint(x: 260, y: 100), timestamp: 1.00),
        ])
        // 第 1 帧仅手指 1 微移 +9pt，第 2 帧仅手指 3 微移 +9pt（质心每帧仅 +3pt）
        view.handleTouchesMoved([.init(id: 1, location: CGPoint(x: 69, y: 100), timestamp: 1.02)])
        view.handleTouchesMoved([.init(id: 3, location: CGPoint(x: 269, y: 100), timestamp: 1.04)])
        view.handleTouchesEnded([
            .init(id: 1, location: CGPoint(x: 69, y: 100), timestamp: 1.08),
            .init(id: 2, location: CGPoint(x: 160, y: 100), timestamp: 1.08),
            .init(id: 3, location: CGPoint(x: 269, y: 100), timestamp: 1.08),
        ])

        #expect(xs.count >= 3)
        for i in 1..<xs.count {
            let step = xs[i] - xs[i - 1]
            #expect(step >= 0 && step < 0.08, "三指质心单步增量应平滑无反向跳变: \(xs)")
        }
    }

    @Test("SessionService 单击 35ms 定时器绝不误释放紧随其后的双击拖拽，且支持快速连点左键与拖拽锁")
    func sessionServiceClickReleaseNeverCancelsSubsequentDragOrFastDoubleClick() async throws {
        let session = SessionService.shared
        var payloads: [[String: Any]] = []
        session.close()
        session.inputTestSink = { payloads.append($0) }
        defer {
            session.releasePressedInput()
            session.inputTestSink = nil
        }

        // 1. 轻点左键后 10ms 内立即发起二次触按拖拽（按住左键）
        session.clickMouse("left")
        try await Task.sleep(for: .milliseconds(10))
        session.sendMouseButton(button: "left", pressed: true)

        // 等待超过原 35ms/50ms 单击释放窗口，验证左键依然稳固处于按下状态！
        try await Task.sleep(for: .milliseconds(65))
        #expect(session.isLeftMouseHeld == true)
        #expect(session.isSustainedLeftHold == true)

        session.sendMouseButton(button: "left", pressed: false)
        #expect(session.isLeftMouseHeld == false)

        let buttonSeq = payloads.compactMap { item -> Bool? in
            guard item["kind"] as? String == "mouse_button",
                  item["button"] as? String == "left" else { return nil }
            return item["pressed"] as? Bool
        }
        // 严格顺序: 单击按下 → 立即冲刷抬起 → 拖拽按下 → 拖拽结束抬起
        #expect(buttonSeq == [true, false, true, false])

        // 2. 极速双击「左键」按钮（间隔 5ms）不应被误判为释放拖拽锁而吞掉第二击
        payloads.removeAll()
        session.clickMouse("left")
        try await Task.sleep(for: .milliseconds(5))
        session.clickMouse("left")
        try await Task.sleep(for: .milliseconds(60))

        let doubleClickSeq = payloads.compactMap { item -> Bool? in
            guard item["kind"] as? String == "mouse_button",
                  item["button"] as? String == "left" else { return nil }
            return item["pressed"] as? Bool
        }
        #expect(doubleClickSeq == [true, false, true, false])

        // 3. 显式开启「拖拽锁定」后单击左键应解锁释放
        payloads.removeAll()
        session.toggleLeftMouseHold()
        #expect(session.isDragLocked && session.isSustainedLeftHold)
        session.clickMouse("left")
        #expect(!session.isDragLocked && !session.isLeftMouseHeld)
    }

    @Test("修饰键锁存同步作用于鼠标点击/拖拽，且切入观看模式时可靠释放所有在途按键")
    func modifierLatchSyncsWithMouseAndReleasesOnWatchOnly() async throws {
        let session = SessionService.shared
        var payloads: [[String: Any]] = []
        session.close()
        session.inputTestSink = { payloads.append($0) }
        defer {
            session.setWatchOnly(false)
            session.releasePressedInput()
            session.inputTestSink = nil
        }

        // 单击 Command(0xe05b) 进入 sticky → 执行鼠标左键点击 → 点击抬起后自动释放 Command
        session.toggleModifier(0xe05b, now: 10.0)
        #expect(session.modifierLatch.mode(for: 0xe05b) == .sticky)
        session.clickMouse("left")
        try await Task.sleep(for: .milliseconds(60))
        #expect(session.modifierLatch.mode(for: 0xe05b) == nil)

        let cmdEvents = payloads.compactMap { item -> Bool? in
            guard item["kind"] as? String == "key",
                  (item["scancode"] as? UInt16) == 0xe05b else { return nil }
            return item["pressed"] as? Bool
        }
        #expect(cmdEvents == [true, false])

        // 双击 Shift(0x2a) 进入常驻 locked，再按住左键时切入观看模式 → 两者均须发送抬起事件
        payloads.removeAll()
        session.toggleModifier(0x2a, now: 20.0)
        session.toggleModifier(0x2a, now: 20.15)
        #expect(session.modifierLatch.mode(for: 0x2a) == .locked)
        session.sendMouseButton(button: "left", pressed: true)

        session.setWatchOnly(true)
        let releasedLeft = payloads.contains {
            $0["kind"] as? String == "mouse_button" && ($0["pressed"] as? Bool) == false
        }
        let releasedShift = payloads.contains {
            $0["kind"] as? String == "key"
                && ($0["scancode"] as? UInt16) == 0x2a
                && ($0["pressed"] as? Bool) == false
        }
        #expect(releasedLeft && releasedShift)
    }

    @Test("iOS 智能标点归一化与双平台快捷键判别")
    func smartPunctuationAndPlatformShortcuts() {
        let smart = RemoteKeys.strokes(for: "“hi”—it’s")
        let ascii = RemoteKeys.strokes(for: "\"hi\"-it's")
        #expect(smart != nil && smart == ascii)

        let session = SessionService.shared
        #expect(session.prefersPCShortcuts(deviceKind: .windows) == true)
        #expect(session.prefersPCShortcuts(deviceKind: .mac) == false)
    }
}
