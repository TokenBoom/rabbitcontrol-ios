import SwiftUI

/// 会话内键盘扩展条:修饰键自锁切换、功能键与组合键一键发送,可唤起软键盘逐字输入;横屏下合并为单行紧凑条避免遮挡画面。
struct SessionKeyboardBar: View {
    var session: SessionService
    @Binding var expanded: Bool
    @State private var activeModifiers: Set<UInt16> = []
    @State private var typing = false
    @FocusState private var textFocused: Bool
    @State private var typed = ""
    @Environment(\.verticalSizeClass) private var verticalClass

    private var isLandscape: Bool { verticalClass == .compact }

    private let mods: [(String, UInt16)] = [("⌘", 0xe05b), ("⌃", 0x1d), ("⌥", 0x38), ("⇧", 0x2a)]
    private let keys: [(String, UInt16)] = [
        ("Esc", 1), ("Tab", 0x0f), ("F5", 0x3f), ("F11", 0x57), ("Del", 0xe053),
        ("←", 0xe04b), ("↑", 0xe048), ("↓", 0xe050), ("→", 0xe04d),
    ]
    private let combos: [(String, UInt16, [UInt16])] = [
        ("⌘C", 0x2e, [0xe05b]), ("⌘V", 0x2f, [0xe05b]), ("⌘Z", 0x2c, [0xe05b]),
        ("⌘A", 0x1e, [0xe05b]), ("⌘Tab", 0x0f, [0xe05b]), ("^C", 0x2e, [0x1d]),
    ]

    var body: some View {
        VStack(spacing: isLandscape ? 4 : 6) {
            if expanded {
                if isLandscape {
                    landscapeStrip
                } else {
                    portraitPanel
                }
            }
            // 隐藏的文本捕捉框:软键盘逐字上屏
            TextField("", text: $typed)
                .focused($textFocused)
                .frame(width: 1, height: 1).opacity(0.01)
                .autocorrectionDisabled().textInputAutocapitalization(.never)
                .onChange(of: typed) { _, newValue in
                    guard let ch = newValue.last else { typed = ""; return }
                    if let strokes = RemoteKeys.strokes(for: String(ch)) {
                        for stroke in strokes {
                            session.tapKey(stroke.key, modifiers: Array(activeModifiers) + (stroke.shift ? [0x2a] : []))
                        }
                    }
                    typed = ""
                }
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
                if !expanded { textFocused = false; typing = false }
            } label: {
                HStack(spacing: 5) {
                    RabbitIcon(.keyboard, size: isLandscape ? 13 : 15)
                    RabbitIcon(expanded ? .chevronDown : .chevronUp, size: 11)
                }.foregroundStyle(.white)
                .frame(width: isLandscape ? 64 : 74, height: isLandscape ? 24 : 30)
                .background(RCColor.hudBg, in: Capsule())
            }
            .accessibilityLabel(expanded ? "收起键盘扩展条" : "展开键盘扩展条")
            .accessibilityIdentifier("sessionbar.toggle")
        }
    }

    private var landscapeStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                typingButton(height: 30)
                Divider().frame(height: 18).overlay(.white.opacity(0.28))
                ForEach(mods, id: \.1) { modButton($0, width: 34, height: 30) }
                Divider().frame(height: 18).overlay(.white.opacity(0.28))
                ForEach(keys, id: \.1) { keyButton($0, height: 30) }
                Divider().frame(height: 18).overlay(.white.opacity(0.28))
                ForEach(combos, id: \.0) { comboButton($0, height: 30) }
            }
            .padding(.horizontal, 10)
        }
        .padding(.vertical, 6)
        .background(RCColor.hudBg, in: Capsule())
        .safeAreaPadding(.horizontal, 16)
    }

    private var portraitPanel: some View {
        VStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(mods, id: \.1) { modButton($0, width: 40, height: 34) }
                    Divider().frame(height: 22).overlay(.white.opacity(0.3))
                    typingButton(height: 34)
                }
                .padding(.horizontal, 10)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(keys, id: \.1) { keyButton($0, height: 34) }
                }
                .padding(.horizontal, 10)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(combos, id: \.0) { comboButton($0, height: 34) }
                }
                .padding(.horizontal, 10)
            }
        }
        .padding(.vertical, 10)
        .background(RCColor.hudBg, in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 10)
    }

    private func modButton(_ mod: (String, UInt16), width: CGFloat, height: CGFloat) -> some View {
        Button {
            if activeModifiers.contains(mod.1) { activeModifiers.remove(mod.1) }
            else { activeModifiers.insert(mod.1) }
        } label: {
            Text(mod.0).font(isLandscape ? .subheadline.bold() : .headline).frame(width: width, height: height)
                .background(activeModifiers.contains(mod.1) ? RCColor.accent : Color.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
        }.foregroundStyle(.white)
    }

    private func typingButton(height: CGFloat) -> some View {
        Button {
            typing.toggle()
            textFocused = typing
        } label: {
            HStack(spacing: 4) { RabbitIcon(.keyboard, size: 14); Text("打字") }
                .font(isLandscape ? .caption.bold() : .subheadline).frame(height: height).padding(.horizontal, 9)
                .background(typing ? RCColor.accent : Color.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
        }.foregroundStyle(.white)
        .accessibilityIdentifier("sessionbar.typing")
    }

    private func keyButton(_ key: (String, UInt16), height: CGFloat) -> some View {
        Button { tap(key.1) } label: {
            Text(key.0).font(isLandscape ? .caption.bold() : .subheadline).frame(minWidth: isLandscape ? 32 : 38, minHeight: height)
                .padding(.horizontal, isLandscape ? 4 : 0)
                .background(Color.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
        }.foregroundStyle(.white)
        .accessibilityLabel(key.0)
    }

    private func comboButton(_ combo: (String, UInt16, [UInt16]), height: CGFloat) -> some View {
        Button { session.tapKey(combo.1, modifiers: combo.2) } label: {
            Text(combo.0).font((isLandscape ? Font.caption : Font.subheadline).monospaced()).frame(minWidth: isLandscape ? 40 : 46, minHeight: height)
                .background(Color.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
        }.foregroundStyle(.white)
    }

    private func tap(_ key: UInt16) {
        session.tapKey(key, modifiers: Array(activeModifiers))
    }
}
