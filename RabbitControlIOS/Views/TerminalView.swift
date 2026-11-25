import SwiftUI

struct TerminalView: View {
    @State private var input = ""
    @State private var followOutput = true
    @State private var sendError: String?
    @State private var tools = ToolService.shared
    @State private var session = SessionService.shared
    private var ready: Bool { session.isConnected && tools.termID != nil && !tools.terminalExited }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(tools.terminals) { tab in
                        HStack(spacing: 4) {
                            Button { tools.terminalSelect(tab.id) } label: {
                                Text("终端 #\(tab.index)\(tab.exited ? " · 已退出" : "")").font(.caption.monospaced())
                            }
                            Button {
                                if let sid = session.sessionID { tools.terminalClose(sessionID: sid, termID: tab.id) }
                            } label: { RabbitIcon(.close, size: 10).frame(width: 20, height: 20) }
                                .accessibilityLabel("关闭终端 #\(tab.index)")
                        }
                        .padding(.leading, 10).padding(.trailing, 4).frame(height: 30)
                        .background(tab.id == tools.activeTermID ? RCColor.accent : Color.white.opacity(0.1), in: Capsule())
                    }
                    Button { newTerminal() } label: {
                        HStack(spacing: 4) { RabbitIcon(.plus, size: 12); Text("新终端").font(.caption) }
                            .padding(.horizontal, 10).frame(height: 30)
                            .background(Color.white.opacity(0.1), in: Capsule())
                    }.disabled(!session.isConnected)
                    .accessibilityIdentifier("terminal.new")
                }.padding(.horizontal, 10).padding(.vertical, 6).foregroundStyle(.white)
            }.background(Color(hex: 0x2A2A2C))
            ScrollViewReader { proxy in
                ScrollView {
                    Text(tools.terminalOutput.isEmpty ? (tools.lastError ?? "等待终端输出…") : tools.terminalOutput)
                        .font(.footnote.monospaced()).foregroundStyle(.white)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                        .textSelection(.enabled)
                    Color.clear.frame(height: 1).id("tail")
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: tools.terminalOutput) { if followOutput { proxy.scrollTo("tail", anchor: .bottom) } }
                .onChange(of: followOutput) { if followOutput { proxy.scrollTo("tail", anchor: .bottom) } }
            }
            if tools.terminalExited || tools.lastError != nil && tools.termID == nil {
                HStack {
                    Text(tools.terminalExited ? "终端已退出" : "未连接到终端").font(.callout)
                    Button("重新打开终端") { open() }.buttonStyle(.bordered).disabled(!session.isConnected)
                }.foregroundStyle(.white)
            }
            if let sendError { Text(sendError).font(.footnote).foregroundStyle(.white) }
            HStack(spacing: 8) {
                ForEach([("Ctrl+C", "\u{03}"), ("Ctrl+D", "\u{04}"), ("Tab", "\t"), ("↑", "\u{1b}[A"), ("↓", "\u{1b}[B"), ("Esc", "\u{1b}")], id: \.0) { key in
                    Button(key.0) {
                        if let sid = session.sessionID, ready { _ = tools.terminalInput(sessionID: sid, text: key.1) }
                    }.font(.caption.monospaced()).buttonStyle(.bordered).disabled(!ready)
                }
                Spacer(minLength: 0)
            }.padding(.horizontal, 10).padding(.top, 6).background(Color(hex: 0x2A2A2C))
            HStack(spacing: 8) {
                RabbitIcon(.chevronRight, size: 14).foregroundStyle(.green)
                TextField("命令", text: $input).font(.body.monospaced()).textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                    .disabled(!ready).submitLabel(.send).onSubmit(sendInput)
                    .accessibilityIdentifier("terminal.input")
                Button("发送", action: sendInput).buttonStyle(.borderedProminent)
                    .disabled(input.isEmpty || !ready)
            }.padding(10).background(Color(hex: 0x2A2A2C))
        }
        .environment(\.colorScheme, .dark)
        .background(Color(hex: 0x1E1E20).ignoresSafeArea())
        .navigationTitle("终端").navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            Toggle(isOn: $followOutput) { Label("跟随最新输出", rabbitIcon: .terminalFollow) }
                .toggleStyle(.button).accessibilityLabel("跟随最新输出")
        }
        .onAppear {
            guard let sid = session.sessionID else { return }
            tools.start(sessionID: sid)
            if tools.termID == nil { open() }
        }
        .onDisappear {
            if let sid = session.sessionID { tools.terminalCloseAll(sessionID: sid) }
            tools.stop()
        }
    }

    /// 重开当前标签(已退出或失败时)。
    private func open() {
        guard let sid = session.sessionID else { return }
        sendError = nil
        if tools.termID != nil { tools.terminalClose(sessionID: sid) }
        tools.terminalOpen(sessionID: sid)
    }

    private func newTerminal() {
        guard let sid = session.sessionID else { return }
        sendError = nil
        tools.terminalOpen(sessionID: sid)
    }

    private func sendInput() {
        guard ready, !input.isEmpty, let sid = session.sessionID else { return }
        if tools.terminalInput(sessionID: sid, text: input + "\n") { sendError = nil; input = "" }
        else { sendError = "发送失败，已保留输入。请检查连接后重试。" }
    }
}
