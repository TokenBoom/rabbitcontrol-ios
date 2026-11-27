import SwiftUI
import UIKit

/// 精密触控输入层:原始多点触控事件驱动的手势状态机。
/// - 触控板模式:单指相对移动(非线性加速)、轻点左键、长按后滑动拖拽、二次触按拖拽、
///   长按原地松手或双指轻点右键、双指自然/传统惯性滚动、三指质心拖动、双指锚点捏合缩放。
/// - 直触模式:绝对坐标精确映射(双击落点防抖吸附)、1x 快速滑动悬停移鼠、放大态快速滑动平移画布、
///   长按后滑动/双击后滑动/三指滑动为左键拖拽、长按原地松手或双指轻点右键、双指就地滚轮/捏合缩放。
final class TouchInputUIView: UIView {
    struct TouchSample: Equatable {
        var id: Int
        var location: CGPoint
        var timestamp: TimeInterval
    }

    var inputMode: TouchInputMode = .directTouch {
        didSet {
            if oldValue != inputMode { updateCursorVisibility(active: false) }
        }
    }
    var sensitivity: CGFloat = 1.15
    var naturalScroll = true
    var watchOnly = false {
        didSet {
            if watchOnly {
                cancelAll()
                updateCursorVisibility(active: false)
            }
        }
    }
    /// 竖屏分屏纯触控板:整个视图都是触控板,不做捏合缩放。
    var trackpadOnly = false {
        didSet {
            if oldValue != trackpadOnly { updateCursorVisibility(active: false) }
        }
    }
    /// 外部持续左键按住状态（如开启「拖拽锁定」或另一只手按住「左键」按钮）。
    var externalSustainedLeftHold = false {
        didSet {
            guard oldValue != externalSustainedLeftHold else { return }
            styleCursorLayer()
            if showsVirtualCursor {
                updateCursorVisibility(active: externalSustainedLeftHold)
            }
            zoomPan?.onCursorVisualUpdate?(cursor, effectiveLeftHeld, externalSustainedLeftHold)
        }
    }
    /// 外部是否处于「拖拽锁定」切换态（单击可解锁释放）。
    var externalDragLocked = false

    var zoomPan: ZoomPanState? {
        didSet {
            if let shared = zoomPan?.cursor {
                cursor = shared
            }
        }
    }
    private var viewportSize: CGSize { bounds.size }

    var onMove: (Double, Double) -> Void = { _, _ in }
    var onButton: (String, Bool) -> Void = { _, _ in }
    var onClick: (String) -> Void = { _ in }
    var onWheel: (Int, Bool) -> Void = { _, _ in }
    var onSpecialKey: (UInt16, [UInt16]) -> Void = { _, _ in }

    private enum Phase {
        case idle
        case oneFingerPending      // 触控板单指刚按下,等待判定点击/移动/长按
        case trackpadMove          // 触控板相对移动(或外部左键锁定时持续拖拽)
        case trackpadDrag          // 触控板内部手势按住左键拖动(长按拖/二次触按拖)
        case directPending         // 直触按下,未越过阈值
        case directHover           // 直触 1x 快速滑动悬停移鼠(或外部左键锁定时持续拖拽)
        case directPan             // 直触放大态(>1x)单指拖动画布平移
        case directDrag            // 直触内部手势左键拖拽(长按拖/双击后拖)
        case longPressArmed        // 长按已就绪(已震动提示):继续滑动转为左键拖拽,原地松手触发右键
        case twoFingerPending      // 双指刚落下,等待判定滚动/捏合/轻点右键
        case twoFingerScroll       // 双指滚动
        case pinchZoom             // 双指捏合缩放
        case threeFingerDrag       // 三指质心拖动
        case consumed              // 本次多指/手势序列已消费,等待全部手指抬起归零
    }

    private var phase: Phase = .idle
    private var cursor: CGPoint {
        get { zoomPan?.cursor ?? fallbackCursor }
        set {
            let clamped = CGPoint(x: min(max(newValue.x, 0), 1), y: min(max(newValue.y, 0), 1))
            fallbackCursor = clamped
            zoomPan?.updateSharedCursor(clamped, leftHeld: effectiveLeftHeld, active: true)
        }
    }
    private var fallbackCursor = CGPoint(x: 0.5, y: 0.5)

    private var leftHeld = false {
        didSet {
            styleCursorLayer()
            zoomPan?.onCursorVisualUpdate?(cursor, effectiveLeftHeld, true)
        }
    }
    private var effectiveLeftHeld: Bool { leftHeld || externalSustainedLeftHold }

    private var activeTouchPoints: [Int: CGPoint] = [:]
    private var primaryTouchID: Int?
    private var downAt: TimeInterval = 0
    private var downPoint = CGPoint.zero
    private var lastPoint = CGPoint.zero
    private var lastMoveAt: TimeInterval = 0

    // 双击防抖吸附与二次触按拖拽状态
    private var lastTapAt: TimeInterval = 0
    private var lastTapPoint = CGPoint.zero
    private var lastTapNormalized = CGPoint(x: 0.5, y: 0.5)
    private var isSecondTapCandidate = false

    private var lastWatchTwoTapAt: TimeInterval = 0
    private var twoStart = CGPoint.zero
    private var twoLastCenter = CGPoint.zero
    private var twoStartSpan: CGFloat = 0
    private var twoDownAt: TimeInterval = 0
    private var twoMoved = false
    private var threeLastCenter = CGPoint.zero

    private var scrollAccum = CGPoint.zero
    private var scrollVelocity = CGPoint.zero
    private var inertiaLink: CADisplayLink?
    private var baseScale: CGFloat = 1
    private var longPressWork: DispatchWorkItem?
    private var cursorFadeWork: DispatchWorkItem?
    private var armedRingLayer: CAShapeLayer?

    private let cursorLayer = CAShapeLayer()
    private let cursorDotLayer = CAShapeLayer()
    private let lightImpact = UIImpactFeedbackGenerator(style: .light)
    private let mediumImpact = UIImpactFeedbackGenerator(style: .medium)

    let slop: CGFloat = 9
    let doubleTapWindow: TimeInterval = 0.36
    let doubleTapRadius: CGFloat = 28
    /// 按住微停顿达到该阈值后开始滑动即判定为「长按拖拽」，无需死等完整长按震动。
    let longPressDragDelay: TimeInterval = 0.26
    /// 原地长按达到该阈值触发触觉与视觉就绪环：继续滑动进入左键拖拽，原地抬手触发右键。
    let longPressDelay: TimeInterval = 0.40
    let twoFingerTapDuration: TimeInterval = 0.32
    let scrollNotch: CGFloat = 30

    private var usesTrackpadSemantics: Bool {
        inputMode == .trackpad || trackpadOnly
    }

    override var canBecomeFirstResponder: Bool { !watchOnly }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        isUserInteractionEnabled = true
        backgroundColor = .clear
        setupFeedbackLayers()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        syncCursorPosition()
    }

    private func setupFeedbackLayers() {
        let radius: CGFloat = 9
        cursorLayer.bounds = CGRect(x: 0, y: 0, width: radius * 2, height: radius * 2)
        cursorLayer.path = UIBezierPath(ovalIn: cursorLayer.bounds).cgPath
        cursorLayer.lineWidth = 1.6
        cursorLayer.shadowColor = UIColor.black.cgColor
        cursorLayer.shadowOpacity = 0.45
        cursorLayer.shadowRadius = 3
        cursorLayer.shadowOffset = CGSize(width: 0, height: 1)
        cursorLayer.opacity = 0

        let dotRadius: CGFloat = 2.2
        cursorDotLayer.bounds = CGRect(x: 0, y: 0, width: dotRadius * 2, height: dotRadius * 2)
        cursorDotLayer.path = UIBezierPath(ovalIn: cursorDotLayer.bounds).cgPath
        cursorDotLayer.position = CGPoint(x: radius, y: radius)
        cursorLayer.addSublayer(cursorDotLayer)
        layer.addSublayer(cursorLayer)
        styleCursorLayer()
    }

    private var showsVirtualCursor: Bool {
        !watchOnly && !trackpadOnly && inputMode == .trackpad
    }

    private func styleCursorLayer() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let held = effectiveLeftHeld
        let accent = UIColor(red: 0x33 / 255.0, green: 0x70 / 255.0, blue: 1.0, alpha: 1.0)
        cursorLayer.strokeColor = (held ? accent : UIColor.white).cgColor
        cursorLayer.fillColor = (held ? accent.withAlphaComponent(0.28) : UIColor.black.withAlphaComponent(0.18)).cgColor
        cursorDotLayer.fillColor = (held ? accent : UIColor.white).cgColor
        CATransaction.commit()
    }

    private func syncCursorPosition() {
        guard showsVirtualCursor, viewportSize.width > 0, viewportSize.height > 0 else { return }
        let rect = zoomPan?.videoRect(in: viewportSize) ?? CGRect(origin: .zero, size: viewportSize)
        let cur = cursor
        let pt = CGPoint(x: rect.minX + cur.x * rect.width, y: rect.minY + cur.y * rect.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cursorLayer.position = pt
        CATransaction.commit()
    }

    private func updateCursorVisibility(active: Bool) {
        cursorFadeWork?.cancel()
        cursorFadeWork = nil
        guard showsVirtualCursor else {
            cursorLayer.opacity = 0
            return
        }
        syncCursorPosition()
        cursorLayer.opacity = (active || effectiveLeftHeld) ? 0.95 : 0.32
        if active {
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.showsVirtualCursor, !self.effectiveLeftHeld else { return }
                let anim = CABasicAnimation(keyPath: "opacity")
                anim.fromValue = self.cursorLayer.opacity
                anim.toValue = 0.28
                anim.duration = 0.25
                self.cursorLayer.opacity = 0.28
                self.cursorLayer.add(anim, forKey: "fade")
            }
            cursorFadeWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
        }
    }

    private func showArmedRing(at viewPoint: CGPoint) {
        dismissArmedRing()
        guard !watchOnly, !trackpadOnly, bounds.width > 0 else { return }
        let ring = CAShapeLayer()
        let size: CGFloat = 38
        ring.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        ring.position = viewPoint
        ring.path = UIBezierPath(ovalIn: ring.bounds).cgPath
        ring.fillColor = UIColor(red: 0x33 / 255.0, green: 0x70 / 255.0, blue: 1.0, alpha: 0.14).cgColor
        ring.strokeColor = UIColor(red: 0x33 / 255.0, green: 0x70 / 255.0, blue: 1.0, alpha: 0.92).cgColor
        ring.lineWidth = 2.0
        layer.addSublayer(ring)
        armedRingLayer = ring

        let scaleAnim = CABasicAnimation(keyPath: "transform.scale")
        scaleAnim.fromValue = 0.55
        scaleAnim.toValue = 1.0
        scaleAnim.duration = 0.14
        scaleAnim.timingFunction = CAMediaTimingFunction(name: .easeOut)
        ring.add(scaleAnim, forKey: "arm")
    }

    private func dismissArmedRing() {
        armedRingLayer?.removeFromSuperlayer()
        armedRingLayer = nil
    }

    private func showClickPulse(at viewPoint: CGPoint, isRightClick: Bool) {
        guard !watchOnly, !trackpadOnly, bounds.width > 0 else { return }
        let ring = CAShapeLayer()
        let size: CGFloat = isRightClick ? 34 : 26
        ring.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        ring.position = viewPoint
        ring.path = UIBezierPath(ovalIn: ring.bounds).cgPath
        ring.fillColor = UIColor.clear.cgColor
        let stroke = isRightClick
            ? UIColor(red: 1.0, green: 0x7D / 255.0, blue: 0, alpha: 0.95)
            : UIColor(red: 0x33 / 255.0, green: 0x70 / 255.0, blue: 1.0, alpha: 0.9)
        ring.strokeColor = stroke.cgColor
        ring.lineWidth = isRightClick ? 2.2 : 1.8
        layer.addSublayer(ring)

        let scaleAnim = CABasicAnimation(keyPath: "transform.scale")
        scaleAnim.fromValue = 0.45
        scaleAnim.toValue = 1.35
        let fadeAnim = CABasicAnimation(keyPath: "opacity")
        fadeAnim.fromValue = 0.9
        fadeAnim.toValue = 0.0
        let group = CAAnimationGroup()
        group.animations = [scaleAnim, fadeAnim]
        group.duration = 0.22
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        ring.opacity = 0
        CATransaction.begin()
        CATransaction.setCompletionBlock { ring.removeFromSuperlayer() }
        ring.add(group, forKey: "pulse")
        CATransaction.commit()
    }

    private func cursorViewPoint() -> CGPoint {
        let rect = zoomPan?.videoRect(in: viewportSize) ?? CGRect(origin: .zero, size: viewportSize)
        let cur = cursor
        return CGPoint(x: rect.minX + cur.x * rect.width, y: rect.minY + cur.y * rect.height)
    }

    // MARK: - 坐标映射与输出

    /// 视图坐标 → 远端归一化坐标(按缩放/平移后的视频矩形反算)。
    private func normalized(for point: CGPoint) -> CGPoint {
        guard viewportSize.width > 0, viewportSize.height > 0 else { return cursor }
        if let zoomPan {
            return zoomPan.normalizedPoint(for: point, in: viewportSize)
        }
        return CGPoint(
            x: min(max(point.x / max(viewportSize.width, 1), 0), 1),
            y: min(max(point.y / max(viewportSize.height, 1), 0), 1)
        )
    }

    private func sendMove(_ p: CGPoint) {
        let clamped = CGPoint(x: min(max(p.x, 0), 1), y: min(max(p.y, 0), 1))
        cursor = clamped
        onMove(Double(clamped.x), Double(clamped.y))
    }

    private func pressLeft(_ down: Bool) {
        guard leftHeld != down else { return }
        leftHeld = down
        onButton("left", down)
    }

    private func triggerClick(_ button: String, pulseAt point: CGPoint? = nil) {
        if let point {
            showClickPulse(at: point, isRightClick: button == "right")
        }
        onClick(button)
    }

    func cancelAll() {
        cancelLongPress()
        dismissArmedRing()
        if leftHeld { pressLeft(false) }
        activeTouchPoints.removeAll()
        primaryTouchID = nil
        isSecondTapCandidate = false
        phase = .idle
        stopInertia()
    }

    // MARK: - UIKit 触控事件桥接（严格限定本视图活跃触点，杜绝跨控件多指串扰）

    private static func touchIdentifier(_ touch: UITouch) -> Int {
        Int(bitPattern: Unmanaged.passUnretained(touch).toOpaque())
    }

    private func syncActiveTouchesFromEvent(_ event: UIEvent?) {
        guard let viewTouches = event?.touches(for: self) else { return }
        var synced: [Int: CGPoint] = [:]
        for t in viewTouches {
            switch t.phase {
            case .began, .moved, .stationary:
                synced[Self.touchIdentifier(t)] = t.location(in: self)
            default:
                break
            }
        }
        activeTouchPoints = synced
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if !watchOnly, window != nil, !isFirstResponder, !Self.hasTextInputFirstResponder(in: window) {
            _ = becomeFirstResponder()
        }
        let samples = touches.map {
            TouchSample(id: Self.touchIdentifier($0), location: $0.location(in: self), timestamp: $0.timestamp)
        }
        if event != nil {
            syncActiveTouchesFromEvent(event)
            for s in samples { activeTouchPoints[s.id] = s.location }
        }
        handleTouchesBegan(samples)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        let samples = touches.map {
            TouchSample(id: Self.touchIdentifier($0), location: $0.location(in: self), timestamp: $0.timestamp)
        }
        if event != nil {
            syncActiveTouchesFromEvent(event)
            for s in samples { activeTouchPoints[s.id] = s.location }
        }
        handleTouchesMoved(samples)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        let samples = touches.map {
            TouchSample(id: Self.touchIdentifier($0), location: $0.location(in: self), timestamp: $0.timestamp)
        }
        if event != nil {
            syncActiveTouchesFromEvent(event)
            for s in samples { activeTouchPoints.removeValue(forKey: s.id) }
        }
        handleTouchesEnded(samples)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        handleTouchesCancelled()
    }

    private static func hasTextInputFirstResponder(in window: UIWindow?) -> Bool {
        guard let window else { return false }
        return findFirstResponder(in: window) is UITextInput
    }

    private static func findFirstResponder(in view: UIView) -> UIView? {
        if view.isFirstResponder { return view }
        for sub in view.subviews {
            if let found = findFirstResponder(in: sub) { return found }
        }
        return nil
    }

    // MARK: - 外接物理键盘直通（iPad 妙控键盘 / 蓝牙键盘）

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard !watchOnly else {
            super.pressesBegan(presses, with: event)
            return
        }
        var unhandled: Set<UIPress> = []
        for press in presses {
            if let key = press.key, RemoteHardwareKeyMap.forward(key: key, sendTap: onSpecialKey) {
                continue
            }
            unhandled.insert(press)
        }
        if !unhandled.isEmpty {
            super.pressesBegan(unhandled, with: event)
        }
    }

    // MARK: - 可单测纯手势状态机核心

    func handleTouchesBegan(_ samples: [TouchSample]) {
        guard !samples.isEmpty else { return }
        if RCErrorCenter.shared.modal != nil || AppLockStore.shared.isLocked {
            cancelAll()
            return
        }
        for s in samples {
            activeTouchPoints[s.id] = s.location
        }
        let count = activeTouchPoints.count
        let now = samples[0].timestamp

        if watchOnly {
            if count >= 2 {
                phase = .twoFingerPending
                twoDownAt = now
                twoMoved = false
                if let pair = currentTwoCentroid() {
                    twoStart = pair.center
                    twoLastCenter = pair.center
                    twoStartSpan = pair.span
                    baseScale = zoomPan?.scale ?? 1
                }
            } else if count == 1, let first = samples.first, (zoomPan?.scale ?? 1) > 1.01 {
                primaryTouchID = first.id
                lastPoint = first.location
                phase = .directPan
            }
            return
        }

        if count >= 3 {
            // 三指拖动:以三指质心平滑驱动左键拖拽,避免多指轮流触发时跳变
            cancelLongPress()
            dismissArmedRing()
            stopInertia()
            if let center = currentAllCentroid() {
                threeLastCenter = center
                lastMoveAt = now
                if phase != .threeFingerDrag {
                    phase = .threeFingerDrag
                    if !usesTrackpadSemantics {
                        sendMove(normalized(for: center))
                    } else {
                        sendMove(cursor)
                    }
                    pressLeft(true)
                    lightImpact.impactOccurred()
                }
            }
            return
        }

        if count == 2 {
            // 双指:取消单指等待态,进入滚动/捏合/双指右键判定
            let wasAlreadyMovingOneFinger = (phase == .trackpadMove || phase == .directHover || phase == .directPan)
            cancelLongPress()
            dismissArmedRing()
            stopInertia()
            if phase == .trackpadDrag || phase == .directDrag {
                pressLeft(false)
            }
            if phase != .threeFingerDrag {
                phase = .twoFingerPending
                twoDownAt = now
                // 若单指已滑动一段距离才落下第二指,允许进入滚动/缩放但避免松手误触右键
                twoMoved = wasAlreadyMovingOneFinger
                scrollAccum = .zero
                if let pair = currentTwoCentroid() {
                    twoStart = pair.center
                    twoLastCenter = pair.center
                    twoStartSpan = pair.span
                    baseScale = zoomPan?.scale ?? 1
                }
            }
            return
        }

        guard count == 1, let first = samples.first else { return }
        stopInertia()
        primaryTouchID = first.id
        downAt = first.timestamp
        downPoint = first.location
        lastPoint = first.location
        lastMoveAt = first.timestamp

        let withinDoubleTapTime = (first.timestamp - lastTapAt) <= doubleTapWindow && lastTapAt > 0
        if usesTrackpadSemantics {
            isSecondTapCandidate = withinDoubleTapTime && !externalSustainedLeftHold
            phase = .oneFingerPending
        } else {
            let withinRadius = hypot(first.location.x - lastTapPoint.x, first.location.y - lastTapPoint.y) <= doubleTapRadius
            isSecondTapCandidate = withinDoubleTapTime && withinRadius && !externalSustainedLeftHold
            phase = .directPending
        }
        if showsVirtualCursor { updateCursorVisibility(active: true) }
        if !externalSustainedLeftHold {
            scheduleLongPress(expectedDownAt: downAt)
        }
    }

    func handleTouchesMoved(_ samples: [TouchSample]) {
        guard !samples.isEmpty else { return }
        for s in samples {
            activeTouchPoints[s.id] = s.location
        }
        let count = activeTouchPoints.count

        switch phase {
        case .oneFingerPending:
            guard !watchOnly, let pid = primaryTouchID,
                  let sample = samples.first(where: { $0.id == pid }) else { return }
            let p = sample.location
            if hypot(p.x - downPoint.x, p.y - downPoint.y) > slop {
                cancelLongPress()
                dismissArmedRing()
                let heldLongEnoughForDrag = (sample.timestamp - downAt) >= longPressDragDelay
                let shouldStartInternalDrag = !externalSustainedLeftHold && (isSecondTapCandidate || heldLongEnoughForDrag)
                if shouldStartInternalDrag {
                    phase = .trackpadDrag
                    sendMove(cursor)
                    pressLeft(true)
                    lightImpact.impactOccurred()
                } else {
                    phase = .trackpadMove
                }
                applyTrackpadDelta(from: downPoint, to: p, dt: max(sample.timestamp - lastMoveAt, 0.008))
                lastPoint = p
                lastMoveAt = sample.timestamp
            }

        case .directPending:
            guard !watchOnly, let pid = primaryTouchID,
                  let sample = samples.first(where: { $0.id == pid }) else { return }
            let p = sample.location
            if hypot(p.x - downPoint.x, p.y - downPoint.y) > slop {
                cancelLongPress()
                dismissArmedRing()
                let heldLongEnoughForDrag = (sample.timestamp - downAt) >= longPressDragDelay
                if externalSustainedLeftHold {
                    // 外部已开启「拖拽锁定」或按住物理左键 → 单指滑动直接移动远端指针完成拖拽
                    phase = .directHover
                    sendMove(normalized(for: p))
                } else if isSecondTapCandidate || heldLongEnoughForDrag {
                    // 双击后滑动 或 按住停顿后滑动(长按拖拽) → 从精确按下起点开始左键拖拽
                    phase = .directDrag
                    sendMove(normalized(for: downPoint))
                    pressLeft(true)
                    sendMove(normalized(for: p))
                    lightImpact.impactOccurred()
                } else if let zoomPan, zoomPan.scale > 1.01 {
                    phase = .directPan
                    let dx = p.x - downPoint.x
                    let dy = p.y - downPoint.y
                    zoomPan.pan = CGPoint(x: zoomPan.pan.x + dx, y: zoomPan.pan.y + dy)
                    zoomPan.clampPan(in: viewportSize)
                    syncCursorPosition()
                    zoomPan.onCursorVisualUpdate?(cursor, effectiveLeftHeld, false)
                } else {
                    // 1x 未放大时快速滑动 → 平滑移动悬停光标(Hover),避免误拖桌面文件
                    phase = .directHover
                    sendMove(normalized(for: p))
                }
                lastPoint = p
                lastMoveAt = sample.timestamp
            }

        case .longPressArmed:
            // 长按震动就绪后手指开始移动 → 立即切换为左键长按拖拽!
            guard !watchOnly, let pid = primaryTouchID,
                  let sample = samples.first(where: { $0.id == pid }) else { return }
            let p = sample.location
            if hypot(p.x - downPoint.x, p.y - downPoint.y) > slop {
                dismissArmedRing()
                if usesTrackpadSemantics {
                    phase = .trackpadDrag
                    sendMove(cursor)
                    pressLeft(true)
                    applyTrackpadDelta(from: downPoint, to: p, dt: max(sample.timestamp - lastMoveAt, 0.008))
                } else {
                    phase = .directDrag
                    sendMove(normalized(for: downPoint))
                    pressLeft(true)
                    sendMove(normalized(for: p))
                }
                lightImpact.impactOccurred()
                lastPoint = p
                lastMoveAt = sample.timestamp
            }

        case .trackpadMove, .trackpadDrag:
            guard !watchOnly, let pid = primaryTouchID,
                  let sample = samples.first(where: { $0.id == pid }) else { return }
            let p = sample.location
            let dt = max(sample.timestamp - lastMoveAt, 0.001)
            applyTrackpadDelta(from: lastPoint, to: p, dt: dt)
            lastPoint = p
            lastMoveAt = sample.timestamp

        case .threeFingerDrag:
            guard !watchOnly, count >= 2, let center = currentAllCentroid() else { return }
            let now = samples[0].timestamp
            let dt = max(now - lastMoveAt, 0.001)
            if !usesTrackpadSemantics {
                sendMove(normalized(for: center))
            } else {
                applyTrackpadDelta(from: threeLastCenter, to: center, dt: dt)
            }
            threeLastCenter = center
            lastMoveAt = now

        case .directHover:
            guard !watchOnly, let pid = primaryTouchID,
                  let sample = samples.first(where: { $0.id == pid }) else { return }
            let p = sample.location
            lastPoint = p
            lastMoveAt = sample.timestamp
            sendMove(normalized(for: p))

        case .directPan:
            guard let pid = primaryTouchID,
                  let sample = samples.first(where: { $0.id == pid }),
                  let zoomPan else { return }
            let p = sample.location
            let dx = p.x - lastPoint.x
            let dy = p.y - lastPoint.y
            lastPoint = p
            if zoomPan.scale > 1 {
                zoomPan.pan = CGPoint(x: zoomPan.pan.x + dx, y: zoomPan.pan.y + dy)
                zoomPan.clampPan(in: viewportSize)
                syncCursorPosition()
                zoomPan.onCursorVisualUpdate?(cursor, effectiveLeftHeld, false)
            }

        case .directDrag:
            guard !watchOnly, let pid = primaryTouchID,
                  let sample = samples.first(where: { $0.id == pid }) else { return }
            sendMove(normalized(for: sample.location))

        case .twoFingerPending, .twoFingerScroll, .pinchZoom:
            guard count >= 2, let pair = currentTwoCentroid() else { return }
            let prevCenter = twoLastCenter
            let centerDelta = CGPoint(x: pair.center.x - prevCenter.x, y: pair.center.y - prevCenter.y)
            twoLastCenter = pair.center
            let spanDelta = pair.span - twoStartSpan
            let centerTravel = hypot(pair.center.x - twoStart.x, pair.center.y - twoStart.y)

            if phase == .twoFingerPending {
                if !trackpadOnly, abs(spanDelta) > max(12, centerTravel * 0.82) {
                    phase = .pinchZoom
                    twoMoved = true
                } else if !watchOnly, centerTravel > slop {
                    phase = .twoFingerScroll
                    twoMoved = true
                    scrollAccum = .zero
                    // 直触双指滚动前先将远端鼠标定位至双指起点,确保滚轮作用于手指正下方的窗口/分栏
                    if !usesTrackpadSemantics {
                        sendMove(normalized(for: twoStart))
                    }
                } else if watchOnly, centerTravel > slop, (zoomPan?.scale ?? 1) > 1.01 {
                    phase = .pinchZoom
                    twoMoved = true
                }
            }

            if phase == .pinchZoom, let zoomPan {
                let oldScale = max(zoomPan.scale, 1)
                let newScale = min(8, max(1, baseScale * pair.span / max(twoStartSpan, 1)))
                let factor = newScale / oldScale
                zoomPan.scale = newScale
                if newScale <= 1 {
                    zoomPan.pan = .zero
                } else {
                    let anchorX = prevCenter.x - viewportSize.width / 2
                    let anchorY = prevCenter.y - viewportSize.height / 2
                    let nextPanX = (zoomPan.pan.x - anchorX) * factor + anchorX + centerDelta.x
                    let nextPanY = (zoomPan.pan.y - anchorY) * factor + anchorY + centerDelta.y
                    zoomPan.pan = CGPoint(x: nextPanX, y: nextPanY)
                    zoomPan.clampPan(in: viewportSize)
                }
                syncCursorPosition()
                zoomPan.onCursorVisualUpdate?(cursor, effectiveLeftHeld, false)
            } else if phase == .twoFingerScroll, !watchOnly {
                scrollAccum.x += centerDelta.x
                scrollAccum.y += centerDelta.y
                scrollVelocity = centerDelta
                emitScroll()
            }

        default:
            break
        }
    }

    func handleTouchesEnded(_ samples: [TouchSample]) {
        for s in samples {
            activeTouchPoints.removeValue(forKey: s.id)
        }
        let remaining = activeTouchPoints.count
        let endTimestamp = samples.first?.timestamp ?? lastMoveAt

        switch phase {
        case .oneFingerPending:
            cancelLongPress()
            dismissArmedRing()
            if !watchOnly {
                if externalDragLocked {
                    // 拖拽锁定态下轻点触控板 → 释放拖拽锁定
                    onButton("left", false)
                    lastTapAt = 0
                } else {
                    triggerClick("left", pulseAt: showsVirtualCursor ? cursorViewPoint() : nil)
                    lastTapAt = endTimestamp
                }
            }
            isSecondTapCandidate = false
            primaryTouchID = nil
            phase = remaining > 0 ? .consumed : .idle

        case .directPending:
            cancelLongPress()
            dismissArmedRing()
            if !watchOnly, let endedPrimary = samples.first(where: { $0.id == primaryTouchID }) ?? samples.first {
                if externalDragLocked {
                    // 拖拽锁定态下轻点画面 → 释放拖拽锁定
                    onButton("left", false)
                    lastTapAt = 0
                } else {
                    let loc = endedPrimary.location
                    let targetNorm: CGPoint
                    let pulsePos: CGPoint
                    if isSecondTapCandidate {
                        // 双击/三击容差半径内自动吸附至首击精确坐标,避免手机指尖微偏超出远端 4px 双击判定区
                        targetNorm = lastTapNormalized
                        pulsePos = lastTapPoint
                    } else {
                        targetNorm = normalized(for: loc)
                        lastTapPoint = loc
                        lastTapNormalized = targetNorm
                        pulsePos = loc
                    }
                    sendMove(targetNorm)
                    triggerClick("left", pulseAt: pulsePos)
                    lastTapAt = endedPrimary.timestamp
                }
            }
            isSecondTapCandidate = false
            primaryTouchID = nil
            phase = remaining > 0 ? .consumed : .idle

        case .longPressArmed:
            // 长按震动就绪后原地松手(未发生滑动) → 触发鼠标右键
            cancelLongPress()
            dismissArmedRing()
            if !watchOnly {
                var pulsePos = cursorViewPoint()
                if !usesTrackpadSemantics {
                    let targetNorm = normalized(for: downPoint)
                    sendMove(targetNorm)
                    pulsePos = downPoint
                }
                triggerClick("right", pulseAt: trackpadOnly ? nil : pulsePos)
                lastTapAt = 0
            }
            isSecondTapCandidate = false
            primaryTouchID = nil
            phase = remaining > 0 ? .consumed : .idle

        case .directPan, .directHover, .trackpadMove:
            isSecondTapCandidate = false
            if remaining <= 0 {
                primaryTouchID = nil
                phase = .idle
            }

        case .trackpadDrag, .directDrag:
            pressLeft(false)
            isSecondTapCandidate = false
            lastTapAt = 0
            primaryTouchID = nil
            if showsVirtualCursor { updateCursorVisibility(active: true) }
            phase = remaining > 0 ? .consumed : .idle

        case .threeFingerDrag:
            if remaining < 3 {
                pressLeft(false)
                if showsVirtualCursor { updateCursorVisibility(active: true) }
                phase = remaining > 0 ? .consumed : .idle
            }

        case .twoFingerPending:
            if !twoMoved, endTimestamp - twoDownAt < twoFingerTapDuration {
                if watchOnly {
                    if endTimestamp - lastWatchTwoTapAt < 0.38 {
                        zoomPan?.reset()
                        lightImpact.impactOccurred()
                    }
                    lastWatchTwoTapAt = endTimestamp
                } else {
                    var pulsePos = cursorViewPoint()
                    if !usesTrackpadSemantics {
                        sendMove(normalized(for: twoStart))
                        pulsePos = twoStart
                    }
                    mediumImpact.impactOccurred()
                    triggerClick("right", pulseAt: trackpadOnly ? nil : pulsePos)
                }
            }
            phase = remaining > 0 ? .consumed : .idle

        case .twoFingerScroll:
            if remaining < 2 {
                if !watchOnly { startInertia() }
                phase = remaining > 0 ? .consumed : .idle
            }

        case .pinchZoom:
            if remaining < 2 {
                phase = remaining > 0 ? .consumed : .idle
            }

        case .consumed:
            if remaining <= 0 {
                primaryTouchID = nil
                phase = .idle
            }

        case .idle:
            break
        }
    }

    func handleTouchesCancelled() {
        cancelAll()
    }

    // MARK: - 内部计算与惯性滚轮

    private func applyTrackpadDelta(from prev: CGPoint, to current: CGPoint, dt: TimeInterval) {
        var dx = current.x - prev.x
        var dy = current.y - prev.y
        let speed = hypot(dx, dy) / max(dt, 0.001)
        let gain = sensitivity * (1 + min(speed / 900, 1.2))
        dx *= gain
        dy *= gain
        let rect = zoomPan?.videoRect(in: viewportSize) ?? CGRect(origin: .zero, size: viewportSize)
        let scaleX = max(rect.width, 1)
        let scaleY = max(rect.height, 1)
        let next = CGPoint(
            x: min(max(cursor.x + dx / scaleX, 0), 1),
            y: min(max(cursor.y + dy / scaleY, 0), 1)
        )
        cursor = next
        if showsVirtualCursor { updateCursorVisibility(active: true) }
        sendMove(next)
    }

    /// 触发原地长按就绪态（可单测直接调用或由定时器驱动）。
    func fireScheduledLongPressIfPending() {
        guard !watchOnly, phase == .oneFingerPending || phase == .directPending else { return }
        phase = .longPressArmed
        mediumImpact.impactOccurred()
        if !trackpadOnly {
            let ringPos = usesTrackpadSemantics ? cursorViewPoint() : downPoint
            showArmedRing(at: ringPos)
        }
    }

    private func scheduleLongPress(expectedDownAt: TimeInterval) {
        cancelLongPress()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.downAt == expectedDownAt else { return }
            self.fireScheduledLongPressIfPending()
        }
        longPressWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + longPressDelay, execute: work)
    }

    private func cancelLongPress() {
        longPressWork?.cancel()
        longPressWork = nil
    }

    private func currentTwoCentroid() -> (center: CGPoint, span: CGFloat)? {
        guard activeTouchPoints.count >= 2 else { return nil }
        let sortedKeys = activeTouchPoints.keys.sorted()
        guard let p0 = activeTouchPoints[sortedKeys[0]],
              let p1 = activeTouchPoints[sortedKeys[1]] else { return nil }
        let center = CGPoint(x: (p0.x + p1.x) / 2, y: (p0.y + p1.y) / 2)
        let span = hypot(p0.x - p1.x, p0.y - p1.y)
        return (center, span)
    }

    private func currentAllCentroid() -> CGPoint? {
        guard !activeTouchPoints.isEmpty else { return nil }
        var sumX: CGFloat = 0
        var sumY: CGFloat = 0
        for pt in activeTouchPoints.values {
            sumX += pt.x
            sumY += pt.y
        }
        let n = CGFloat(activeTouchPoints.count)
        return CGPoint(x: sumX / n, y: sumY / n)
    }

    private func emitScroll() {
        // 底层滚轮约定 delta > 0 为向上滚轮(页面上移看顶部)、delta < 0 为向下滚轮(页面下移看底部):
        // 自然滚动(naturalScroll=true)下双指上推(scrollAccum.y < 0)应发送负值向下浏览内容,故符号为 +1。
        let sign: CGFloat = naturalScroll ? 1 : -1
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

/// 外接物理键盘（iPad 妙控键盘 / 蓝牙键盘）HID 键码到远端 Set-1 扫描码映射。
enum RemoteHardwareKeyMap {
    static func forward(key: UIKey, sendTap: (UInt16, [UInt16]) -> Void) -> Bool {
        var mods: [UInt16] = []
        if key.modifierFlags.contains(.command) { mods.append(0xe05b) }
        if key.modifierFlags.contains(.control) { mods.append(0x1d) }
        if key.modifierFlags.contains(.alternate) { mods.append(0x38) }
        if key.modifierFlags.contains(.shift) { mods.append(0x2a) }

        if let special = specialScancode(for: key.keyCode) {
            sendTap(special, mods)
            return true
        }
        let chars = key.charactersIgnoringModifiers
        guard chars.count == 1, let strokes = RemoteKeys.strokes(for: chars), let stroke = strokes.first else {
            return false
        }
        var finalMods = mods
        if stroke.shift && !finalMods.contains(0x2a) {
            finalMods.append(0x2a)
        }
        sendTap(stroke.key, finalMods)
        return true
    }

    static func specialScancode(for usage: UIKeyboardHIDUsage) -> UInt16? {
        switch usage {
        case .keyboardEscape: return 0x01
        case .keyboardReturnOrEnter, .keypadEnter: return 0x1c
        case .keyboardDeleteOrBackspace: return 0x0e
        case .keyboardDeleteForward: return 0xe053
        case .keyboardTab: return 0x0f
        case .keyboardSpacebar: return 0x39
        case .keyboardLeftArrow: return 0xe04b
        case .keyboardRightArrow: return 0xe04d
        case .keyboardUpArrow: return 0xe048
        case .keyboardDownArrow: return 0xe050
        case .keyboardHome: return 0xe047
        case .keyboardEnd: return 0xe04f
        case .keyboardPageUp: return 0xe049
        case .keyboardPageDown: return 0xe051
        case .keyboardF1: return 0x3b
        case .keyboardF2: return 0x3c
        case .keyboardF3: return 0x3d
        case .keyboardF4: return 0x3e
        case .keyboardF5: return 0x3f
        case .keyboardF6: return 0x40
        case .keyboardF7: return 0x41
        case .keyboardF8: return 0x42
        case .keyboardF9: return 0x43
        case .keyboardF10: return 0x44
        case .keyboardF11: return 0x57
        case .keyboardF12: return 0x58
        default: return nil
        }
    }
}

/// 竖屏分屏触控板模式下覆盖在上方桌面画面的只读虚拟光标浮层（零触控拦截，CoreAnimation 直驱）。
struct SplitCursorOverlayView: UIViewRepresentable {
    var zoomPan: ZoomPanState
    var leftHeld: Bool

    func makeUIView(context: Context) -> SplitCursorUIView {
        let view = SplitCursorUIView()
        view.zoomPan = zoomPan
        view.bindCursorUpdates()
        return view
    }

    func updateUIView(_ uiView: SplitCursorUIView, context: Context) {
        uiView.zoomPan = zoomPan
        uiView.setLeftHeld(leftHeld)
    }

    final class SplitCursorUIView: UIView {
        weak var zoomPan: ZoomPanState?
        private let cursorLayer = CAShapeLayer()
        private let dotLayer = CAShapeLayer()
        private var leftHeld = false
        private var fadeWork: DispatchWorkItem?

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            backgroundColor = .clear
            let radius: CGFloat = 9
            cursorLayer.bounds = CGRect(x: 0, y: 0, width: radius * 2, height: radius * 2)
            cursorLayer.path = UIBezierPath(ovalIn: cursorLayer.bounds).cgPath
            cursorLayer.lineWidth = 1.6
            cursorLayer.shadowColor = UIColor.black.cgColor
            cursorLayer.shadowOpacity = 0.45
            cursorLayer.shadowRadius = 3
            cursorLayer.shadowOffset = CGSize(width: 0, height: 1)
            cursorLayer.opacity = 0.35

            let dotRadius: CGFloat = 2.2
            dotLayer.bounds = CGRect(x: 0, y: 0, width: dotRadius * 2, height: dotRadius * 2)
            dotLayer.path = UIBezierPath(ovalIn: dotLayer.bounds).cgPath
            dotLayer.position = CGPoint(x: radius, y: radius)
            cursorLayer.addSublayer(dotLayer)
            layer.addSublayer(cursorLayer)
            applyStyle()
        }

        required init?(coder: NSCoder) { fatalError() }

        override func layoutSubviews() {
            super.layoutSubviews()
            reposition()
        }

        func bindCursorUpdates() {
            zoomPan?.onCursorVisualUpdate = { [weak self] _, held, active in
                guard let self else { return }
                if self.leftHeld != held {
                    self.leftHeld = held
                    self.applyStyle()
                }
                self.reposition()
                if active || held {
                    self.bumpVisibility()
                }
            }
        }

        func setLeftHeld(_ held: Bool) {
            guard leftHeld != held else {
                reposition()
                return
            }
            leftHeld = held
            applyStyle()
            reposition()
            if held { bumpVisibility() }
        }

        private func applyStyle() {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let accent = UIColor(red: 0x33 / 255.0, green: 0x70 / 255.0, blue: 1.0, alpha: 1.0)
            cursorLayer.strokeColor = (leftHeld ? accent : UIColor.white).cgColor
            cursorLayer.fillColor = (leftHeld ? accent.withAlphaComponent(0.28) : UIColor.black.withAlphaComponent(0.18)).cgColor
            dotLayer.fillColor = (leftHeld ? accent : UIColor.white).cgColor
            CATransaction.commit()
        }

        private func reposition() {
            guard bounds.width > 0, bounds.height > 0, let zoomPan else { return }
            let rect = zoomPan.videoRect(in: bounds.size)
            let cur = zoomPan.cursor
            let pt = CGPoint(x: rect.minX + cur.x * rect.width, y: rect.minY + cur.y * rect.height)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            cursorLayer.position = pt
            CATransaction.commit()
        }

        private func bumpVisibility() {
            fadeWork?.cancel()
            fadeWork = nil
            cursorLayer.opacity = 0.95
            let work = DispatchWorkItem { [weak self] in
                guard let self, !self.leftHeld else { return }
                self.cursorLayer.opacity = 0.32
            }
            fadeWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
        }
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
        view.externalSustainedLeftHold = session.isSustainedLeftHold
        view.externalDragLocked = session.isDragLocked
        view.zoomPan = zoomPan
        view.onMove = { [weak session] nx, ny in session?.sendMouseMove(nx: nx, ny: ny) }
        view.onButton = { [weak session] button, pressed in session?.sendMouseButton(button: button, pressed: pressed) }
        view.onClick = { [weak session] button in session?.clickMouse(button) }
        view.onWheel = { [weak session] delta, horizontal in session?.sendWheel(delta: delta, horizontal: horizontal) }
        view.onSpecialKey = { [weak session] scancode, mods in session?.tapKey(scancode, modifiers: mods) }
    }
}
