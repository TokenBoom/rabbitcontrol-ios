import SwiftUI

struct SettingsView: View {
    @State private var prefs = PrefsStore.shared

    var body: some View {
        Form {
            Section {
                Picker("画质档位", selection: $prefs.qualityPreset) {
                    ForEach(PrefsStore.QualityPreset.allCases) { Text($0.rawValue).tag($0) }
                }.accessibilityIdentifier("settings.qualityPreset")
                if prefs.qualityPreset == .custom {
                    Stepper("码率：\(Double(prefs.customBitrateBps) / 1_000_000, specifier: "%.1f") Mbps",
                            value: $prefs.customBitrateBps, in: 500_000...50_000_000, step: 500_000)
                    Stepper("帧率：\(prefs.customFps) fps", value: $prefs.customFps, in: 10...60, step: 5)
                } else {
                    LabeledContent("码率", value: "\(prefs.effectiveBitrateBps / 1_000_000) Mbps")
                    LabeledContent("帧率", value: "\(prefs.effectiveFps) fps")
                }
            } header: { Text("默认画质") } footer: { Text("自动保存，下次连接时生效。网络不稳时可选择流畅。") }
            Section {
                Toggle("显示连接统计", isOn: $prefs.showHUD).accessibilityIdentifier("settings.showHUD")
            } header: { Text("远程桌面") } footer: { Text("在画面上显示帧率、延迟和码率，也可在会话控制中开关。") }
        }.navigationTitle("设置").navigationBarTitleDisplayMode(.inline)
    }
}
