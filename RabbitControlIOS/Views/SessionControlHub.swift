import SwiftUI

/// 沉浸式会话控制中枢:底部抽屉,分组呈现画质/工具/安全/操作。
/// 只暴露 core 真实支持的能力;未接入的明确标注。
struct SessionControlHub: View {
    var session: SessionService
    var device: Device
    var onExit: () -> Void

    @State private var fpsChoice: Int = PrefsStore.shared.effectiveFps
    @State private var qualityChoice: String = "高清"
    @State private var audioMuted = false
    @State private var showFiles = false
    @State private var showTerminal = false
    @State private var showPortmap = false

    /// 画质档位 → 码率(bps),与设置页一致
    private static let qualityBitrate: [(String, Int)] = [
        ("流畅", 2_000_000), ("高清", 8_000_000), ("超清", 14_000_000), ("原画", 30_000_000),
    ]

    var body: some View {
        NavigationStack {
            List {
                Section("画质") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("帧率").font(.caption).foregroundStyle(.secondary)
                        Picker("帧率", selection: $fpsChoice) {
                            ForEach([24, 30, 60, 144], id: \.self) { f in
                                Text("\(f) 帧").tag(f)
                            }
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: fpsChoice) { _, v in
                            PrefsStore.shared.customFps = v
                            ToastCenter.shared.show("帧率将在下次连接生效")
                        }
                    }
                    .listRowBackground(RCColor.bgCard)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("画质(实时生效)").font(.caption).foregroundStyle(.secondary)
                        Picker("画质", selection: $qualityChoice) {
                            ForEach(Self.qualityBitrate, id: \.0) { q in
                                Text(q.0).tag(q.0)
                            }
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: qualityChoice) { _, v in
                            if let bps = Self.qualityBitrate.first(where: { $0.0 == v })?.1 {
                                session.setBitrate(bps)
                                ToastCenter.shared.show("已调整码率")
                            }
                        }
                    }
                    .listRowBackground(RCColor.bgCard)
                }

                Section("工具") {
                    Button { showFiles = true } label: {
                        Label("文件传输", systemImage: "folder.badge.arrow.up")
                    }
                    Button { showTerminal = true } label: {
                        Label("终端", systemImage: "terminal")
                    }
                    Button { showPortmap = true } label: {
                        Label("端口映射", systemImage: "network")
                    }
                }
                .listRowBackground(RCColor.bgCard)

                Section("安全") {
                    Toggle(isOn: $audioMuted) {
                        Label("远端静音", systemImage: "speaker.slash")
                    }
                    .onChange(of: audioMuted) { _, v in session.setAudioMuted(v) }
                    Button {
                        session.lockRemoteScreen()
                        ToastCenter.shared.show("已发送锁屏")
                    } label: {
                        Label("锁定远端屏幕", systemImage: "lock.display")
                    }
                }
                .listRowBackground(RCColor.bgCard)

                Section {
                    Button(role: .destructive, action: onExit) {
                        Label("退出远控", systemImage: "xmark.rectangle")
                    }
                }
                .listRowBackground(RCColor.bgCard)
            }
            .scrollContentBackground(.hidden)
            .background(RCColor.stageBg)
            .navigationTitle("控制中枢")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showFiles) { FileTransferView(device: device) }
            .sheet(isPresented: $showTerminal) { TerminalView() }
            .sheet(isPresented: $showPortmap) { PortMappingView(device: device) }
        }
    }
}
