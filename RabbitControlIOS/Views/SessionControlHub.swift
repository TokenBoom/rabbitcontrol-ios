import SwiftUI

struct SessionControlHub: View {
    var session: SessionService
    var device: Device
    var watchOnly: Bool
    @Binding var showMouseTools: Bool
    var initialTool: DeviceDetailView.QuickTool? = nil
    var onExit: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var prefs = PrefsStore.shared
    @State private var input = InteractionPrefs.shared
    @State private var confirmExit = false
    @State private var confirmLock = false
    @State private var clipboardMessage: String?
    private var canControl: Bool { session.isConnected && !watchOnly }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("设备", value: device.name)
                    LabeledContent("状态", value: session.state.displayText)
                    if let authenticated = session.mutuallyAuthenticated {
                        LabeledContent("双向证书认证", value: authenticated ? "已启用" : "未启用")
                    }
                } header: { Text(watchOnly ? "仅查看设备" : "远程控制") }
                if !watchOnly {
                    Section {
                        Picker(selection: $input.touchMode) {
                            ForEach(TouchInputMode.allCases, id: \.self) { Text($0.label).tag($0) }
                        } label: { Label("触控模式", rabbitIcon: .cursor) }
                        if input.touchMode == .trackpad {
                            HStack {
                                Label("指针灵敏度", rabbitIcon: .mouse)
                                Slider(value: $input.pointerSensitivity, in: 0.5...2.5, step: 0.05)
                                Text(String(format: "%.2fx", input.pointerSensitivity)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                        Toggle(isOn: $input.naturalScroll) { Label("自然滚动方向", rabbitIcon: .arrowDown) }
                        Toggle(isOn: $showMouseTools) { Label("在桌面上显示鼠标工具", rabbitIcon: .mouse) }
                        NavigationLink { RemoteKeyboard(session: session).modifier(ConnectedTool(session: session)) } label: { Label("远程键盘", rabbitIcon: .keyboard) }
                    } header: { Text("操控") } footer: {
                        Text(canControl ? "轻点左键，长按或双指轻点右键，双指滚动，捏合缩放；触控板模式下轻点后再次触按拖动。" : "连接成功后可使用工具。")
                    }.disabled(!canControl)
                }
                Section {
                    Picker(selection: $input.orientation) {
                        ForEach(SessionOrientation.allCases, id: \.self) { Text($0.label).tag($0) }
                    } label: { Label("屏幕方向", rabbitIcon: .display) }
                    Picker(selection: $input.portraitLayout) {
                        ForEach(PortraitLayout.allCases, id: \.self) { Text($0.label).tag($0) }
                    } label: { Label("竖屏布局", rabbitIcon: .display) }
                    Toggle("控制栏放在左侧", isOn: $input.controlsLeading)
                    VStack(alignment: .leading) {
                        Text("控制栏不透明度 \(Int(input.hudAlpha * 100))%")
                        Slider(value: $input.hudAlpha, in: 0.35...1)
                            .accessibilityLabel("控制栏不透明度")
                    }
                    Toggle("显示连接统计", isOn: $prefs.showHUD)
                    if !watchOnly {
                        Picker("画质档位", selection: $prefs.qualityPreset) {
                            ForEach(PrefsStore.QualityPreset.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .onChange(of: prefs.qualityPreset) {
                            if canControl { session.setBitrate(prefs.effectiveBitrateBps) }
                        }
                        .disabled(!canControl)
                    }
                    Button {
                        session.requestIDR()
                    } label: { Label("刷新画面关键帧", rabbitIcon: .arrowRight) }
                        .disabled(!session.isConnected)
                } header: { Text("显示") } footer: {
                    Text(watchOnly ? "观看模式不会发送输入或打开远程工具。" : "切换档位会调整本次码率；档位中的帧率在下次连接时生效。")
                }
                if !watchOnly, let display = session.display {
                    Section("主显示器视频流") {
                        resolutionMenu(display: display)
                        fpsMenu(display: display)
                    }.disabled(!canControl)
                }
                if !watchOnly {
                Section {
                    Toggle(isOn: Binding(get: { session.clipboardEnabled }, set: {
                        session.setClipboardEnabled($0)
                        clipboardMessage = nil
                    })) { Label("本次会话交换文本", rabbitIcon: .clipboard) }
                    if session.clipboardEnabled {
                        PasteButton(payloadType: String.self) { items in
                            guard let text = items.first else { return }
                            clipboardMessage = session.sendClipboard(text) ? "文本已交给会话发送。" : "未发送：请稍后重试，文本不能超过 65535 字节。"
                        }.accessibilityLabel("粘贴并发送到 Mac")
                        Button("复制 Mac 最近共享的文本") {
                            if let text = session.receivedText {
                                UIPasteboard.general.setItems([["public.utf8-plain-text": text]], options: [.localOnly: true])
                                clipboardMessage = "已复制到本机。"
                            }
                        }.disabled(session.receivedText == nil)
                        if let clipboardMessage { Text(clipboardMessage).font(.footnote) }
                    }
                } header: { Text("文本剪贴板") } footer: {
                    Text("手机仅在你点粘贴时发送文本；Mac 须开启剪贴板共享。收到的文本不会自动覆盖本机剪贴板。")
                }.disabled(!canControl)
                }
                Section {
                    Toggle(isOn: Binding(get: { session.audioMuted }, set: { session.setAudioMuted($0) })) { Label("静音远端声音", rabbitIcon: .speaker) }
                        .disabled(!session.isConnected)
                    if !watchOnly {
                        Button(role: .destructive) { confirmLock = true } label: { Label("锁定远端屏幕", rabbitIcon: .security) }.disabled(!canControl)
                    }
                }
            }
            .navigationTitle(watchOnly ? "观看设置" : "会话控制").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("结束", role: .destructive) { confirmExit = true }
                        .accessibilityLabel("结束远程协助")
                }
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
            .confirmationDialog("结束本次远程协助？", isPresented: $confirmExit, titleVisibility: .visible) {
                Button("结束会话", role: .destructive, action: onExit)
            }
            .confirmationDialog("锁定远端屏幕？", isPresented: $confirmLock, titleVisibility: .visible) {
                Button("锁屏", role: .destructive) { session.lockRemoteScreen() }
            }
        }
    }
    @ViewBuilder
    private func resolutionMenu(display: SessionService.DisplayConfig) -> some View {
        let presets: [SessionService.DisplayConfig.Preset] = {
            if display.width > 0, display.height > 0,
               !display.presets.contains(where: { $0.width == display.width && $0.height == display.height }) {
                let current = SessionService.DisplayConfig.Preset(
                    width: display.width, height: display.height,
                    label: "\(display.width) × \(display.height)（当前）"
                )
                return [current] + display.presets
            }
            return display.presets
        }()
        Menu {
            ForEach(presets, id: \.self) { preset in
                Button {
                    session.setStream(width: preset.width, height: preset.height)
                } label: {
                    if preset.width == display.width && preset.height == display.height {
                        Label(preset.label, rabbitIcon: .checkmark)
                    } else {
                        Text(preset.label)
                    }
                }
            }
        } label: {
            Label("分辨率：\(display.width) × \(display.height)", rabbitIcon: .display)
        }
    }

    @ViewBuilder
    private func fpsMenu(display: SessionService.DisplayConfig) -> some View {
        Menu {
            ForEach(Self.fpsOptions(display: display), id: \.self) { fps in
                Button {
                    session.setStream(fps: fps)
                } label: {
                    if fps == display.fps {
                        Label("\(fps) fps", rabbitIcon: .checkmark)
                    } else {
                        Text("\(fps) fps")
                    }
                }
            }
        } label: {
            Label("帧率：\(display.fps) fps", rabbitIcon: .display)
        }
    }

    /// 帧率选项:30/60/90/120,封顶 120 与主机实际上限,始终包含当前值。
    static func fpsOptions(display: SessionService.DisplayConfig) -> [Int] {
        let cap = min(max(display.maxFps, display.fps), 120)
        var list = [30, 60, 90, 120].filter { $0 <= cap }
        if display.fps > 0, !list.contains(display.fps) { list.append(display.fps) }
        return list.sorted()
    }
}

struct ConnectedTool: ViewModifier {
    var session: SessionService
    func body(content: Content) -> some View {
        if session.isConnected && !session.peerWatchOnly { content }
        else {
            ContentUnavailableView {
                Label("连接已结束", rabbitIcon: .disconnected)
            } description: {
                Text("请返回会话页重新连接。")
            }
        }
    }


}
