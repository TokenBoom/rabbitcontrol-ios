import SwiftUI

/// 会话内键盘扩展条:修饰键自锁切换、功能键与组合键一键发送,可唤起软键盘逐字输入。
struct SessionKeyboardBar: View {
    var session: SessionService
    @Binding var expanded: Bool
    @State private var activeModifiers: Set<UInt16> = []
    @State private var typing = false
    @FocusState private var textFocused: Bool
    @State private var typed = ""

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
        VStack(spacing: 6) {
            if expanded {
                VStack(spacing: 8) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(mods, id: \.1) { mod in
                                Button {
                                    if activeModifiers.contains(mod.1) { activeModifiers.remove(mod.1) }
                                    else { activeModifiers.insert(mod.1) }
                                } label: {
                                    Text(mod.0).font(.headline).frame(width: 40, height: 34)
                                        .background(activeModifiers.contains(mod.1) ? RCColor.accent : Color.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
                                }.foregroundStyle(.white)
                            }
                            Divider().frame(height: 22).overlay(.white.opacity(0.3))
                            Button {
                                typing.toggle()
                                textFocused = typing
                            } label: {
                                HStack(spacing: 4) { RabbitIcon(.keyboard, size: 15); Text("打字") }
                                    .font(.subheadline).frame(height: 34).padding(.horizontal, 10)
                                    .background(typing ? RCColor.accent : Color.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
                            }.foregroundStyle(.white)
                            .accessibilityIdentifier("sessionbar.typing")
                        }
                        .padding(.horizontal, 10)
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(keys, id: \.1) { key in
                                Button { tap(key.1) } label: {
                                    Text(key.0).font(.subheadline).frame(minWidth: 38, minHeight: 34)
                                        .background(Color.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
                                }.foregroundStyle(.white)
                                .accessibilityLabel(key.0)
                            }
                        }
                        .padding(.horizontal, 10)
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(combos, id: \.0) { combo in
                                Button { session.tapKey(combo.1, modifiers: combo.2) } label: {
                                    Text(combo.0).font(.subheadline.monospaced()).frame(minWidth: 46, minHeight: 34)
                                        .background(Color.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
                                }.foregroundStyle(.white)
                            }
                        }
                        .padding(.horizontal, 10)
                    }
                }
                .padding(.vertical, 10)
                .background(RCColor.hudBg, in: RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal, 10)
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
                HStack(spacing: 6) {
                    RabbitIcon(.keyboard, size: 15)
                    RabbitIcon(expanded ? .chevronDown : .chevronUp, size: 12)
                }.foregroundStyle(.white)
                .frame(width: 74, height: 30)
                .background(RCColor.hudBg, in: Capsule())
            }
            .accessibilityLabel(expanded ? "收起键盘扩展条" : "展开键盘扩展条")
            .accessibilityIdentifier("sessionbar.toggle")
        }
    }

    private func tap(_ key: UInt16) {
        session.tapKey(key, modifiers: Array(activeModifiers))
    }
}
