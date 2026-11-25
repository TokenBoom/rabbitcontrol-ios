import SwiftUI

/// 文件传输(W2 移动端适配):本机/远端双栏改为分段切换单栏,底部传输队列。
/// 数据逐字取自设计文档 §6.0,接入真数据前为 mock。
struct FileTransferView: View {
    var device: Device

    @State private var side: Side = .local
    @State private var checkedLocal: Set<String> = []
    @State private var checkedRemote: Set<String> = []
    @State private var queue: [TransferItem] = MockTransfer.queue

    enum Side: String, CaseIterable, Identifiable {
        case local = "本机"
        case remote = "远端"
        var id: String { rawValue }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                pickerCard
                queueCard
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .background(RCColor.bgPage)
        .navigationTitle("文件传输")
    }

    // MARK: - 文件浏览器(单栏分段切换)

    private var pickerCard: some View {
        VStack(spacing: 0) {
            Picker("方向", selection: $side) {
                ForEach(Side.allCases) { s in
                    Text(s == .local ? "本机 · Y的 MacBook Pro" : "远端 · \(device.name)").tag(s)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.top, 16)

            // 路径行
            HStack(spacing: 6) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(RCColor.accent)
                Text(side == .local ? "/Users/yii/Downloads" : "/Users/yii/Documents/mycode/data")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(RCColor.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                HStack(spacing: 4) {
                    toolbarIcon("chevron.left")
                    toolbarIcon("arrow.up")
                    toolbarIcon("arrow.clockwise")
                    toolbarIcon("folder.badge.plus")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            RCColor.divider.frame(height: 1)

            // 表头
            HStack(spacing: 8) {
                Text("名称")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("大小")
                    .frame(width: 70, alignment: .trailing)
            }
            .font(.system(size: 12))
            .foregroundStyle(RCColor.textSecondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)

            RCColor.divider.frame(height: 1)

            let files = side == .local ? MockTransfer.localFiles : MockTransfer.remoteFiles
            let checked = side == .local ? checkedLocal : checkedRemote
            ForEach(Array(files.enumerated()), id: \.element.id) { index, file in
                fileRow(file, checked: checked.contains(file.id), zebra: index % 2 == 1)
            }

            RCColor.divider.frame(height: 1)

            Button {
                let selected = files.filter { checked.contains($0.id) }
                for file in selected {
                    queue.append(TransferItem(
                        id: UUID().uuidString,
                        name: file.name,
                        status: .sent,
                        size: file.size,
                        from: side == .local ? "/Users/yii/Downloads" : "/Users/yii/Documents/mycode/data",
                        to: side == .local ? "\\Users\\yii\\data" : "/Users/yii/Downloads"
                    ))
                }
                if side == .local { checkedLocal = [] } else { checkedRemote = [] }
                ToastCenter.shared.show("已加入传输队列")
            } label: {
                Text(side == .local ? "发送到远端 →" : "← 发送到本机")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 40)
                    .background(
                        checked.isEmpty ? RCColor.stroke : RCColor.accent,
                        in: RoundedRectangle(cornerRadius: 8)
                    )
            }
            .disabled(checked.isEmpty)
            .padding(16)
            .accessibilityIdentifier("transfer.send")
        }
        .background(.white, in: RoundedRectangle(cornerRadius: 12))
    }

    private func toolbarIcon(_ systemImage: String) -> some View {
        Button {
            ToastCenter.shared.show("功能开发中")
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 13))
                .foregroundStyle(RCColor.textSecondary)
                .frame(width: 28, height: 28)
        }
    }

    private func fileRow(_ file: MockFile, checked: Bool, zebra: Bool) -> some View {
        Button {
            if side == .local {
                if checkedLocal.contains(file.id) { checkedLocal.remove(file.id) } else { checkedLocal.insert(file.id) }
            } else {
                if checkedRemote.contains(file.id) { checkedRemote.remove(file.id) } else { checkedRemote.insert(file.id) }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: checked ? "checkmark.square.fill" : "square")
                    .font(.system(size: 15))
                    .foregroundStyle(checked ? RCColor.accent : RCColor.textDisabled)
                Image(systemName: file.isDir ? "folder.fill" : "doc")
                    .font(.system(size: 14))
                    .foregroundStyle(file.isDir ? RCColor.accent : RCColor.textSecondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.name)
                        .font(.system(size: 14))
                        .foregroundStyle(RCColor.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("\(file.modified) · \(file.type)")
                        .font(.system(size: 11))
                        .foregroundStyle(RCColor.textSecondary)
                }
                Spacer()
                Text(file.size)
                    .font(.system(size: 12))
                    .foregroundStyle(RCColor.textSecondary)
                    .frame(width: 70, alignment: .trailing)
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
            .background(zebra ? Color(hex: 0xFAFAFA) : .white)
        }
        .buttonStyle(.plain)
    }

    // MARK: - 传输队列

    private var sentCount: Int { queue.filter { $0.status == .sent }.count }

    private var queueCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("传输列表")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(RCColor.textPrimary)
                Text("已传输 \(sentCount) 个文件")
                    .font(.system(size: 12))
                    .foregroundStyle(RCColor.textSecondary)
                Spacer()
                Button {
                    queue.removeAll { $0.status == .sent || $0.status == .failed }
                } label: {
                    Image(systemName: "eraser")
                        .font(.system(size: 14))
                        .foregroundStyle(RCColor.textSecondary)
                        .frame(width: 32, height: 32)
                }
                .accessibilityIdentifier("transfer.clearFinished")
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 8)

            ForEach(queue) { item in
                VStack(spacing: 0) {
                    RCColor.divider.frame(height: 1)
                    HStack(spacing: 8) {
                        Image(systemName: "doc")
                            .font(.system(size: 14))
                            .foregroundStyle(RCColor.textSecondary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.name)
                                .font(.system(size: 13))
                                .foregroundStyle(RCColor.textPrimary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            HStack(spacing: 6) {
                                statusView(item.status)
                                Text(item.size)
                                    .font(.system(size: 11))
                                    .foregroundStyle(RCColor.textSecondary)
                            }
                            if item.status == .transferring {
                                ProgressView(value: 0.47)
                                    .tint(RCColor.accent)
                                    .frame(height: 6)
                            }
                        }
                        Spacer()
                        Button {
                            queue.removeAll { $0.id == item.id }
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 14))
                                .foregroundStyle(RCColor.textSecondary)
                                .frame(width: 32, height: 32)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
            }
            .padding(.bottom, 8)
        }
        .background(.white, in: RoundedRectangle(cornerRadius: 12))
    }

    private func statusView(_ status: TransferItem.Status) -> some View {
        switch status {
        case .sent:
            Text("✓ 已发送")
                .font(.system(size: 11))
                .foregroundStyle(Color(hex: 0x00B42A))
        case .failed:
            Text("✕ 失败")
                .font(.system(size: 11))
                .foregroundStyle(RCColor.danger)
        case .transferring:
            Text("进行中 47%")
                .font(.system(size: 11))
                .foregroundStyle(RCColor.accent)
        }
    }
}

struct MockFile: Identifiable {
    let id: String
    let name: String
    let modified: String
    let type: String
    let size: String
    let isDir: Bool
}

struct TransferItem: Identifiable {
    enum Status {
        case sent
        case transferring
        case failed
    }

    let id: String
    let name: String
    let status: Status
    let size: String
    let from: String
    let to: String
}

/// §6.0 W2 mock:左栏(本机)8 行 / 右栏(远端)8 行 / 队列 4 条。
enum MockTransfer {
    static let localFiles: [MockFile] = [
        MockFile(id: "l1", name: "openssl-3.5.tar.gz", modified: "2026年11月21日", type: "GZip 归档", size: "9.44 MB", isDir: false),
        MockFile(id: "l2", name: "Antigravity.dmg", modified: "2026年11月21日", type: "磁盘映像", size: "225.02 MB", isDir: false),
        MockFile(id: "l3", name: "GUI-Server.exe", modified: "2026年11月19日", type: "Windows 程序", size: "24.35 MB", isDir: false),
        MockFile(id: "l4", name: "logs", modified: "2026年11月19日", type: "文件夹", size: "--", isDir: true),
        MockFile(id: "l5", name: "logs.zip", modified: "2026年11月19日", type: "Zip 归档", size: "7.44 MB", isDir: false),
        MockFile(id: "l6", name: "expo-report.json", modified: "2026年11月18日", type: "JSON", size: "1.24 KB", isDir: false),
        MockFile(id: "l7", name: "notes.md", modified: "2026年11月18日", type: "Markdown", size: "3.10 KB", isDir: false),
        MockFile(id: "l8", name: "dump-1121.log", modified: "2026年11月17日", type: "日志", size: "56.72 MB", isDir: false),
    ]

    static let remoteFiles: [MockFile] = [
        MockFile(id: "r1", name: "BiliBiliLiveRecorder.7z", modified: "2026年11月07日", type: "7z", size: "10.80 MB", isDir: false),
        MockFile(id: "r2", name: "blivedm-go", modified: "2026年11月05日", type: "文件夹", size: "--", isDir: true),
        MockFile(id: "r3", name: "browserclient", modified: "2026年11月05日", type: "文件夹", size: "--", isDir: true),
        MockFile(id: "r4", name: "danmaku-coder.data", modified: "2026年11月06日", type: "data", size: "21.29 MB", isDir: false),
        MockFile(id: "r5", name: "danmaku-renderer.exe", modified: "2026年11月07日", type: "exe", size: "15.85 MB", isDir: false),
        MockFile(id: "r6", name: "docs", modified: "2026年11月07日", type: "文件夹", size: "--", isDir: true),
        MockFile(id: "r7", name: "README.md", modified: "2026年11月07日", type: "Markdown", size: "2.42 KB", isDir: false),
        MockFile(id: "r8", name: "stream-config.toml", modified: "2026年11月06日", type: "TOML", size: "1.05 KB", isDir: false),
    ]

    static let queue: [TransferItem] = [
        TransferItem(id: "q1", name: "BiliBiliLiveRecorder-gui-master.7z", status: .sent, size: "10.80 MB", from: "/Users/yii/Downloads", to: "\\Users\\yii\\data"),
        TransferItem(id: "q2", name: "Stream-ug.na…22:11:18.har", status: .sent, size: "6.94 KB", from: "/Users/yii/Downloads", to: "\\Users\\yii\\Downloads"),
        TransferItem(id: "q3", name: "danmaku-coder.data", status: .transferring, size: "21.29 MB", from: "/Users/yii/Downloads", to: "\\Users\\yii\\data"),
        TransferItem(id: "q4", name: "GUI-Server.exe", status: .failed, size: "24.35 MB", from: "/Users/yii/Downloads", to: "\\Users\\yii\\data"),
    ]
}
