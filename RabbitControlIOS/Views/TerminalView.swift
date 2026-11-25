import SwiftUI

/// 真实终端:通过工具通道在远端开 PTY,输出滚动显示,底部输入行发送击键。
/// 依赖活动会话(SessionService 已建连);无会话时降级提示。
struct TerminalView: View {
    @State private var startedAt = Date.now
    @State private var input = ""
    @State private var tools = ToolService.shared
    @State private var session = SessionService.shared

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(hex: 0x1E1E20).ignoresSafeArea()

            VStack(spacing: 0) {
                // 输出区
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(tools.terminalOutput.isEmpty ? "连接中…" : tools.terminalOutput)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Color(hex: 0xD4D4D4))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.top, 8)
                            .textSelection(.enabled)
                            .id("output")
                    }
                    .onChange(of: tools.terminalOutput) {
                        withAnimation { proxy.scrollTo("output", anchor: .bottom) }
                    }
                }

                // 输入行
                HStack(spacing: 8) {
                    Text(">")
                        .foregroundStyle(RCColor.online)
                    TextField("命令", text: $input)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(.white)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onSubmit { sendInput() }
                        .accessibilityIdentifier("terminal.input")
                    Button("发送") { sendInput() }
                        .font(.system(size: 13))
                        .foregroundStyle(RCColor.accent)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color(hex: 0x2A2A2C))
            }

            // 右上计时
            TimelineView(.periodic(from: startedAt, by: 1)) { context in
                Text(elapsed(at: context.date))
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundStyle(Color(hex: 0x98989D))
            }
            .frame(maxWidth: .infinity, alignment: .topTrailing)
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .navigationTitle("终端")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .onAppear {
            AppChrome.shared.tabBarHidden = true
            guard let sid = session.sessionID else { return }
            tools.start(sessionID: sid)
            if tools.termID == nil {
                tools.terminalOpen(sessionID: sid)
            }
        }
        .onDisappear {
            AppChrome.shared.tabBarHidden = false
            if let sid = session.sessionID {
                tools.terminalClose(sessionID: sid)
            }
            tools.stop()
        }
        .overlay {
            if session.sessionID == nil {
                ContentUnavailableView("需要活动会话", systemImage: "terminal",
                                       description: Text("请先进入远程桌面建立连接"))
            }
        }
    }

    private func sendInput() {
        guard !input.isEmpty, let sid = session.sessionID else { return }
        tools.terminalInput(sessionID: sid, text: input + "\n")
        input = ""
    }

    private func elapsed(at date: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(startedAt)))
        return String(format: "%02d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
    }
}
