import SwiftUI

/// 终端窗口(W3 移动端适配):深色静态壳,prompt + 闪烁光标 + 右上计时。
/// 真实 PTY 属后续版本,本期为 mock。
struct TerminalView: View {
    @State private var startedAt = Date.now
    @State private var cursorVisible = true

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(hex: 0x1E1E20).ignoresSafeArea()

            // prompt 行:[host] [path] ~ >
            HStack(spacing: 6) {
                tag("[host]")
                tag("[path]")
                Text("~")
                    .foregroundStyle(RCColor.accent)
                Text(">")
                    .foregroundStyle(RCColor.online)
                Rectangle()
                    .fill(RCColor.accent)
                    .frame(width: 10, height: 18)
                    .opacity(cursorVisible ? 1 : 0)
                    .onAppear {
                        withAnimation(.easeInOut(duration: 0.4).repeatForever(autoreverses: true)) {
                            cursorVisible = false
                        }
                    }
                Spacer()
            }
            .font(.system(size: 13, design: .monospaced))
            .padding(.horizontal, 16)
            .padding(.top, 24)

            // 右上计时
            TimelineView(.periodic(from: startedAt, by: 1)) { context in
                Text(elapsed(at: context.date))
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundStyle(Color(hex: 0x98989D))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .padding(.horizontal, 16)
            .padding(.top, 24)
        }
        .navigationTitle("session1")
        .onAppear { AppChrome.shared.tabBarHidden = true }
        .onDisappear { AppChrome.shared.tabBarHidden = false }

        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(Color(hex: 0x98989D))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color(hex: 0x98989D), lineWidth: 1)
            }
    }

    private func elapsed(at date: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(startedAt)))
        return String(format: "%02d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
    }
}
