import SwiftUI

/// 设置页(W1 移动端适配):顶部 tab(常规/安全/键盘/网络),仅「常规」有内容,其余空态。
struct SettingsView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case general = "常规"
        case security = "安全"
        case keyboard = "键盘"
        case network = "网络"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .general: "gearshape"
            case .security: "lock"
            case .keyboard: "keyboard"
            case .network: "globe"
            }
        }
    }

    @State private var tab: Tab = .general
    @State private var launchAtLogin = true
    @State private var keepAwake = "永不"
    @State private var closeWindow = "隐藏到菜单栏"
    @State private var dragFileFloat = true

    var body: some View {
        VStack(spacing: 0) {
            Picker("设置分组", selection: $tab) {
                ForEach(Tab.allCases) { t in
                    Label(t.rawValue, systemImage: t.icon).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            if tab == .general {
                generalContent
            } else {
                Spacer()
                Text("暂无可配置项")
                    .font(.system(size: 14))
                    .foregroundStyle(RCColor.textSecondary)
                Spacer()
            }
        }
        .background(RCColor.bgPage)
        .navigationTitle("设置")
        .onAppear { AppChrome.shared.tabBarHidden = true }
        .onDisappear { AppChrome.shared.tabBarHidden = false }

        .navigationBarTitleDisplayMode(.inline)
    }

    private var generalContent: some View {
        ScrollView {
            VStack(spacing: 16) {
                // G1
                settingsCard {
                    ToggleRow(title: "开机自启动", isOn: $launchAtLogin)
                    divider
                    selectRow(
                        title: "让这台 Mac 保持唤醒状态",
                        note: "防止电脑进入睡眠状态,导致无法远程访问(合盖状态下建议连接电源适配器)。",
                        selection: $keepAwake,
                        options: ["永不", "10 分钟", "30 分钟", "1 小时"]
                    )
                    divider
                    selectRow(
                        title: "关闭窗口时",
                        note: nil,
                        selection: $closeWindow,
                        options: ["隐藏到菜单栏", "退出程序"]
                    )
                }

                // G2
                settingsCard {
                    ToggleRow(
                        title: "被控时拖拽文件显示发送浮窗",
                        note: "开启后,可在被控时向主控端发送文件。",
                        isOn: $dragFileFloat
                    )
                }

                // G3
                settingsCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("移动设备传输文件存储路径")
                            .font(.system(size: 14))
                            .foregroundStyle(RCColor.textPrimary)
                        Text("/Users/yii/Library/Application Support/RabbitControl/Download")
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(RCColor.textSecondary)
                            .lineLimit(2)
                        HStack(spacing: 12) {
                            secondaryButton("修改路径")
                            secondaryButton("打开文件夹")
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                // G4
                settingsCard {
                    HStack {
                        Text("实名认证")
                            .font(.system(size: 14))
                            .foregroundStyle(RCColor.textPrimary)
                        Spacer()
                        Text("已通过账号实名认证")
                            .font(.system(size: 13))
                            .foregroundStyle(RCColor.textDisabled)
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 48)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private var divider: some View {
        RCColor.divider.frame(height: 1).padding(.leading, 16)
    }

    private func settingsCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            content()
        }
        .background(.white, in: RoundedRectangle(cornerRadius: 12))
    }

    private func secondaryButton(_ title: String) -> some View {
        Button(title) {
            ToastCenter.shared.show("功能开发中")
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

    private func selectRow(title: String, note: String?, selection: Binding<String>, options: [String]) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 14))
                    .foregroundStyle(RCColor.textPrimary)
                if let note {
                    Text(note)
                        .font(.system(size: 12))
                        .foregroundStyle(RCColor.textSecondary)
                }
            }
            Spacer()
            Menu {
                ForEach(options, id: \.self) { option in
                    Button {
                        selection.wrappedValue = option
                    } label: {
                        if option == selection.wrappedValue {
                            Label(option, systemImage: "checkmark")
                        } else {
                            Text(option)
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(selection.wrappedValue)
                        .font(.system(size: 13))
                        .foregroundStyle(RCColor.textPrimary)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11))
                        .foregroundStyle(RCColor.textSecondary)
                }
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(.white, in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(RCColor.stroke, lineWidth: 1)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

/// 设置行:左标题(+可选灰说明)、右 Switch(§4 ToggleRow)。
struct ToggleRow: View {
    var title: String
    var note: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 14))
                    .foregroundStyle(RCColor.textPrimary)
                if let note {
                    Text(note)
                        .font(.system(size: 12))
                        .foregroundStyle(RCColor.textSecondary)
                }
            }
            Spacer()
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .tint(RCColor.accent)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
