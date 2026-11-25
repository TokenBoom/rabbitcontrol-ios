import SwiftUI

struct SettingsView: View {
    @State private var prefs = PrefsStore.shared
    @State private var input = InteractionPrefs.shared

    var body: some View {
        Form {
            Section {
                Picker("画质档位", selection: $prefs.qualityPreset) {
                    ForEach(PrefsStore.QualityPreset.allCases) { Text($0.rawValue).tag($0) }
                }.accessibilityIdentifier("settings.qualityPreset")
                if prefs.qualityPreset == .custom {
                    Stepper("码率：\(Double(prefs.customBitrateBps) / 1_000_000, specifier: "%.1f") Mbps",
                            value: $prefs.customBitrateBps, in: 500_000...50_000_000, step: 500_000)
                    Stepper("帧率：\(prefs.customFps) fps", value: $prefs.customFps, in: 15...120, step: 15)
                } else {
                    LabeledContent("码率", value: "\(prefs.effectiveBitrateBps / 1_000_000) Mbps")
                    LabeledContent("帧率", value: "\(prefs.effectiveFps) fps")
                }
            } header: { Text("默认画质") } footer: { Text("分辨率默认跟随被控端；下次连接时生效。") }

            Section {
                Picker("默认交互模式", selection: $input.touchMode) {
                    ForEach(TouchInputMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Picker("默认屏幕方向", selection: $input.orientation) {
                    ForEach(SessionOrientation.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Picker("默认竖屏布局", selection: $input.portraitLayout) {
                    ForEach(PortraitLayout.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                HStack {
                    Text("指针灵敏度")
                    Slider(value: $input.pointerSensitivity, in: 0.5...2.5, step: 0.05)
                    Text(String(format: "%.2fx", input.pointerSensitivity))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Toggle("直点指尖微偏置", isOn: $input.directTouchOffset)
                Toggle("自然滚动方向", isOn: $input.naturalScroll)
            } header: { Text("操控与屏幕") }

            Section {
                Toggle("默认显示连接统计", isOn: $prefs.showHUD).accessibilityIdentifier("settings.showHUD")
                Toggle("默认同步远端声音", isOn: $input.audioEnabledDefault)
                Toggle("默认同步剪贴板", isOn: $input.clipboardEnabledDefault)
            } header: { Text("会话默认行为") } footer: { Text("可在会话控制面板中随时切换。") }
        }
        .navigationTitle("远控默认设置")
        .navigationBarTitleDisplayMode(.inline)
    }
}
