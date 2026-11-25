import Network
import SwiftUI

/// 手动连接只接受数字 IP:端口或本账号九位设备码。
enum AssistTarget: Identifiable, Equatable {
    case direct(String), account(String)

    init?(_ input: String) {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = text.replacingOccurrences(of: " ", with: "")
        if digits.count == 9, digits.utf8.allSatisfy({ (48...57).contains($0) }) {
            self = .account(digits)
            return
        }
        guard let separator = text.lastIndex(of: ":"),
              let port = UInt16(text[text.index(after: separator)...]), port > 0 else { return nil }
        let host = String(text[..<separator])
        guard IPv4Address(host) != nil || (host.hasPrefix("[") && host.hasSuffix("]") && IPv6Address(String(host.dropFirst().dropLast())) != nil) else { return nil }
        self = .direct(text)
    }

    var id: String {
        switch self { case .direct(let value), .account(let value): value }
    }
    var address: String? { if case .direct(let addr) = self { addr } else { nil } }
}

/// 协助页会话是否正在全屏显示;RootView 据此隐藏悬浮底栏。
@Observable
final class AssistFlow {
    static let shared = AssistFlow()
    var sessionActive = false
}

struct AssistView: View {
    var embeddedInTab = false
    @Environment(\.dismiss) private var dismiss
    @FocusState private var editing: Bool
    @State private var input = ""
    @State private var password = ""
    @State private var mode: DeviceDetailView.SessionMode = .control
    @State private var target: AssistTarget?
    @State private var history = TargetHistory.shared
    @State private var quickTab = 0
    private var parsed: AssistTarget? { AssistTarget(input) }
    private var quickList: [String] { quickTab == 0 ? history.recent : history.favorites }

    private var problem: String? {
        guard !input.isEmpty else { return nil }
        guard let parsed else { return "请输入九位设备 ID，或 IP 地址和端口（1–65535）。" }
        if case .account(let id) = parsed {
            guard AuthService.shared.isLoggedIn else { return "请先登录设备所属账号，或使用直连地址。" }
            guard let device = AuthService.shared.devices.first(where: { $0.deviceID.replacingOccurrences(of: " ", with: "") == id }) else { return "此 ID 不在当前账号的设备列表中。" }
            guard device.online, !device.disabled, device.allowRemoteAssist else { return "设备离线或未允许远程协助。" }
        }
        return nil
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField("设备 ID 或 IP:端口", text: $input)
                        .keyboardType(.numbersAndPunctuation).textInputAutocapitalization(.never)
                        .autocorrectionDisabled().focused($editing).submitLabel(.go)
                        .onSubmit(connect).accessibilityIdentifier("assist.partnerID")
                    if input.isEmpty {
                        PasteButton(payloadType: String.self) { items in
                            if let text = items.first { input = text.trimmingCharacters(in: .whitespacesAndNewlines) }
                        }
                        .labelStyle(.titleOnly).buttonBorderShape(.capsule).controlSize(.small)
                    } else {
                        Button { input = "" } label: { RabbitIcon(.close, size: 14).frame(width: 32, height: 32) }
                            .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("清除连接目标")
                    }
                }
            } header: { Text("连接目标") } footer: {
                Text(problem ?? "输入同一账号下的设备 ID，或对方提供的直连地址，例如 192.168.1.10:9901。")
            }
            Section {
                Picker("模式", selection: $mode) {
                    Text("远程控制").tag(DeviceDetailView.SessionMode.control)
                    Text("仅查看设备").tag(DeviceDetailView.SessionMode.watch)
                }.pickerStyle(.segmented)
                SecureField("远端连接密码（如需）", text: $password)
                    .textContentType(.password)
                    .submitLabel(.go).onSubmit(connect)
            } header: { Text("连接方式") } footer: {
                Text(mode == .watch ? "仅查看不会发送键鼠操作，也不能使用远程工具。" : "需要对方设备允许控制；无需连接密码时留空。")
            }
            Button(action: connect) {
                Label(mode == .watch ? "查看设备屏幕" : "开始远控", rabbitIcon: mode == .watch ? .eye : .cursor)
                    .font(.headline).frame(maxWidth: .infinity, minHeight: 44)
            }
                .buttonStyle(.borderedProminent).listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                .disabled(parsed == nil || problem != nil)
                .accessibilityIdentifier("assist.connect")
            if !history.recent.isEmpty || !history.favorites.isEmpty {
                Section {
                    Picker("快速连接", selection: $quickTab) {
                        Text("最近连接 (\(history.recent.count))").tag(0)
                        Text("我的收藏 (\(history.favorites.count))").tag(1)
                    }.pickerStyle(.segmented).listRowBackground(Color.clear).listRowInsets(EdgeInsets())
                    if quickList.isEmpty {
                        Text(quickTab == 0 ? "暂无最近连接" : "在最近连接中轻点星标即可收藏")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(quickList, id: \.self) { item in
                        HStack {
                            Button {
                                input = item
                                connect()
                            } label: {
                                HStack {
                                    RabbitIcon(item.contains(":") ? .server : .computer, size: 18)
                                        .foregroundStyle(RCColor.accent)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(Self.display(item)).font(.body.monospacedDigit()).foregroundStyle(.primary)
                                        if let when = history.lastConnectedText(item) {
                                            Text(when).font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                }.contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            .accessibilityLabel("连接 \(Self.display(item))")
                            Button { history.toggleFavorite(item) } label: {
                                RabbitIcon(history.isFavorite(item) ? .starFilled : .star, size: 18)
                                    .foregroundStyle(history.isFavorite(item) ? Color.orange : .secondary)
                                    .frame(width: 36, height: 36)
                            }.buttonStyle(.plain)
                            .accessibilityLabel(history.isFavorite(item) ? "取消收藏" : "收藏")
                        }
                        .swipeActions {
                            if quickTab == 0 {
                                Button(role: .destructive) { history.removeRecent(item) } label: { Label("删除", rabbitIcon: .trash) }
                            }
                        }
                    }
                } header: { Text("快速连接") }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("远程协助")
        .toolbar {
            if !embeddedInTab {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }.accessibilityHidden(target != nil).accessibilityIdentifier("assist.close")
                }
            }
        }
        .accessibilityHidden(target != nil)
        .fullScreenCover(item: $target, onDismiss: {
            AssistFlow.shared.sessionActive = false
            password = ""
            SessionService.shared.close()
        }) { target in
            SessionView(device: Device(id: target.id, name: target.id, kind: .mac, online: true,
                                       isLocal: false, wallpaper: .coast), mode: mode, directAddr: target.address,
                        connectionPassword: password)
        }
        .onChange(of: target != nil) {
            AssistFlow.shared.sessionActive = target != nil
        }
    }

    private func connect() {
        guard let parsed, problem == nil else { return }
        editing = false
        target = parsed
    }

    /// 九位码按 3-3-3 分组显示,直连地址原样。
    static func display(_ item: String) -> String {
        guard item.count == 9, item.allSatisfy(\.isNumber) else { return item }
        let chars = Array(item)
        return "\(String(chars[0..<3])) \(String(chars[3..<6])) \(String(chars[6..<9]))"
    }
}
