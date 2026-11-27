import SwiftUI

struct RemoteKeyboard: View {
    var session: SessionService
    var deviceKind: Device.Kind? = nil
    @State private var text = ""
    @State private var modifier: UInt16 = 0
    @State private var feedback: String?

    private struct SystemShortcut: Identifiable {
        let title: String
        let key: UInt16
        let modifiers: [UInt16]
        var id: String { title }
    }

    private var prefersPC: Bool {
        session.prefersPCShortcuts(deviceKind: deviceKind)
    }

    private var systemShortcuts: [SystemShortcut] {
        if prefersPC {
            return [
                SystemShortcut(title: "复制 Ctrl+C", key: 0x2e, modifiers: [0x1d]),
                SystemShortcut(title: "粘贴 Ctrl+V", key: 0x2f, modifiers: [0x1d]),
                SystemShortcut(title: "撤销 Ctrl+Z", key: 0x2c, modifiers: [0x1d]),
                SystemShortcut(title: "全选 Ctrl+A", key: 0x1e, modifiers: [0x1d]),
                SystemShortcut(title: "切换窗口 Alt+Tab", key: 0x0f, modifiers: [0x38]),
                SystemShortcut(title: "显示桌面 Win+D", key: 0x20, modifiers: [0xe05b]),
                SystemShortcut(title: "任务管理器 ⌃⇧Esc", key: 0x01, modifiers: [0x1d, 0x2a]),
                SystemShortcut(title: "关闭窗口 Alt+F4", key: 0x3e, modifiers: [0x38]),
                SystemShortcut(title: "锁定屏幕 Win+L", key: 0x26, modifiers: [0xe05b]),
            ]
        }
        return [
            SystemShortcut(title: "拷贝 ⌘C", key: 0x2e, modifiers: [0xe05b]),
            SystemShortcut(title: "粘贴 ⌘V", key: 0x2f, modifiers: [0xe05b]),
            SystemShortcut(title: "撤销 ⌘Z", key: 0x2c, modifiers: [0xe05b]),
            SystemShortcut(title: "全选 ⌘A", key: 0x1e, modifiers: [0xe05b]),
            SystemShortcut(title: "切换应用 ⌘Tab", key: 0x0f, modifiers: [0xe05b]),
            SystemShortcut(title: "聚焦搜索 ⌘Space", key: 0x39, modifiers: [0xe05b]),
            SystemShortcut(title: "强制退出 ⌥⌘Esc", key: 0x01, modifiers: [0x38, 0xe05b]),
            SystemShortcut(title: "全屏截屏 ⇧⌘3", key: 0x04, modifiers: [0x2a, 0xe05b]),
            SystemShortcut(title: "锁定屏幕 ⌃⌘Q", key: 0x10, modifiers: [0x1d, 0xe05b]),
        ]
    }

    private var strokes: [RemoteKeys.Stroke]? {
        guard text.count <= 80 else { return nil }
        return RemoteKeys.strokes(for: text)
    }

    var body: some View {
        Form {
            Section("发送按键") {
                Picker("组合键", selection: $modifier) {
                    let modOptions: [(String, UInt16)] = [
                        ("无", 0),
                        (prefersPC ? "Win" : "⌘", 0xe05b),
                        ("⌃", 0x1d),
                        (prefersPC ? "Alt" : "⌥", 0x38),
                        ("⇧", 0x2a),
                    ]
                    ForEach(modOptions, id: \.1) {
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
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 102))]) {
                    ForEach(systemShortcuts) { shortcut in
                        Button {
                            session.tapKey(shortcut.key, modifiers: shortcut.modifiers)
                            feedback = "已发送「\(shortcut.title)」。"
                        } label: {
                            Text(shortcut.title).font(.subheadline).lineLimit(1).minimumScaleFactor(0.8)
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            } header: { Text("常用系统组合键") } footer: { Text("自动适配被控端系统常用组合键，点击直接发送至被控端。") }
            Section("功能键") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 65))]) {
                    ForEach([("Esc", UInt16(1)), ("Tab", 0x0f), ("退格", 0x0e), ("回车", 0x1c),
                             ("←", 0xe04b), ("↑", 0xe048), ("↓", 0xe050), ("→", 0xe04d),
                             ("Home", 0xe047), ("End", 0xe04f), ("PgUp", 0xe049), ("PgDn", 0xe051)], id: \.1) { key in
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
