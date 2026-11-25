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

struct AssistView: View {
    @Environment(\.dismiss) private var dismiss
    @FocusState private var editing: Bool
    @State private var input = ""
    @State private var password = ""
    @State private var mode: DeviceDetailView.SessionMode = .control
    @State private var target: AssistTarget?
    private var parsed: AssistTarget? { AssistTarget(input) }

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
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("远程协助")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("关闭") { dismiss() }.accessibilityHidden(target != nil).accessibilityIdentifier("assist.close")
            }
        }
        .accessibilityHidden(target != nil)
        .fullScreenCover(item: $target, onDismiss: { password = ""; SessionService.shared.close() }) { target in
            SessionView(device: Device(id: target.id, name: target.id, kind: .mac, online: true,
                                       isLocal: false, wallpaper: .coast), mode: mode, directAddr: target.address,
                        connectionPassword: password)
        }
    }

    private func connect() {
        guard let parsed, problem == nil else { return }
        editing = false
        target = parsed
    }
}
