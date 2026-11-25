import SwiftUI

/// 设置页(iOS 主控语义):画质偏好 + 安全偏好,全部真实生效(写入 PrefsStore,
/// 会话打开时采用)。被控向设置(防窥/锁屏/开机自启)不属于移动端,不展示。
struct SettingsView: View {
    @State private var prefs = PrefsStore.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                qualityCard
                securityCard
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .background(RCColor.bgPage)
        .navigationTitle("设置")
        .onAppear { AppChrome.shared.tabBarHidden = true }
        .onDisappear { AppChrome.shared.tabBarHidden = false }
    }

    private var qualityCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("画质")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(RCColor.textPrimary)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

            RCColor.divider.frame(height: 1)

            HStack {
                Text("画质档位")
                    .font(.system(size: 14))
                    .foregroundStyle(RCColor.textPrimary)
                Spacer()
                Picker("画质档位", selection: $prefs.qualityPreset) {
                    ForEach(PrefsStore.QualityPreset.allCases) { p in
                        Text(p.rawValue).tag(p)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("settings.qualityPreset")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            if prefs.qualityPreset == .custom {
                RCColor.divider.frame(height: 1)
                Stepper(value: $prefs.customBitrateBps, in: 500_000...50_000_000, step: 500_000) {
                    HStack {
                        Text("码率")
                            .font(.system(size: 14))
                            .foregroundStyle(RCColor.textPrimary)
                        Spacer()
                        Text("\(prefs.customBitrateBps / 1_000_000) Mbps")
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(RCColor.textSecondary)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                RCColor.divider.frame(height: 1)
                Stepper(value: $prefs.customFps, in: 10...60, step: 5) {
                    HStack {
                        Text("帧率")
                            .font(.system(size: 14))
                            .foregroundStyle(RCColor.textPrimary)
                        Spacer()
                        Text("\(prefs.customFps) fps")
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(RCColor.textSecondary)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }

            RCColor.divider.frame(height: 1)
            HStack {
                Text("显示 HUD")
                    .font(.system(size: 14))
                    .foregroundStyle(RCColor.textPrimary)
                Spacer()
                Toggle("", isOn: $prefs.showHUD)
                    .labelsHidden()
                    .tint(RCColor.accent)
                    .accessibilityIdentifier("settings.showHUD")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(.white, in: RoundedRectangle(cornerRadius: 12))
    }

    private var securityCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("安全")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(RCColor.textPrimary)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

            RCColor.divider.frame(height: 1)

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("默认加密连接")
                        .font(.system(size: 14))
                        .foregroundStyle(RCColor.textPrimary)
                    Text("mTLS 双向证书校验,证书不可用时自动降级")
                        .font(.system(size: 11))
                        .foregroundStyle(RCColor.textSecondary)
                }
                Spacer()
                Toggle("", isOn: $prefs.encryptConnection)
                    .labelsHidden()
                    .tint(RCColor.accent)
                    .accessibilityIdentifier("settings.encryptConnection")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(.white, in: RoundedRectangle(cornerRadius: 12))
    }
}
