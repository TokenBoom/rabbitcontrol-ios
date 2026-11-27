import SwiftUI
import UIKit

/// 修饰键三态机:空闲 → 单击单次生效(sticky) → 双击常驻自锁(locked)。
struct ModifierLatch: Equatable {
    enum Mode: Equatable {
        case sticky
        case locked
    }

    private(set) var states: [UInt16: Mode] = [:]
    private var lastStickyAt: [UInt16: TimeInterval] = [:]
    var doubleTapWindow: TimeInterval = 0.38

    func mode(for code: UInt16) -> Mode? {
        states[code]
    }

    var activeCodes: [UInt16] {
        let order: [UInt16] = [0xe05b, 0x1d, 0x38, 0x2a]
        return order.filter { states[$0] != nil } + states.keys.filter { !order.contains($0) }.sorted()
    }

    var isEmpty: Bool { states.isEmpty }

    mutating func toggle(_ code: UInt16, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        switch states[code] {
        case nil:
            states[code] = .sticky
            lastStickyAt[code] = now
        case .sticky:
            if let at = lastStickyAt[code], now - at <= doubleTapWindow {
                states[code] = .locked
            } else {
                states.removeValue(forKey: code)
            }
            lastStickyAt.removeValue(forKey: code)
        case .locked:
            states.removeValue(forKey: code)
            lastStickyAt.removeValue(forKey: code)
        }
    }

    /// 取出当前生效的修饰键,并自动释放单次(sticky)修饰键,保留自锁(locked)修饰键。
    mutating func consumeForKeyPress() -> [UInt16] {
        let active = activeCodes
        states = states.filter { $0.value == .locked }
        lastStickyAt.removeAll()
        return active
    }

    mutating func clearAll() {
        states.removeAll()
        lastStickyAt.removeAll()
    }
}

/// 原生输入法安全的隐藏键盘捕获视图:
/// - 重写 `deleteBackward()` 原生可靠捕获软键盘退格(无需依赖易被光标移动破坏的零宽字符);
/// - 严格检查 `markedTextRange == nil`,不打断中文拼音/日文假名等候选词预输入合成;
/// - 禁用 iOS 默认智能引号与智能破折号,并支持外接物理键盘功能键/组合键直通。
struct IMECapableKeyCaptureField: UIViewRepresentable {
    @Binding var isFocused: Bool
    var onCommitText: (String) -> Void
    var onBackspace: () -> Void
    var onReturn: () -> Void
    var onDesktopHardwareKey: ((UInt16, [UInt16]) -> Void)? = nil
    var onTerminalControlSequence: ((String) -> Void)? = nil

    func makeUIView(context: Context) -> KeyCaptureUITextField {
        let tf = KeyCaptureUITextField()
        tf.onCommitText = onCommitText
        tf.onBackspace = onBackspace
        tf.onReturn = onReturn
        tf.onDesktopHardwareKey = onDesktopHardwareKey
        tf.onTerminalControlSequence = onTerminalControlSequence
        tf.onFocusChanged = { focused in
            if isFocused != focused {
                isFocused = focused
            }
        }
        return tf
    }

    func updateUIView(_ uiView: KeyCaptureUITextField, context: Context) {
        uiView.onCommitText = onCommitText
        uiView.onBackspace = onBackspace
        uiView.onReturn = onReturn
        uiView.onDesktopHardwareKey = onDesktopHardwareKey
        uiView.onTerminalControlSequence = onTerminalControlSequence
        uiView.onFocusChanged = { focused in
            if isFocused != focused {
                isFocused = focused
            }
        }
        if isFocused && !uiView.isFirstResponder {
            DispatchQueue.main.async {
                if self.isFocused && uiView.window != nil && !uiView.isFirstResponder {
                    _ = uiView.becomeFirstResponder()
                }
            }
        } else if !isFocused && uiView.isFirstResponder {
            DispatchQueue.main.async {
                if !self.isFocused && uiView.isFirstResponder {
                    _ = uiView.resignFirstResponder()
                }
            }
        }
    }

    final class KeyCaptureUITextField: UITextField, UITextFieldDelegate {
        var onCommitText: ((String) -> Void)?
        var onBackspace: (() -> Void)?
        var onReturn: (() -> Void)?
        var onDesktopHardwareKey: ((UInt16, [UInt16]) -> Void)?
        var onTerminalControlSequence: ((String) -> Void)?
        var onFocusChanged: ((Bool) -> Void)?

        override init(frame: CGRect) {
            super.init(frame: frame)
            autocorrectionType = .no
            autocapitalizationType = .none
            spellCheckingType = .no
            smartQuotesType = .no
            smartDashesType = .no
            smartInsertDeleteType = .no
            returnKeyType = .default
            tintColor = .clear
            textColor = .clear
            backgroundColor = .clear
            delegate = self
            addTarget(self, action: #selector(handleEditingChanged), for: .editingChanged)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func becomeFirstResponder() -> Bool {
            let ok = super.becomeFirstResponder()
            if ok { onFocusChanged?(true) }
            return ok
        }

        override func resignFirstResponder() -> Bool {
            let ok = super.resignFirstResponder()
            if ok { onFocusChanged?(false) }
            return ok
        }

        override func deleteBackward() {
            // 正在拼音预输入时交给系统输入法回删拼音字母;无预输入时直接发送远端退格
            if markedTextRange != nil {
                super.deleteBackward()
                return
            }
            if let current = text, !current.isEmpty {
                super.deleteBackward()
                text = ""
            }
            onBackspace?()
        }

        @objc private func handleEditingChanged() {
            // 预输入合成未上屏时绝不清空文本,保证中文拼音候选栏正常工作
            guard markedTextRange == nil else { return }
            guard let committed = text, !committed.isEmpty else { return }
            text = ""
            onCommitText?(committed)
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            if markedTextRange != nil {
                return true
            }
            if let current = text, !current.isEmpty {
                text = ""
                onCommitText?(current)
            }
            onReturn?()
            return false
        }

        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            if markedTextRange != nil {
                super.pressesBegan(presses, with: event)
                return
            }
            var unhandled: Set<UIPress> = []
            for press in presses {
                guard let key = press.key else {
                    unhandled.insert(press)
                    continue
                }
                if let onTerminalControlSequence, let seq = Self.terminalSequence(for: key) {
                    onTerminalControlSequence(seq)
                    continue
                }
                if let onDesktopHardwareKey {
                    let hasCommandOrCtrlOrAlt = !key.modifierFlags.intersection([.command, .control, .alternate]).isEmpty
                    let isSpecial = RemoteHardwareKeyMap.specialScancode(for: key.keyCode) != nil
                    if (hasCommandOrCtrlOrAlt || isSpecial),
                       RemoteHardwareKeyMap.forward(key: key, sendTap: onDesktopHardwareKey) {
                        continue
                    }
                }
                unhandled.insert(press)
            }
            if !unhandled.isEmpty {
                super.pressesBegan(unhandled, with: event)
            }
        }

        private static func terminalSequence(for key: UIKey) -> String? {
            if key.modifierFlags.contains(.control) {
                let chars = key.charactersIgnoringModifiers.lowercased()
                if let scalar = chars.unicodeScalars.first, scalar.value >= 0x61 && scalar.value <= 0x7a {
                    let ctrlByte = UInt8(scalar.value - 0x60)
                    return String(UnicodeScalar(ctrlByte))
                }
            }
            switch key.keyCode {
            case .keyboardEscape: return "\u{1b}"
            case .keyboardTab: return key.modifierFlags.contains(.shift) ? "\u{1b}[Z" : "\t"
            case .keyboardUpArrow: return "\u{1b}[A"
            case .keyboardDownArrow: return "\u{1b}[B"
            case .keyboardRightArrow: return "\u{1b}[C"
            case .keyboardLeftArrow: return "\u{1b}[D"
            case .keyboardHome: return "\u{1b}[H"
            case .keyboardEnd: return "\u{1b}[F"
            case .keyboardPageUp: return "\u{1b}[5~"
            case .keyboardPageDown: return "\u{1b}[6~"
            case .keyboardDeleteForward: return "\u{1b}[3~"
            default: return nil
            }
        }
    }
}

/// 会话内键盘扩展条:修饰键单击单次/双击自锁(同步作用于键鼠点击与拖拽)、常用键与双平台组合键一键发送,软键盘支持中文预输入与原生退格。
struct SessionKeyboardBar: View {
    var session: SessionService
    @Binding var expanded: Bool
    var stageWidth: CGFloat = 0
    var deviceKind: Device.Kind? = nil
    @State private var typing = false
    @Environment(\.verticalSizeClass) private var verticalClass

    static let sentinel = "\u{200B}"

    enum SoftKeyEvent: Equatable {
        case none
        case backspace
        case text(String)
    }

    /// 解析隐藏输入框的文本变化,利用零宽哨兵准确识别软键盘退格。
    static func parseSoftInput(_ newValue: String) -> SoftKeyEvent {
        if newValue == sentinel { return .none }
        if newValue.isEmpty { return .backspace }
        if newValue.hasPrefix(sentinel) {
            let suffix = String(newValue.dropFirst(sentinel.count))
            return suffix.isEmpty ? .none : .text(suffix)
        }
        let cleaned = newValue.replacingOccurrences(of: sentinel, with: "")
        return cleaned.isEmpty ? .backspace : .text(cleaned)
    }

    private var isLandscape: Bool {
        RCLayout.prefersSingleRowKeyboardBar(
            verticalSizeClass: verticalClass,
            availableWidth: stageWidth
        )
    }

    private var prefersPC: Bool {
        session.prefersPCShortcuts(deviceKind: deviceKind)
    }

    private var mods: [(String, String, UInt16)] {
        prefersPC
            ? [
                ("⌃", "Control", 0x1d),
                ("⊞", "Windows", 0xe05b),
                ("⌥", "Alt", 0x38),
                ("⇧", "Shift", 0x2a),
            ]
            : [
                ("⌘", "Command", 0xe05b),
                ("⌃", "Control", 0x1d),
                ("⌥", "Option", 0x38),
                ("⇧", "Shift", 0x2a),
            ]
    }

    private let primaryKeys: [(String, String, UInt16)] = [
        ("Esc", "Escape", 1),
        ("Tab", "Tab", 0x0f),
        ("⌫", "退格", 0x0e),
        ("⏎", "回车", 0x1c),
        ("空格", "空格", 0x39),
        ("Del", "向前删除", 0xe053),
    ]
    private let arrowAndFnKeys: [(String, String, UInt16)] = [
        ("←", "左方向键", 0xe04b),
        ("↑", "上方向键", 0xe048),
        ("↓", "下方向键", 0xe050),
        ("→", "右方向键", 0xe04d),
        ("Home", "Home", 0xe047),
        ("End", "End", 0xe04f),
        ("PgUp", "Page Up", 0xe049),
        ("PgDn", "Page Down", 0xe051),
        ("F5", "F5", 0x3f),
        ("F11", "F11", 0x57),
    ]

    private var combos: [(String, UInt16, [UInt16])] {
        if prefersPC {
            return [
                ("⌃C", 0x2e, [0x1d]),
                ("⌃V", 0x2f, [0x1d]),
                ("⌃Z", 0x2c, [0x1d]),
                ("⌃A", 0x1e, [0x1d]),
                ("⌥Tab", 0x0f, [0x38]),
                ("⊞D", 0x20, [0xe05b]),
                ("⌃⇧Esc", 0x01, [0x1d, 0x2a]),
            ]
        }
        return [
            ("⌘Space", 0x39, [0xe05b]),
            ("⌘C", 0x2e, [0xe05b]),
            ("⌘V", 0x2f, [0xe05b]),
            ("⌘Z", 0x2c, [0xe05b]),
            ("⌘A", 0x1e, [0xe05b]),
            ("⌘Tab", 0x0f, [0xe05b]),
            ("⌃C", 0x2e, [0x1d]),
        ]
    }

    private var activeModifierSymbols: String {
        mods.compactMap { session.modifierLatch.mode(for: $0.2) != nil ? $0.0 : nil }.joined()
    }

    var body: some View {
        VStack(spacing: isLandscape ? 4 : 6) {
            if expanded {
                if isLandscape {
                    landscapeStrip
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else {
                    portraitPanel
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            IMECapableKeyCaptureField(
                isFocused: $typing,
                onCommitText: { chunk in
                    handleTypedChunk(chunk)
                },
                onBackspace: {
                    tap(0x0e)
                },
                onReturn: {
                    tap(0x1c)
                },
                onDesktopHardwareKey: { scancode, extraMods in
                    session.tapKey(scancode, modifiers: extraMods)
                }
            )
            .frame(width: 1, height: 1)
            .opacity(0.01)
            .allowsHitTesting(false)

            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                withAnimation(.easeOut(duration: 0.18)) { expanded.toggle() }
                if !expanded {
                    typing = false
                }
            } label: {
                HStack(spacing: 5) {
                    RabbitIcon(.keyboard, size: isLandscape ? 13 : 15)
                    if !activeModifierSymbols.isEmpty {
                        Text(activeModifierSymbols)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(RCColor.accent)
                    }
                    RabbitIcon(expanded ? .chevronDown : .chevronUp, size: 11)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, isLandscape ? 14 : 16)
                .frame(minWidth: isLandscape ? 64 : 76, minHeight: isLandscape ? 25 : 30)
                .background(RCColor.hudBg, in: Capsule())
                .overlay {
                    Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1)
                }
            }
            .accessibilityLabel(expanded ? "收起键盘扩展条" : "展开键盘扩展条")
            .accessibilityIdentifier("sessionbar.toggle")
        }
    }

    private var landscapeStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                typingButton(height: 30)
                barDivider(height: 18)
                ForEach(mods, id: \.2) { modButton($0, width: 34, height: 30) }
                barDivider(height: 18)
                ForEach(primaryKeys, id: \.2) { keyButton($0, height: 30) }
                barDivider(height: 18)
                ForEach(arrowAndFnKeys, id: \.2) { keyButton($0, height: 30) }
                barDivider(height: 18)
                ForEach(combos, id: \.0) { comboButton($0, height: 30) }
            }
            .padding(.horizontal, 10)
        }
        .padding(.vertical, 6)
        .background(RCColor.hudBg, in: Capsule())
        .overlay {
            Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.24), radius: 10, y: 3)
        .frame(maxWidth: 860)
        .safeAreaPadding(.horizontal, 14)
    }

    private var portraitPanel: some View {
        VStack(spacing: 7) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    typingButton(height: 34)
                    barDivider(height: 20)
                    ForEach(mods, id: \.2) { modButton($0, width: 38, height: 34) }
                    barDivider(height: 20)
                    ForEach(primaryKeys, id: \.2) { keyButton($0, height: 34) }
                }
                .padding(.horizontal, 10)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(arrowAndFnKeys, id: \.2) { keyButton($0, height: 33) }
                    barDivider(height: 18)
                    ForEach(combos, id: \.0) { comboButton($0, height: 33) }
                }
                .padding(.horizontal, 10)
            }
        }
        .padding(.vertical, 9)
        .background(RCColor.hudBg, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
        .padding(.horizontal, 10)
    }

    private func barDivider(height: CGFloat) -> some View {
        Divider().frame(height: height).overlay(.white.opacity(0.22))
    }

    private func modButton(_ mod: (String, String, UInt16), width: CGFloat, height: CGFloat) -> some View {
        let mode = session.modifierLatch.mode(for: mod.2)
        return Button {
            UISelectionFeedbackGenerator().selectionChanged()
            session.toggleModifier(mod.2)
        } label: {
            ZStack(alignment: .bottom) {
                Text(mod.0)
                    .font(isLandscape ? .subheadline.bold() : .headline)
                    .frame(width: width, height: height)
                if mode != nil {
                    Capsule()
                        .fill(mode == .locked ? Color.white : RCColor.accent)
                        .frame(width: mode == .locked ? 12 : 5, height: 2.5)
                        .padding(.bottom, 3)
                }
            }
            .background(
                mode == .locked
                    ? RCColor.accent
                    : (mode == .sticky ? RCColor.accent.opacity(0.32) : Color.white.opacity(0.13)),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(mode == .sticky ? RCColor.accent : .white.opacity(0.08), lineWidth: 1)
            }
        }
        .foregroundStyle(.white)
        .accessibilityLabel("\(mod.1)\(mode == .locked ? "，已锁定" : (mode == .sticky ? "，单次生效" : ""))")
    }

    private func typingButton(height: CGFloat) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            typing.toggle()
        } label: {
            HStack(spacing: 4) {
                RabbitIcon(.keyboard, size: 14)
                Text(typing ? "收键盘" : "打字")
            }
            .font(isLandscape ? .caption.bold() : .subheadline.weight(.medium))
            .frame(height: height)
            .padding(.horizontal, 9)
            .background(typing ? RCColor.accent : Color.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(.white.opacity(0.08), lineWidth: 1)
            }
        }
        .foregroundStyle(.white)
        .accessibilityIdentifier("sessionbar.typing")
    }

    private func keyButton(_ key: (String, String, UInt16), height: CGFloat) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            tap(key.2)
        } label: {
            Text(key.0)
                .font(isLandscape ? .caption.bold() : .subheadline.weight(.medium))
                .frame(minWidth: isLandscape ? 32 : 36, minHeight: height)
                .padding(.horizontal, isLandscape ? 5 : 6)
                .background(Color.white.opacity(0.13), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(.white.opacity(0.07), lineWidth: 1)
                }
        }
        .foregroundStyle(.white)
        .accessibilityLabel(key.1)
    }

    private func comboButton(_ combo: (String, UInt16, [UInt16]), height: CGFloat) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            session.tapKey(combo.1, modifiers: combo.2)
        } label: {
            Text(combo.0)
                .font((isLandscape ? Font.caption : Font.subheadline).monospaced().weight(.medium))
                .frame(minWidth: isLandscape ? 42 : 48, minHeight: height)
                .padding(.horizontal, 6)
                .background(RCColor.accent.opacity(0.20), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(RCColor.accent.opacity(0.35), lineWidth: 1)
                }
        }
        .foregroundStyle(.white)
    }

    private func handleTypedChunk(_ chunk: String) {
        var unsupportedBuffer = ""
        for ch in chunk {
            if ch == "\n" || ch == "\r" {
                tap(0x1c)
            } else if let strokes = RemoteKeys.strokes(for: String(ch)) {
                for stroke in strokes {
                    session.tapKey(stroke.key, modifiers: stroke.shift ? [0x2a] : [])
                }
            } else {
                unsupportedBuffer.append(ch)
            }
        }
        if !unsupportedBuffer.isEmpty {
            let pasteMod: UInt16 = prefersPC ? 0x1d : 0xe05b
            let pasteHint = prefersPC ? "Ctrl+V" : "⌘V"
            if session.clipboardEnabled, session.sendClipboard(unsupportedBuffer) {
                ToastCenter.shared.show("中文/特殊文本已同步至远端剪贴板，可按 \(pasteHint) 粘贴")
                _ = pasteMod
            } else {
                ToastCenter.shared.show("中文请先在「控制 → 文本剪贴板」开启同步后自动传输")
            }
        }
    }

    private func tap(_ key: UInt16) {
        session.tapKey(key)
    }
}
