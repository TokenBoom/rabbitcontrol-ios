import SwiftUI
import UIKit

/// 「远程协助」页(P2 移动端适配):远控伙伴设备卡片 + 本设备卡片。
struct AssistView: View {
    @State private var partnerID = ""
    @State private var allowAssist = true
    @State private var codeVisible = true
    @State private var verifyMode = MockData.verifyModes[0]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("开始协助")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(RCColor.textPrimary)
                    .accessibilityAddTraits(.isHeader)

                partnerCard
                localCard
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 110)
        }
        .background(RCColor.bgPage)
        .navigationBarHidden(true)
    }

    // MARK: - 远控伙伴设备

    private var partnerCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("远控伙伴设备")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(RCColor.textPrimary)
            Text("通过其他设备的【设备 ID】及【设备验证码】启动远程控制")
                .font(.system(size: 13))
                .foregroundStyle(RCColor.textSecondary)

            Text("伙伴的设备 ID")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(RCColor.textPrimary)

            TextField("请输入设备 ID", text: $partnerID)
                .keyboardType(.numberPad)
                .font(.system(size: 15))
                .padding(.horizontal, 14)
                .frame(height: 52)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(partnerID.isEmpty ? RCColor.stroke : RCColor.accent, lineWidth: 1)
                }
                .accessibilityIdentifier("assist.partnerID")

            Button {
                ToastCenter.shared.show("功能开发中")
            } label: {
                Text("开始远控")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(
                        partnerID.isEmpty ? RCColor.accent.opacity(0.5) : RCColor.accent,
                        in: RoundedRectangle(cornerRadius: 10)
                    )
            }
            .disabled(partnerID.isEmpty)
            .accessibilityIdentifier("assist.connect")

            HStack(spacing: 16) {
                Spacer()
                Button("最近连接") {
                    ToastCenter.shared.show("暂无历史记录")
                }
                Rectangle()
                    .fill(RCColor.stroke)
                    .frame(width: 1, height: 14)
                Button("收藏设备") {
                    ToastCenter.shared.show("功能开发中")
                }
                Spacer()
            }
            .font(.system(size: 14))
            .foregroundStyle(RCColor.accent)
            .buttonStyle(.plain)
        }
        .padding(20)
        .background(.white, in: RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.04), radius: 3, y: 1)
    }

    // MARK: - 本设备

    private var localCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("本设备")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(RCColor.textPrimary)
                Spacer()
                Text("允许他人远程协助")
                    .font(.system(size: 13))
                    .foregroundStyle(RCColor.textSecondary)
                Toggle("", isOn: $allowAssist)
                    .labelsHidden()
                    .tint(RCColor.accent)
                    .accessibilityIdentifier("assist.allowToggle")
            }

            if allowAssist {
                VStack(alignment: .leading, spacing: 12) {
                    Text("本设备 ID")
                        .font(.system(size: 13))
                        .foregroundStyle(RCColor.textSecondary)
                    Text(MockData.localDeviceID)
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(RCColor.textDisplayNum)
                        .accessibilityIdentifier("assist.localID")

                    HStack(spacing: 12) {
                        Text(codeVisible ? MockData.localVerifyCode : "••••••••")
                            .font(.system(size: 24, weight: .semibold).monospacedDigit())
                            .foregroundStyle(RCColor.textDisplayNum)
                            .accessibilityIdentifier("assist.verifyCode")

                        Button {
                            codeVisible.toggle()
                        } label: {
                            Image(systemName: codeVisible ? "eye" : "eye.slash")
                                .font(.system(size: 16))
                                .foregroundStyle(RCColor.textSecondary)
                                .frame(width: 32, height: 32)
                        }
                        .accessibilityIdentifier("assist.toggleCodeVisibility")

                        Spacer()

                        Button {
                            UIPasteboard.general.string = "\(MockData.localDeviceID) · \(MockData.localVerifyCode)"
                            ToastCenter.shared.show("已复制设备 ID 与验证码")
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "doc.on.doc")
                                Text("复制并分享")
                            }
                            .font(.system(size: 13))
                            .foregroundStyle(RCColor.textPrimary)
                            .padding(.horizontal, 12)
                            .frame(height: 32)
                            .background(.white, in: RoundedRectangle(cornerRadius: 8))
                            .overlay {
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(RCColor.stroke, lineWidth: 1)
                            }
                        }
                        .accessibilityIdentifier("assist.copyShare")
                    }

                    Menu {
                        ForEach(MockData.verifyModes, id: \.self) { mode in
                            Button {
                                verifyMode = mode
                            } label: {
                                if mode == verifyMode {
                                    Label(mode, systemImage: "checkmark")
                                } else {
                                    Text(mode)
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text("验证方式:\(verifyMode)")
                                .font(.system(size: 13))
                                .foregroundStyle(RCColor.textSecondary)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 11))
                                .foregroundStyle(RCColor.textSecondary)
                        }
                    }
                    .accessibilityIdentifier("assist.verifyMode")

                    Text("每次远控结束刷新")
                        .font(.system(size: 12))
                        .foregroundStyle(RCColor.textSecondary)
                }
            }
        }
        .padding(20)
        .background(.white, in: RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.04), radius: 3, y: 1)
    }
}
