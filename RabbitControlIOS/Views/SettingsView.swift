import SwiftUI

struct SettingsView: View {
    @State private var prefs = PrefsStore.shared
    @State private var input = InteractionPrefs.shared
    private var proxyStore: ProxyConfigStore { .shared }

    var body: some View {
        Form {
            Section {
                Picker("画质档位", selection: $prefs.qualityPreset) {
                    ForEach(PrefsStore.QualityPreset.allCases) { Text($0.rawValue).tag($0) }
                }.accessibilityIdentifier("settings.qualityPreset")
                if prefs.qualityPreset == .custom {
                    Stepper("码率：\(Double(prefs.customBitrateBps) / 1_000_000, specifier: "%.1f") Mbps",
                            value: $prefs.customBitrateBps, in: 500_000...150_000_000, step: 1_000_000)
                    Stepper("帧率：\(prefs.customFps) fps", value: $prefs.customFps, in: 15...120, step: 15)
                } else {
                    LabeledContent("码率", value: "\(prefs.effectiveBitrateBps / 1_000_000) Mbps")
                    LabeledContent("帧率", value: "\(prefs.effectiveFps) fps")
                }
                Picker("视频编码", selection: $prefs.preferredCodec) {
                    ForEach(VideoCodec.selectablePreferenceCases) { codec in
                        Text(codec.preferenceLabel).tag(codec)
                    }
                }.accessibilityIdentifier("settings.preferredCodec")
                Toggle("静止画面无损文字锐化", isOn: $prefs.stillRefinementEnabled)
                    .accessibilityIdentifier("settings.stillRefinement")
            } header: { Text("默认画质") } footer: {
                Text(
                    VideoCodec.isHardwareAV1DecodeSupported
                        ? "支持 AV1 硬件解码与 H.265 高效编码；被控端不支持所选编码时自动安全降级，分辨率默认跟随被控端。"
                        : "默认优先使用 H.265（更省带宽、画质更清晰，被控端不支持时自动回退 H.264）；分辨率默认跟随被控端，下次连接时生效。"
                )
            }

            Section {
                Picker("默认连接模式", selection: $prefs.connectionMode) {
                    ForEach(ConnectionMode.allCases) { item in
                        Text(item.label).tag(item)
                    }
                }
                .accessibilityIdentifier("settings.connectionMode")

                NavigationLink {
                    ProxySettingsView()
                } label: {
                    LabeledContent("出站网络代理", value: proxyStore.config.summaryText)
                }
                .accessibilityIdentifier("settings.proxy")
            } header: { Text("网络与路由") } footer: {
                Text("「自动路由」按局域网 → P2P 打洞 → mTLS 中继智能连接；启用代理时需使用「自动路由」或「强制 TCP 中继」。")
            }

            Section {
                Toggle("默认显示连接统计", isOn: $prefs.showHUD).accessibilityIdentifier("settings.showHUD")
                Toggle("默认同步远端声音", isOn: $input.audioEnabledDefault)
                Toggle("默认同步剪贴板", isOn: $input.clipboardEnabledDefault)
            } header: { Text("会话默认行为") } footer: { Text("可在会话控制面板中随时切换。") }

            Section {
                Picker("默认交互模式", selection: $input.touchMode) {
                    ForEach(TouchInputMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                if UIDevice.current.userInterfaceIdiom == .pad {
                    LabeledContent("屏幕方向", value: "横屏固定")
                } else {
                    Picker("默认屏幕方向", selection: $input.orientation) {
                        ForEach(SessionOrientation.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Picker("默认竖屏布局", selection: $input.portraitLayout) {
                        ForEach(PortraitLayout.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                }
                HStack {
                    Text("指针灵敏度")
                    Slider(value: $input.pointerSensitivity, in: 0.5...2.5, step: 0.05)
                    Text(String(format: "%.2fx", input.pointerSensitivity))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Toggle("自然滚动方向", isOn: $input.naturalScroll)
            } header: { Text("操控与屏幕") }

            Section {
                Toggle("默认开启加密连接 (mTLS)", isOn: $prefs.encryptConnection)
                    .accessibilityIdentifier("settings.encryptConnection")
                Toggle("远程结束后自动锁定被控端屏幕", isOn: $prefs.lockRemoteOnDisconnect)
                    .accessibilityIdentifier("settings.lockOnDisconnect")
                NavigationLink {
                    AppLockSettingsView()
                } label: {
                    LabeledContent("客户端本地应用锁", value: AppLockStore.shared.isEnabled ? "已启用" : "未启用")
                }
                .accessibilityIdentifier("settings.appLock")
            } header: { Text("安全与隐私") }
        }
        .navigationTitle("远控默认设置")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 出站网络代理配置页（支持直连、系统代理、手动 HTTP CONNECT / SOCKS5 代理）。
struct ProxySettingsView: View {
    var embeddedInSplit = false
    @Environment(\.dismiss) private var dismiss
    @State private var mode: ProxyConfigStore.Mode
    @State private var proxyProtocol: ProxyConfigStore.ProxyProtocol
    @State private var host: String
    @State private var portText: String
    @State private var username: String
    @State private var password: String
    @State private var isSaving = false
    @State private var uiError: RCUiError?

    init(embeddedInSplit: Bool = false) {
        self.embeddedInSplit = embeddedInSplit
        let current = ProxyConfigStore.shared.config
        _mode = State(initialValue: current.mode)
        _proxyProtocol = State(initialValue: current.proxyProtocol)
        _host = State(initialValue: current.host)
        _portText = State(initialValue: String(current.port))
        _username = State(initialValue: current.username)
        _password = State(initialValue: current.password)
    }

    private var manualValidationMessage: String? {
        guard mode == .manual else { return nil }
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedHost.isEmpty {
            return "请输入代理服务器主机名或 IP。"
        }
        if trimmedHost.contains(where: { $0.isWhitespace || "/?#@".contains($0) }) {
            return "代理主机只填域名或 IP，不含协议前缀或路径。"
        }
        guard let port = UInt16(portText), port > 0 else {
            return "代理端口须为 1–65535 的整数。"
        }
        if !password.isEmpty && username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "填写代理密码时需同时提供用户名。"
        }
        return nil
    }

    private var canSave: Bool {
        !isSaving && manualValidationMessage == nil
    }

    var body: some View {
        Form {
            Section {
                Picker("代理模式", selection: $mode) {
                    ForEach(ProxyConfigStore.Mode.allCases) { item in
                        Text(item.label).tag(item)
                    }
                }
                .accessibilityIdentifier("proxy.mode")
            } footer: {
                Text("更改代理后，活跃信令连接会自动重连并切换至新网络路径。")
            }

            if mode == .manual {
                Section("代理服务器") {
                    Picker("代理协议", selection: $proxyProtocol) {
                        ForEach(ProxyConfigStore.ProxyProtocol.allCases) { proto in
                            Text(proto.label).tag(proto)
                        }
                    }
                    .accessibilityIdentifier("proxy.protocol")

                    TextField("服务器主机名或 IP", text: $host)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("proxy.host")

                    LabeledContent("端口") {
                        TextField("7890", text: $portText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .accessibilityIdentifier("proxy.port")
                    }
                }

                Section {
                    TextField("用户名（选填）", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("proxy.username")
                    SecureField("密码（选填）", text: $password)
                        .textContentType(.password)
                        .accessibilityIdentifier("proxy.password")
                } header: {
                    Text("代理认证")
                } footer: {
                    if let manualValidationMessage {
                        Text(manualValidationMessage).foregroundStyle(RCColor.danger)
                    } else {
                        Text("代理密码仅加密保存在本机系统钥匙串中，不会明文落盘。")
                    }
                }
            }

            if let uiError {
                Section {
                    RCInlineErrorView(error: uiError, onDismiss: {
                        self.uiError = nil
                    })
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
            }

            Section {
                Button {
                    save()
                } label: {
                    HStack {
                        Spacer()
                        if isSaving {
                            ProgressView().padding(.trailing, 6)
                        }
                        Text(isSaving ? "正在应用…" : "保存并应用")
                            .fontWeight(.semibold)
                        Spacer()
                    }
                }
                .disabled(!canSave)
                .accessibilityIdentifier("proxy.save")
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("网络代理")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: mode) { uiError = nil }
        .onChange(of: proxyProtocol) { uiError = nil }
        .onChange(of: host) { uiError = nil }
        .onChange(of: portText) { uiError = nil }
    }

    private func save() {
        guard canSave else { return }
        let resolvedPort = UInt16(portText) ?? 7890
        let draft = ProxyConfigStore.Config(
            mode: mode,
            proxyProtocol: proxyProtocol,
            host: host.trimmingCharacters(in: .whitespacesAndNewlines),
            port: resolvedPort,
            username: username.trimmingCharacters(in: .whitespacesAndNewlines),
            password: password
        )
        isSaving = true
        uiError = nil
        Task {
            do {
                try await ProxyConfigStore.shared.apply(draft)
                ToastCenter.shared.show("网络代理设置已生效")
                if !embeddedInSplit { dismiss() }
            } catch {
                uiError = RCUiErrorCodec.fromError(error, fallbackCode: RCErrorCodes.validationInvalidConfig)
            }
            isSaving = false
        }
    }
}
