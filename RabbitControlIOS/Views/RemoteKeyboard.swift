import SwiftUI

struct RemoteKeyboard: View {
    var session: SessionService
    @State private var text = ""
    @State private var modifier: UInt16 = 0
    @State private var feedback: String?
    private var strokes: [RemoteKeys.Stroke]? {
        guard text.count <= 80 else { return nil }
        return RemoteKeys.strokes(for: text)
    }

    var body: some View {
        Form {
            Section("发送按键") {
                Picker("组合键", selection: $modifier) {
                    ForEach([("无", UInt16(0)), ("⌘", 0xe05b), ("⌃", 0x1d), ("⌥", 0x38), ("⇧", 0x2a)], id: \.1) {
                        Text($0.0).tag($0.1)
                    }
                }.pickerStyle(.segmented)
                TextField("按美式键位输入", text: $text)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .submitLabel(.send).onSubmit(send)
                LabeledContent("字符数", value: "\(text.count) / 80").font(.caption)
                Button("发送到远端", action: send).disabled(text.isEmpty || strokes == nil)
                if strokes == nil { Text("每次最多 80 个美式键位字符；中文等文本请返回会话控制，使用文本剪贴板。").font(.footnote) }
                else if let feedback, text.isEmpty { Text(feedback).font(.footnote).foregroundStyle(.secondary) }
            }
            Section {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96))]) {
                    ForEach([("拷贝 ⌘C", UInt16(0x2e)), ("粘贴 ⌘V", 0x2f), ("撤销 ⌘Z", 0x2c), ("全选 ⌘A", 0x1e),
                             ("切换 App ⌘Tab", 0x0f), ("聚焦搜索 ⌘空格", 0x39)], id: \.1) { shortcut in
                        Button {
                            session.tapKey(shortcut.1, modifiers: [0xe05b])
                            feedback = "已发送「\(shortcut.0)」。"
                        } label: {
                            Text(shortcut.0).font(.subheadline).lineLimit(1).minimumScaleFactor(0.8)
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            } header: { Text("常用快捷键") } footer: { Text("按 Mac 快捷键发送，不使用上方选择的组合键。") }
            Section("功能键") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 65))]) {
                    ForEach([("Esc", UInt16(1)), ("Tab", 0x0f), ("退格", 0x0e), ("回车", 0x1c),
                             ("←", 0xe04b), ("↑", 0xe048), ("↓", 0xe050), ("→", 0xe04d)], id: \.1) { key in
                        Button { session.tapKey(key.1, modifiers: modifiers(shift: false)) } label: {
                            Text(key.0).frame(maxWidth: .infinity, minHeight: 44)
                        }
                            .buttonStyle(.bordered)
                    }
                }
            }
        }.navigationTitle("远程键盘").scrollDismissesKeyboard(.interactively)
    }

    private func send() {
        guard !text.isEmpty, let strokes else { return }
        for stroke in strokes { session.tapKey(stroke.key, modifiers: modifiers(shift: stroke.shift)) }
        feedback = "已将 \(text.count) 个字符交给会话发送。"
        text = ""
    }

    private func modifiers(shift: Bool) -> [UInt16] {
        (modifier == 0 ? [] : [modifier]) + (shift && modifier != 0x2a ? [0x2a] : [])
    }
}
