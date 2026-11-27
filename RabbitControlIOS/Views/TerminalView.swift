import SwiftUI
import UIKit

/// 远程终端系统解锁密码钥匙串辅助（按设备 ID 独立加密存储，对齐基线 §7.2 `v0.2.1`）。
enum TerminalUnlockKeychainStore {
    private static func keychain(for deviceID: String) -> SessionKeychain {
        let clean = deviceID.replacingOccurrences(of: " ", with: "").lowercased()
        return SessionKeychain(service: "com.rabbitcontrol.ios.termunlock.\(clean)")
    }

    static func loadPassword(for deviceID: String?) -> String? {
        guard let deviceID, !deviceID.isEmpty,
              let data = try? keychain(for: deviceID).load(),
              let pwd = String(data: data, encoding: .utf8),
              !pwd.isEmpty else {
            return nil
        }
        return pwd
    }

    static func savePassword(_ password: String, for deviceID: String?) {
        guard let deviceID, !deviceID.isEmpty, !password.isEmpty else { return }
        try? keychain(for: deviceID).store(Data(password.utf8))
    }

    static func clearPassword(for deviceID: String?) {
        guard let deviceID, !deviceID.isEmpty else { return }
        try? keychain(for: deviceID).remove()
    }
}

/// W3 远程终端（对齐 macOS 基线 §7.2）：
/// - VT100/ANSI 色彩屏幕缓冲 + 实时单键流式交互输入（支持 `vim` / `htop` / `sudo` 无回显口令）；
/// - 最多 8 个后台 PTY 会话管理、重命名、字号调节与动态网格重算；
/// - 被控端处于锁屏或 `LoginWindow` 时弹出系统密码验证门禁（支持钥匙串记住/自动解锁）。
struct TerminalView: View {
    var initialDraftCommand: String? = nil

    @State private var input = ""
    @State private var rawKeyFocused = false
    @State private var followOutput = true
    @State private var sendError: String?
    @State private var viewportSize = CGSize.zero
    @AppStorage("terminal.fontSize") private var fontSize: Double = 13
    @State private var renamingTab: ToolService.TerminalTab?
    @State private var renameText = ""
    @State private var showSessionListSheet = false

    // 锁屏系统口令验证状态
    @State private var unlockPassword = ""
    @State private var rememberSystemPassword = false
    @State private var isUnlocking = false
    @State private var unlockUiError: RCUiError?
    @State private var didAttemptAutoUnlock = false

    @State private var tools = ToolService.shared
    @State private var session = SessionService.shared

    private var terminalAllowed: Bool { session.toolPermissions.allowTerminal }
    private var isHostTerminalLocked: Bool {
        guard let lock = session.terminalLockState else { return false }
        return lock.required && !lock.unlocked
    }
    private var ready: Bool {
        session.isConnected && terminalAllowed && !isHostTerminalLocked && tools.termID != nil && !tools.terminalExited
    }

    var body: some View {
        Group {
            if !terminalAllowed {
                VStack {
                    RCInlineErrorView(
                        error: CoreClient.resolveUiError(code: RCErrorCodes.toolForbidden),
                        onDarkStage: true
                    )
                    .padding(20)
                    Spacer()
                }
            } else if isHostTerminalLocked {
                terminalLockGateView
            } else {
                activeTerminalWorkspace
            }
        }
        .environment(\.colorScheme, .dark)
        .background(Color(hex: 0x1E1E20).ignoresSafeArea())
        .navigationTitle("终端").navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Button {
                        adjustFontSize(-1)
                    } label: {
                        Label("缩小字号", systemImage: "textformat.size.smaller")
                    }
                    .disabled(fontSize <= 10)

                    Button {
                        adjustFontSize(1)
                    } label: {
                        Label("放大字号", systemImage: "textformat.size.larger")
                    }
                    .disabled(fontSize >= 20)

                    Divider()

                    Button {
                        showSessionListSheet = true
                    } label: {
                        Label("会话列表 (\(tools.terminals.count)/8)", rabbitIcon: .terminal)
                    }

                    if let active = tools.activeTerminal {
                        Button {
                            renameText = active.displayTitle
                            renamingTab = active
                        } label: {
                            Label("重命名当前终端", rabbitIcon: .pencil)
                        }
                    }

                    if TerminalUnlockKeychainStore.loadPassword(for: session.targetDeviceID) != nil {
                        Divider()
                        Button(role: .destructive) {
                            TerminalUnlockKeychainStore.clearPassword(for: session.targetDeviceID)
                            ToastCenter.shared.show("已清除本机保存的远端系统密码")
                        } label: {
                            Label("清除已存系统解锁密码", rabbitIcon: .trash)
                        }
                    }
                } label: {
                    RabbitIcon(.ellipsis, size: 19)
                }
                .accessibilityLabel("终端选项")
                .accessibilityIdentifier("terminal.options")

                Toggle(isOn: $followOutput) { Label("跟随最新输出", rabbitIcon: .terminalFollow) }
                    .toggleStyle(.button).accessibilityLabel("跟随最新输出")
            }
        }
        .alert(
            "重命名终端会话",
            isPresented: Binding(get: { renamingTab != nil }, set: { if !$0 { renamingTab = nil } })
        ) {
            TextField("会话名称", text: $renameText)
            Button("取消", role: .cancel) { renamingTab = nil }
            Button("保存") {
                if let tab = renamingTab, let sid = session.sessionID {
                    tools.terminalRename(sessionID: sid, termID: tab.id, name: renameText)
                }
                renamingTab = nil
            }
            .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .sheet(isPresented: $showSessionListSheet) {
            terminalSessionListSheet
        }
        .onAppear {
            if let initialDraftCommand, input.isEmpty {
                input = initialDraftCommand
            }
            guard let sid = session.sessionID else { return }
            tryAutoUnlockIfNeeded(sessionID: sid)
            let grid = ToolService.calculateTerminalGrid(viewportSize: viewportSize, fontSize: fontSize)
            tools.terminalConnectOrOpen(sessionID: sid, cols: grid.cols, rows: grid.rows)
        }
        .onChange(of: session.terminalLockState) { _, newState in
            if newState?.required == true, newState?.unlocked == false, let sid = session.sessionID {
                tryAutoUnlockIfNeeded(sessionID: sid)
            }
        }
        .onDisappear {
            rawKeyFocused = false
            // 仅分离输出流，保留远端后台持久化终端继续运行；点击标签 × 才会真正终止进程。
            if let sid = session.sessionID {
                tools.terminalDetachAll(sessionID: sid)
            }
        }
    }

    // MARK: - 活跃终端主界面

    private var activeTerminalWorkspace: some View {
        VStack(spacing: 0) {
            tabStripBar

            if let cwd = tools.activeTerminal?.cwd, !cwd.isEmpty {
                HStack(spacing: 6) {
                    RabbitIcon(.folder, size: 12)
                        .foregroundStyle(.white.opacity(0.55))
                    Text(cwd)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.white.opacity(0.65))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    if let active = tools.activeTerminal {
                        Text("\(active.cols)×\(active.rows) · \(Int(fontSize))pt")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.white.opacity(0.4))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(Color(hex: 0x232325))
            }

            // 隐藏的流式键盘捕捉框：点击终端画布即可唤起直接按键流输入（支持中文拼音预输入、原生退格与外接键盘控制键，适配 vim / sudo 口令）
            IMECapableKeyCaptureField(
                isFocused: $rawKeyFocused,
                onCommitText: { chunk in
                    if let sid = session.sessionID, ready {
                        _ = tools.terminalInput(sessionID: sid, text: chunk)
                    }
                },
                onBackspace: {
                    if let sid = session.sessionID, ready {
                        _ = tools.terminalInput(sessionID: sid, text: "\u{7f}")
                    }
                },
                onReturn: {
                    if let sid = session.sessionID, ready {
                        _ = tools.terminalInput(sessionID: sid, text: "\r")
                    }
                },
                onTerminalControlSequence: { seq in
                    if let sid = session.sessionID, ready {
                        _ = tools.terminalInput(sessionID: sid, text: seq)
                    }
                }
            )
            .frame(width: 1, height: 1)
            .opacity(0.01)
            .allowsHitTesting(false)

            ScrollViewReader { proxy in
                ScrollView {
                    Group {
                        if let active = tools.activeTerminal, !active.output.isEmpty {
                            Text(active.screen.renderAttributedString())
                        } else {
                            Text(tools.lastError ?? "等待终端输出…")
                                .foregroundStyle(.white.opacity(0.65))
                        }
                    }
                    .font(.system(size: fontSize, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .textSelection(.enabled)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if ready {
                            rawKeyFocused.toggle()
                        }
                    }

                    Color.clear.frame(height: 1).id("tail")
                }
                .scrollDismissesKeyboard(.interactively)
                .onGeometryChange(for: CGSize.self) { geo in
                    geo.size
                } action: { newSize in
                    viewportSize = newSize
                    syncGridSize(newSize)
                }
                .onChange(of: tools.terminalOutput) { if followOutput { proxy.scrollTo("tail", anchor: .bottom) } }
                .onChange(of: followOutput) { if followOutput { proxy.scrollTo("tail", anchor: .bottom) } }
            }

            if tools.terminalExited || tools.lastError != nil && tools.termID == nil {
                HStack {
                    Text(tools.terminalExited ? "终端已退出" : "未连接到终端").font(.callout)
                    Button("重新打开终端") { reopenActive() }.buttonStyle(.bordered).disabled(!session.isConnected)
                }
                .padding(.vertical, 4)
                .foregroundStyle(.white)
            }
            if let sendError { Text(sendError).font(.footnote).foregroundStyle(.white) }

            quickControlKeysBar
            commandInputBar
        }
    }

    private var tabStripBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(tools.terminals) { tab in
                    HStack(spacing: 4) {
                        Button {
                            tools.terminalSelect(tab.id, sessionID: session.sessionID)
                        } label: {
                            Text("\(tab.displayTitle)\(tab.exited ? " · 已退出" : "")")
                                .font(.caption.monospaced())
                                .lineLimit(1)
                        }
                        .contextMenu {
                            Button {
                                renameText = tab.displayTitle
                                renamingTab = tab
                            } label: {
                                Label("重命名", rabbitIcon: .pencil)
                            }
                            Button(role: .destructive) {
                                if let sid = session.sessionID { tools.terminalClose(sessionID: sid, termID: tab.id) }
                            } label: {
                                Label("终止会话", rabbitIcon: .trash)
                            }
                        }

                        Button {
                            if let sid = session.sessionID { tools.terminalClose(sessionID: sid, termID: tab.id) }
                        } label: {
                            RabbitIcon(.close, size: 10).frame(width: 20, height: 20)
                        }
                        .accessibilityLabel("关闭\(tab.displayTitle)")
                    }
                    .padding(.leading, 10).padding(.trailing, 4).frame(height: 30)
                    .background(tab.id == tools.activeTermID ? RCColor.accent : Color.white.opacity(0.1), in: Capsule())
                }
                Button { newTerminal() } label: {
                    HStack(spacing: 4) { RabbitIcon(.plus, size: 12); Text("新终端").font(.caption) }
                        .padding(.horizontal, 10).frame(height: 30)
                        .background(Color.white.opacity(0.1), in: Capsule())
                }
                .disabled(!session.isConnected || !terminalAllowed || tools.terminals.filter({ !$0.exited }).count >= 8)
                .accessibilityIdentifier("terminal.new")
            }
            .padding(.horizontal, 10).padding(.vertical, 6).foregroundStyle(.white)
        }
        .background(Color(hex: 0x2A2A2C))
    }

    private var quickControlKeysBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Button {
                    rawKeyFocused.toggle()
                } label: {
                    Text(rawKeyFocused ? "收起直输" : "直输键入")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .tint(rawKeyFocused ? RCColor.accent : .white)
                .disabled(!ready)

                ForEach([
                    ("Ctrl+C", "\u{03}"),
                    ("Ctrl+D", "\u{04}"),
                    ("Ctrl+Z", "\u{1a}"),
                    ("Ctrl+L", "\u{0c}"),
                    ("Tab", "\t"),
                    ("↑", "\u{1b}[A"),
                    ("↓", "\u{1b}[B"),
                    ("←", "\u{1b}[D"),
                    ("→", "\u{1b}[C"),
                    ("Esc", "\u{1b}"),
                ], id: \.0) { key in
                    Button(key.0) {
                        if let sid = session.sessionID, ready { _ = tools.terminalInput(sessionID: sid, text: key.1) }
                    }
                    .font(.caption.monospaced()).buttonStyle(.bordered).disabled(!ready)
                }
            }
            .padding(.horizontal, 10)
        }
        .padding(.top, 6)
        .background(Color(hex: 0x2A2A2C))
    }

    private var commandInputBar: some View {
        HStack(spacing: 8) {
            RabbitIcon(.chevronRight, size: 14).foregroundStyle(.green)
            TextField("输入整行命令发送（或点上方「直输键入」交互）", text: $input)
                .font(.body.monospaced())
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .disabled(!ready)
                .submitLabel(.send)
                .onSubmit(sendInput)
                .accessibilityIdentifier("terminal.input")
            Button("发送", action: sendInput)
                .buttonStyle(.borderedProminent)
                .disabled(input.isEmpty || !ready)
        }
        .padding(10)
        .background(Color(hex: 0x2A2A2C))
    }

    // MARK: - 锁屏状态系统口令验证门禁（§7.2 `v0.2.1`）

    private var terminalLockGateView: some View {
        let username = session.terminalLockState?.username ?? "系统登录账户"
        let retryAfter = session.lastTerminalUnlockResult?.retryAfterSecs
            ?? session.terminalLockState?.retryAfterSecs
            ?? 0

        return ScrollView {
            VStack(spacing: 18) {
                RabbitIcon(.lock, size: 26)
                    .foregroundStyle(RCColor.warning)
                    .frame(width: 52, height: 52)
                    .background(RCColor.warning.opacity(0.16), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                VStack(spacing: 6) {
                    Text("验证远端系统密码")
                        .font(.title3.bold())
                        .foregroundStyle(.white)
                    Text("远端设备当前处于锁屏或登录窗口状态，请输入「\(username)」的系统登录口令以解锁远程终端。")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.70))
                        .multilineTextAlignment(.center)
                }

                VStack(alignment: .leading, spacing: 12) {
                    SecureField("远端系统账户密码", text: $unlockPassword)
                        .textContentType(.password)
                        .submitLabel(.go)
                        .onSubmit(submitUnlock)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 44)
                        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .foregroundStyle(.white)
                        .accessibilityIdentifier("terminal.unlockPassword")

                    Toggle("记住此设备系统密码（加密存入本机钥匙串）", isOn: $rememberSystemPassword)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.82))

                    if retryAfter > 0 {
                        Text("密码重试过快，请等待 \(retryAfter) 秒后再试。")
                            .font(.caption)
                            .foregroundStyle(RCColor.warning)
                    } else if let resultErr = session.lastTerminalUnlockResult?.error, !resultErr.isEmpty {
                        Text(resultErr)
                            .font(.caption)
                            .foregroundStyle(RCColor.danger)
                    } else if let unlockUiError {
                        RCInlineErrorView(error: unlockUiError, onDarkStage: true)
                    }

                    Button(action: submitUnlock) {
                        HStack(spacing: 8) {
                            if isUnlocking { ProgressView().tint(.white).controlSize(.small) }
                            Text(isUnlocking ? "正在验证…" : "验证并打开终端")
                                .fontWeight(.semibold)
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(
                            unlockPassword.isEmpty || isUnlocking ? RCColor.accent.opacity(0.4) : RCColor.accent,
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(unlockPassword.isEmpty || isUnlocking)
                    .accessibilityIdentifier("terminal.unlockSubmit")
                }
                .padding(18)
                .background(RCColor.hudBg, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                }
            }
            .frame(maxWidth: 380)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - 会话列表管理弹层（浅色会话列表对标 §7.2）

    private var terminalSessionListSheet: some View {
        NavigationStack {
            List {
                Section("活跃与持久化 PTY 会话（\(tools.terminals.count)/8）") {
                    ForEach(tools.terminals) { tab in
                        HStack {
                            Button {
                                tools.terminalSelect(tab.id, sessionID: session.sessionID)
                                showSessionListSheet = false
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 6) {
                                        Text(tab.displayTitle)
                                            .font(.headline)
                                        if tab.id == tools.activeTermID {
                                            Text("当前")
                                                .font(.caption2.weight(.semibold))
                                                .foregroundStyle(RCColor.accent)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(RCColor.accent.opacity(0.12), in: Capsule())
                                        }
                                    }
                                    Text("\(tab.cwd ?? "~") · \(tab.cols)×\(tab.rows)\(tab.exited ? " · 已退出" : "")")
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)

                            Spacer()

                            Menu {
                                Button {
                                    showSessionListSheet = false
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                        renameText = tab.displayTitle
                                        renamingTab = tab
                                    }
                                } label: {
                                    Label("重命名", rabbitIcon: .pencil)
                                }
                                Button(role: .destructive) {
                                    if let sid = session.sessionID {
                                        tools.terminalClose(sessionID: sid, termID: tab.id)
                                    }
                                } label: {
                                    Label("终止会话", rabbitIcon: .trash)
                                }
                            } label: {
                                RabbitIcon(.ellipsis, size: 18)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 32, height: 32)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle("终端会话列表")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { showSessionListSheet = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - 动作处理

    private func tryAutoUnlockIfNeeded(sessionID: UInt64) {
        guard isHostTerminalLocked, !didAttemptAutoUnlock else { return }
        guard let saved = TerminalUnlockKeychainStore.loadPassword(for: session.targetDeviceID) else { return }
        didAttemptAutoUnlock = true
        isUnlocking = true
        Task {
            defer { isUnlocking = false }
            if case .success = await tools.submitTerminalUnlock(sessionID: sessionID, password: saved) {
                let grid = ToolService.calculateTerminalGrid(viewportSize: viewportSize, fontSize: fontSize)
                tools.terminalConnectOrOpen(sessionID: sessionID, cols: grid.cols, rows: grid.rows)
            }
        }
    }

    private func submitUnlock() {
        guard !unlockPassword.isEmpty, !isUnlocking, let sid = session.sessionID else { return }
        let candidate = unlockPassword
        isUnlocking = true
        unlockUiError = nil
        Task {
            defer { isUnlocking = false }
            switch await tools.submitTerminalUnlock(sessionID: sid, password: candidate) {
            case .success:
                if rememberSystemPassword {
                    TerminalUnlockKeychainStore.savePassword(candidate, for: session.targetDeviceID)
                }
                unlockPassword = ""
                let grid = ToolService.calculateTerminalGrid(viewportSize: viewportSize, fontSize: fontSize)
                tools.terminalConnectOrOpen(sessionID: sid, cols: grid.cols, rows: grid.rows)
            case .failure(let err):
                unlockUiError = err
            }
        }
    }

    private func adjustFontSize(_ delta: Double) {
        fontSize = max(10, min(20, fontSize + delta))
        syncGridSize(viewportSize)
    }

    private func syncGridSize(_ size: CGSize) {
        guard let sid = session.sessionID, size.width > 60, size.height > 60 else { return }
        let grid = ToolService.calculateTerminalGrid(viewportSize: size, fontSize: fontSize)
        tools.terminalResize(sessionID: sid, cols: grid.cols, rows: grid.rows)
    }

    private func reopenActive() {
        guard let sid = session.sessionID else { return }
        sendError = nil
        if tools.termID != nil { tools.terminalClose(sessionID: sid) }
        let grid = ToolService.calculateTerminalGrid(viewportSize: viewportSize, fontSize: fontSize)
        tools.terminalOpen(sessionID: sid, cols: grid.cols, rows: grid.rows)
    }

    private func newTerminal() {
        guard let sid = session.sessionID else { return }
        sendError = nil
        let grid = ToolService.calculateTerminalGrid(viewportSize: viewportSize, fontSize: fontSize)
        tools.terminalOpen(sessionID: sid, cols: grid.cols, rows: grid.rows)
    }

    private func sendInput() {
        guard ready, !input.isEmpty, let sid = session.sessionID else { return }
        if tools.terminalInput(sessionID: sid, text: input + "\n") { sendError = nil; input = "" }
        else { sendError = "发送失败，已保留输入。请检查连接后重试。" }
    }
}
