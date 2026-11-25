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
    private var canConnect: Bool { parsed != nil && problem == nil }

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
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerRow
                targetCard
                modeAndActionCard
                if !history.recent.isEmpty || !history.favorites.isEmpty {
                    quickConnectCard
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, embeddedInTab ? 12 : 8)
            .padding(.bottom, embeddedInTab ? 110 : 32)
        }
        .background(RCColor.bgPage)
        .scrollDismissesKeyboard(.interactively)
        .navigationBarHidden(embeddedInTab)
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

    private var headerRow: some View {
        HStack {
            Text("远程协助").font(.largeTitle.bold())
            Spacer()
            HStack(spacing: 6) {
                Circle()
                    .fill(RuntimeService.shared.signalRunning ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                Text(RuntimeService.shared.signalRunning ? "信令在线" : "未连信令")
                    .font(.caption).foregroundStyle(RCColor.textSecondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(RCColor.bgWindow, in: Capsule())
        }
    }

    private var targetCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("连接目标").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                RabbitIcon(.computer, size: 18).foregroundStyle(RCColor.accent)
                TextField("九位设备 ID 或 IP:端口", text: $input)
                    .keyboardType(.numbersAndPunctuation)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($editing)
                    .submitLabel(.go)
                    .onSubmit(connect)
                    .font(.body.monospacedDigit())
                    .accessibilityIdentifier("assist.partnerID")
                if input.isEmpty {
                    PasteButton(payloadType: String.self) { items in
                        if let text = items.first { input = text.trimmingCharacters(in: .whitespacesAndNewlines) }
                    }
                    .labelStyle(.titleOnly).buttonBorderShape(.capsule).controlSize(.small)
                } else {
                    Button { input = "" } label: {
                        RabbitIcon(.close, size: 14).frame(width: 30, height: 30)
                            .background(Color.secondary.opacity(0.14), in: Circle())
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityLabel("清除连接目标")
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(RCColor.bgPage, in: RoundedRectangle(cornerRadius: 12))

            Text(problem ?? "输入同一账号下的九位设备 ID，或对方提供的局域网地址（如 192.168.1.10:9901）。")
                .font(.caption)
                .foregroundStyle(problem == nil ? RCColor.textSecondary : Color.red)
        }
        .padding(16)
        .background(RCColor.bgWindow, in: RoundedRectangle(cornerRadius: 16))
    }

    private var modeAndActionCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("连接方式").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            Picker("模式", selection: $mode) {
                Text("远程控制").tag(DeviceDetailView.SessionMode.control)
                Text("仅查看设备").tag(DeviceDetailView.SessionMode.watch)
            }
            .pickerStyle(.segmented)

            HStack(spacing: 10) {
                RabbitIcon(.security, size: 17).foregroundStyle(RCColor.textSecondary)
                SecureField("远端连接密码（无密码留空）", text: $password)
                    .textContentType(.password)
                    .submitLabel(.go)
                    .onSubmit(connect)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(RCColor.bgPage, in: RoundedRectangle(cornerRadius: 12))

            Button(action: connect) {
                HStack(spacing: 8) {
                    RabbitIcon(mode == .watch ? .eye : .cursor, size: 18)
                    Text(mode == .watch ? "查看设备屏幕" : "开始远控").font(.headline)
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(canConnect ? RCColor.accent : Color.secondary.opacity(0.35),
                            in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .disabled(!canConnect)
            .accessibilityIdentifier("assist.connect")

            Text(mode == .watch ? "仅查看不会发送键鼠操作，也不能使用远程工具。" : "需要对方设备允许远程协助；无需密码时直接点开始远控。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .background(RCColor.bgWindow, in: RoundedRectangle(cornerRadius: 16))
    }

    private var quickConnectCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("快速连接").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Picker("快速连接", selection: $quickTab) {
                    Text("最近 (\(history.recent.count))").tag(0)
                    Text("收藏 (\(history.favorites.count))").tag(1)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 190)
            }

            if quickList.isEmpty {
                Text(quickTab == 0 ? "暂无最近连接记录" : "在最近连接中轻点星标即可收藏")
                    .font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(quickList.enumerated()), id: \.element) { idx, item in
                        HStack(spacing: 10) {
                            Button {
                                input = item
                                connect()
                            } label: {
                                HStack(spacing: 12) {
                                    RabbitIcon(item.contains(":") ? .server : .computer, size: 18)
                                        .foregroundStyle(RCColor.accent)
                                        .frame(width: 34, height: 34)
                                        .background(RCColor.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
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
                                    .frame(width: 34, height: 34)
                            }.buttonStyle(.plain)
                            .accessibilityLabel(history.isFavorite(item) ? "取消收藏" : "收藏")

                            if quickTab == 0 {
                                Button { history.removeRecent(item) } label: {
                                    RabbitIcon(.trash, size: 16).foregroundStyle(.secondary).frame(width: 32, height: 34)
                                }.buttonStyle(.plain)
                                .accessibilityLabel("删除记录")
                            }
                        }
                        .padding(.vertical, 8)
                        if idx < quickList.count - 1 { Divider() }
                    }
                }
            }
        }
        .padding(16)
        .background(RCColor.bgWindow, in: RoundedRectangle(cornerRadius: 16))
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
