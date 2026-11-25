import SwiftUI

/// 端口映射(W4 移动端适配):映射列表 + 添加弹窗(含 §7.1 校验)。
/// 数据逐字取自设计文档 §6.0,接入真数据前为 mock。
struct PortMappingView: View {
    var device: Device

    @State private var mappings: [PortMapping] = MockMappings.items
    @State private var showAdd = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // 标题区:设备名 + 在线点 + 已连接
                HStack(spacing: 8) {
                    Circle()
                        .fill(RCColor.online)
                        .frame(width: 8, height: 8)
                    Text("已连接")
                        .font(.system(size: 13))
                        .foregroundStyle(RCColor.textSecondary)
                    Spacer()
                    Button {
                        showAdd = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "plus.circle")
                            Text("添加")
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
                    .accessibilityIdentifier("portmap.add")
                }

                // 映射列表
                VStack(spacing: 0) {
                    Text("映射列表")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(RCColor.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)

                    ForEach($mappings) { $mapping in
                        RCColor.divider.frame(height: 1)
                        mappingRow($mapping)
                    }
                }
                .background(.white, in: RoundedRectangle(cornerRadius: 12))
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .background(RCColor.bgPage)
        .navigationTitle("端口映射")
        .sheet(isPresented: $showAdd) {
            AddMappingSheet { mapping in
                mappings.append(mapping)
            }
        }
    }

    private func mappingRow(_ mapping: Binding<PortMapping>) -> some View {
        let enabled = mapping.wrappedValue.enabled
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(mapping.wrappedValue.name)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(enabled ? RCColor.textPrimary : RCColor.textDisabled)
                Text(":\(mapping.wrappedValue.localPort) → \(mapping.wrappedValue.targetAddress):\(mapping.wrappedValue.targetPort)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(enabled ? RCColor.textSecondary : RCColor.textDisabled)
                statusView(mapping.wrappedValue.status, enabled: enabled)
            }
            Spacer()
            Toggle("", isOn: mapping.enabled)
                .labelsHidden()
                .tint(RCColor.accent)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func statusView(_ status: PortMapping.Status, enabled: Bool) -> some View {
        let color = enabled ? statusColor(status) : RCColor.textDisabled
        return Text(statusText(status))
            .font(.system(size: 12))
            .foregroundStyle(color)
    }

    private func statusText(_ status: PortMapping.Status) -> String {
        switch status {
        case .success: "✓ 成功"
        case .failed: "✕ 失败"
        case .connecting: "… 连接中"
        }
    }

    private func statusColor(_ status: PortMapping.Status) -> Color {
        switch status {
        case .success: Color(hex: 0x00B42A)
        case .failed: RCColor.danger
        case .connecting: RCColor.textSecondary
        }
    }
}

struct PortMapping: Identifiable {
    enum Status {
        case success
        case failed
        case connecting
    }

    let id: String
    var name: String
    var localPort: String
    var targetAddress: String
    var targetPort: String
    var status: Status
    var enabled: Bool
}

/// §6.0 W4 mock:映射 3 行。
enum MockMappings {
    static let items: [PortMapping] = [
        PortMapping(id: "m1", name: "deepseek harness", localPort: "3080", targetAddress: "127.0.0.1", targetPort: "3080", status: .success, enabled: true),
        PortMapping(id: "m2", name: "ssh-tunnel", localPort: "2222", targetAddress: "10.0.0.8", targetPort: "22", status: .failed, enabled: true),
        PortMapping(id: "m3", name: "jupyter-lab", localPort: "8888", targetAddress: "127.0.0.1", targetPort: "8888", status: .connecting, enabled: true),
    ]
}

/// 添加映射弹窗:四行表单 + §7.1 校验,通过后插入一条「连接中」新行。
struct AddMappingSheet: View {
    var onSave: (PortMapping) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var localPort = ""
    @State private var targetAddress = ""
    @State private var targetPort = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                TextField("名称", text: $name)
                    .accessibilityIdentifier("portmap.field.name")
                TextField("本地端口", text: $localPort)
                    .keyboardType(.numberPad)
                    .accessibilityIdentifier("portmap.field.localPort")
                TextField("目标地址", text: $targetAddress)
                    .keyboardType(.URL)
                    .accessibilityIdentifier("portmap.field.targetAddress")
                TextField("目标端口", text: $targetPort)
                    .keyboardType(.numberPad)
                    .accessibilityIdentifier("portmap.field.targetPort")

                if let error {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundStyle(RCColor.danger)
                }
            }
            .navigationTitle("添加映射")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .accessibilityIdentifier("portmap.save")
                }
            }
        }
        .presentationDetents([.medium])
    }

    /// §7.1 校验:名称非空;端口为 1–65535 数字;目标地址非空。
    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty, trimmedName.count <= 64 else {
            error = "名称需为 1–64 个字符"
            return
        }
        guard validPort(localPort) else {
            error = "端口需为 1–65535 的整数"
            return
        }
        if targetAddress.trimmingCharacters(in: .whitespaces).isEmpty {
            error = "目标地址不能为空"
            return
        }
        guard validPort(targetPort) else {
            error = "端口需为 1–65535 的整数"
            return
        }
        onSave(PortMapping(
            id: UUID().uuidString,
            name: trimmedName,
            localPort: localPort,
            targetAddress: targetAddress,
            targetPort: targetPort,
            status: .connecting,
            enabled: true
        ))
        dismiss()
    }

    private func validPort(_ string: String) -> Bool {
        guard let port = Int(string), (1...65535).contains(port) else { return false }
        return true
    }
}
