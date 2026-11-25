import SwiftUI
import UIKit

/// 精密触控输入层:原始多点触控事件驱动的手势状态机。
/// - 触控板模式:单指相对移动(非线性加速)、轻点左键、二次触按拖动、双指轻点右键、
///   双指惯性滚动、三指拖动、双指捏合缩放。
/// - 直触模式:绝对坐标映射+可选指尖偏置,拖动即左键拖拽,长按右键,双指滚动/缩放。
final class TouchInputUIView: UIView {
    var inputMode: TouchInputMode = .directTouch
    var sensitivity: CGFloat = 1.15
    var naturalScroll = true
    var watchOnly = false {
        didSet { if watchOnly { cancelAll() } }
    }
    /// 竖屏分屏纯触控板:整个视图都是触控板,不做捏合缩放。
    var trackpadOnly = false
    var zoomPan: ZoomPanState?
    private var viewportSize: CGSize { bounds.size }

    var onMove: (Double, Double) -> Void = { _, _ in }
    var onButton: (String, Bool) -> Void = { _, _ in }
    var onWheel: (Int, Bool) -> Void = { _, _ in }

    private enum Phase {
        case idle
        case oneFingerPending      // 单指刚按下,等待判定
        case trackpadMove          // 触控板相对移动
        case trackpadDrag          // 触控板按住拖动
        case directPending         // 直触按下,未越过阈值
        case directDrag            // 直触拖拽(左键按住)
        case twoFingerPending      // 双指刚落下,等待判定滚动/捏合/轻点
        case twoFingerScroll       // 双指滚动
        case pinchZoom             // 双指捏合缩放
        case threeFingerDrag       // 三指拖动
        case consumed              // 本次触控序列已消费(如长按右键后)
    }

    private var phase: Phase = .idle
    private var cursor = CGPoint(x: 0.5, y: 0.5)   // 触控板虚拟光标(归一化)
    private var leftHeld = false
    private var primary: UITouch?
    private var downAt: TimeInterval = 0
    private var downPoint = CGPoint.zero
    private var lastPoint = CGPoint.zero
    private var lastMoveAt: TimeInterval = 0
    private var lastTapAt: TimeInterval = 0        // 上次轻点结束时刻,用于二次触按拖动
    private var twoStart = CGPoint.zero            // 双指质心起点
    private var twoLastCenter = CGPoint.zero
    private var twoStartSpan: CGFloat = 0
    private var twoDownAt: TimeInterval = 0
    private var twoMoved = false
    private var scrollAccum = CGPoint.zero
    private var scrollVelocity = CGPoint.zero
    private var inertiaLink: CADisplayLink?
    private var baseScale: CGFloat = 1
    private var longPressWork: DispatchWorkItem?

    private let slop: CGFloat = 9
    private let tapDuration: TimeInterval = 0.26
    private let doubleTapWindow: TimeInterval = 0.3
    private let longPressDelay: TimeInterval = 0.55
    private let scrollNotch: CGFloat = 34           // 每多少点滚动换算一格滚轮

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        isUserInteractionEnabled = true
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - 坐标映射

    /// 视图坐标 → 远端归一化坐标(直触:按缩放/平移反算;触控板:虚拟光标)。
    private func normalized(for point: CGPoint) -> CGPoint {
        guard let zoomPan, viewportSize.width > 0 else { return cursor }
        return zoomPan.normalizedPoint(for: point, in: viewportSize)
    }

    private func sendMove(_ p: CGPoint) {
        onMove(Double(p.x), Double(p.y))
    }

    private func pressLeft(_ down: Bool) {
        guard leftHeld != down else { return }
        leftHeld = down
        onButton("left", down)
    }

    private func click(_ button: String) {
        onButton(button, true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.onButton(button, false)
        }
    }

    private func cancelAll() {
        cancelLongPress()
        if leftHeld { pressLeft(false) }
        phase = .idle
        primary = nil
        stopInertia()
    }

    // MARK: - 触控事件

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard !watchOnly else { return }
        let count = event?.allTouches?.count ?? touches.count
        if count >= 3 {
            // 三指拖动:松开双指状态,直接按住左键拖动
            cancelLongPress()
            stopInertia()
            if phase != .threeFingerDrag {
                phase = .threeFingerDrag
                if let t = touches.first {
                    lastPoint = t.location(in: self)
                    lastMoveAt = t.timestamp
                }
                if inputMode == .directTouch, let t = touches.first {
                    sendMove(normalized(for: t.location(in: self)))
                }
                pressLeft(true)
            }
            return
        }
        if count == 2 {
            // 双指:取消单指判定,进入滚动/捏合判定
            cancelLongPress()
            if phase == .trackpadDrag || phase == .directDrag { pressLeft(false) }
            if phase == .trackpadMove || phase == .directPending || phase == .oneFingerPending {
                phase = .twoFingerPending
                twoDownAt = touches.first?.timestamp ?? 0
                twoMoved = false
                scrollAccum = .zero
                if let pair = twoCentroid(event) {
                    twoStart = pair.center
                    twoLastCenter = pair.center
                    twoStartSpan = pair.span
                    baseScale = zoomPan?.scale ?? 1
                }
            }
            return
        }
        guard count == 1, let touch = touches.first else { return }
        primary = touch
        downAt = touch.timestamp
        downPoint = touch.location(in: self)
        lastPoint = downPoint
        lastMoveAt = touch.timestamp
        phase = inputMode == .trackpad || trackpadOnly ? .oneFingerPending : .directPending
        scheduleLongPress()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard !watchOnly else { return }
        let count = event?.allTouches?.count ?? 1
        switch phase {
        case .oneFingerPending:
            guard let touch = primary, touches.contains(touch) else { return }
            let p = touch.location(in: self)
            if hypot(p.x - downPoint.x, p.y - downPoint.y) > slop {
                cancelLongPress()
                // 轻点后短时间内再次触按并移动 → 拖动
                let isDragStart = touch.timestamp - lastTapAt < doubleTapWindow
                phase = isDragStart ? .trackpadDrag : .trackpadMove
                if isDragStart {
                    sendMove(cursor)
                    pressLeft(true)
                }
                lastPoint = p
                lastMoveAt = touch.timestamp
            }
        case .trackpadMove, .trackpadDrag, .threeFingerDrag:
            guard let touch = touches.first else { return }
            let p = touch.location(in: self)
            let dt = max(touch.timestamp - lastMoveAt, 0.001)
            var dx = p.x - lastPoint.x
            var dy = p.y - lastPoint.y
            lastPoint = p
            lastMoveAt = touch.timestamp
            if inputMode == .directTouch && phase != .trackpadDrag && phase != .trackpadMove && !trackpadOnly {
                // 直触三指拖动:绝对映射
                sendMove(normalized(for: p))
            } else {
                // 非线性加速:速度越快增益越大
                let speed = hypot(dx, dy) / dt
                let gain = sensitivity * (1 + min(speed / 900, 1.2))
                dx *= gain; dy *= gain
                let rect = zoomPan?.videoRect(in: viewportSize) ?? CGRect(origin: .zero, size: viewportSize)
                let scaleX = max(rect.width, 1)
                let scaleY = max(rect.height, 1)
                cursor.x = min(max(cursor.x + dx / scaleX, 0), 1)
                cursor.y = min(max(cursor.y + dy / scaleY, 0), 1)
                sendMove(cursor)
            }
        case .directPending:
            guard let touch = primary, touches.contains(touch) else { return }
            let p = touch.location(in: self)
            if hypot(p.x - downPoint.x, p.y - downPoint.y) > slop {
                cancelLongPress()
                phase = .directDrag
                sendMove(normalized(for: p))
                pressLeft(true)
                lastPoint = p
            }
        case .directDrag:
            guard let touch = primary, touches.contains(touch) else { return }
            sendMove(normalized(for: touch.location(in: self)))
        case .twoFingerPending, .twoFingerScroll, .pinchZoom:
            guard count >= 2, let pair = twoCentroid(event) else { return }
            let centerDelta = CGPoint(x: pair.center.x - twoLastCenter.x, y: pair.center.y - twoLastCenter.y)
            twoLastCenter = pair.center
            let spanDelta = pair.span - twoStartSpan
            if phase == .twoFingerPending {
                if !trackpadOnly, abs(spanDelta) > 12 {
                    phase = .pinchZoom
                    twoMoved = true
                } else if hypot(pair.center.x - twoStart.x, pair.center.y - twoStart.y) > slop {
                    phase = .twoFingerScroll
                    twoMoved = true
                }
            }
            if phase == .pinchZoom, let zoomPan {
                zoomPan.scale = min(8, max(1, baseScale * pair.span / max(twoStartSpan, 1)))
                if zoomPan.scale == 1 { zoomPan.pan = .zero }
                else {
                    zoomPan.pan = CGPoint(x: zoomPan.pan.x + centerDelta.x, y: zoomPan.pan.y + centerDelta.y)
                }
            } else if phase == .twoFingerScroll {
                scrollAccum.x += centerDelta.x
                scrollAccum.y += centerDelta.y
                scrollVelocity = centerDelta
                emitScroll()
            }
        default:
            break
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        let remaining = (event?.allTouches?.count ?? 0) - touches.count
        switch phase {
        case .oneFingerPending:
            cancelLongPress()
            if let touch = primary, touch.timestamp - downAt < tapDuration {
                click("left")
                lastTapAt = touch.timestamp
            }
            phase = .idle
        case .directPending:
            cancelLongPress()
            if let touch = primary, touch.timestamp - downAt < tapDuration {
                sendMove(normalized(for: touch.location(in: self)))
                click("left")
            }
            phase = .idle
        case .trackpadMove:
            phase = remaining > 0 ? phase : .idle
        case .trackpadDrag, .directDrag, .threeFingerDrag:
            pressLeft(false)
            phase = .idle
        case .twoFingerPending:
            // 双指轻点右键
            if !twoMoved, let t = touches.first, t.timestamp - twoDownAt < tapDuration {
                if inputMode == .directTouch, !trackpadOnly {
                    sendMove(normalized(for: twoStart))
                }
                click("right")
            }
            phase = remaining > 0 ? .consumed : .idle
        case .twoFingerScroll:
            if remaining <= 0 {
                startInertia()
                phase = .idle
            }
        case .pinchZoom:
            if remaining <= 0 { phase = .idle }
        case .consumed:
            if remaining <= 0 { phase = .idle }
        default:
            if remaining <= 0 { phase = .idle }
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        cancelAll()
    }

    // MARK: - 手势细节

    private func scheduleLongPress() {
        cancelLongPress()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.phase == .oneFingerPending || self.phase == .directPending else { return }
            if self.inputMode == .directTouch, !self.trackpadOnly, let touch = self.primary {
                self.sendMove(self.normalized(for: touch.location(in: self)))
            }
            self.click("right")
            self.phase = .consumed
        }
        longPressWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + longPressDelay, execute: work)
    }

    private func cancelLongPress() {
        longPressWork?.cancel()
        longPressWork = nil
    }

    private func twoCentroid(_ event: UIEvent?) -> (center: CGPoint, span: CGFloat)? {
        guard let all = event?.allTouches, all.count >= 2 else { return nil }
        let pts = all.prefix(2).map { $0.location(in: self) }
        let center = CGPoint(x: (pts[0].x + pts[1].x) / 2, y: (pts[0].y + pts[1].y) / 2)
        let span = hypot(pts[0].x - pts[1].x, pts[0].y - pts[1].y)
        return (center, span)
    }

    private func emitScroll() {
        let sign: CGFloat = naturalScroll ? -1 : 1
        while abs(scrollAccum.y) >= scrollNotch {
            let notch = scrollAccum.y > 0 ? 1 : -1
            onWheel(Int(sign) * notch, false)
            scrollAccum.y -= CGFloat(notch) * scrollNotch
        }
        while abs(scrollAccum.x) >= scrollNotch {
            let notch = scrollAccum.x > 0 ? 1 : -1
            onWheel(Int(sign) * notch, true)
            scrollAccum.x -= CGFloat(notch) * scrollNotch
        }
    }

    private func startInertia() {
        guard hypot(scrollVelocity.x, scrollVelocity.y) > 3 else { return }
        stopInertia()
        let link = CADisplayLink(target: self, selector: #selector(inertiaStep))
        link.add(to: .main, forMode: .common)
        inertiaLink = link
    }

    @objc private func inertiaStep() {
        scrollVelocity.x *= 0.9
        scrollVelocity.y *= 0.9
        if hypot(scrollVelocity.x, scrollVelocity.y) < 0.4 {
            stopInertia()
            return
        }
        scrollAccum.x += scrollVelocity.x
        scrollAccum.y += scrollVelocity.y
        emitScroll()
    }

    private func stopInertia() {
        inertiaLink?.invalidate()
        inertiaLink = nil
    }
}

/// SwiftUI 包装:覆盖在视频层之上的透明触控层。
struct TouchInputView: UIViewRepresentable {
    var session: SessionService
    var zoomPan: ZoomPanState
    var watchOnly: Bool
    var trackpadOnly = false

    private var prefs: InteractionPrefs { .shared }

    func makeUIView(context: Context) -> TouchInputUIView {
        TouchInputUIView()
    }

    func updateUIView(_ view: TouchInputUIView, context: Context) {
        view.inputMode = trackpadOnly ? .trackpad : prefs.touchMode
        view.sensitivity = prefs.pointerSensitivity
        view.naturalScroll = prefs.naturalScroll
        view.watchOnly = watchOnly
        view.trackpadOnly = trackpadOnly
        view.zoomPan = zoomPan
        view.onMove = { [weak session] nx, ny in session?.sendMouseMove(nx: nx, ny: ny) }
        view.onButton = { [weak session] button, pressed in session?.sendMouseButton(button: button, pressed: pressed) }
        view.onWheel = { [weak session] delta, horizontal in session?.sendWheel(delta: delta, horizontal: horizontal) }
    }
}
