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
            if let sid = session.sessionID { tools.terminalClose(sessionID: sid) }
            tools.stop()
        }
    }

    private func open() {
        guard let sid = session.sessionID else { return }
        sendError = nil
        if tools.termID != nil { tools.terminalClose(sessionID: sid) }
        tools.terminalOpen(sessionID: sid)
    }

    private func sendInput() {
        guard ready, !input.isEmpty, let sid = session.sessionID else { return }
        if tools.terminalInput(sessionID: sid, text: input + "\n") { sendError = nil; input = "" }
        else { sendError = "发送失败，已保留输入。请检查连接后重试。" }
    }
}
