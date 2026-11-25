import SwiftUI
import UniformTypeIdentifiers

struct FileTransferView: View {
    var device: Device
    @State private var tools = ToolService.shared
    @State private var session = SessionService.shared
    @State private var parents: [String] = []
    @State private var requestedPath: String?
    @State private var showFilePicker = false
    @State private var feedback: String?
    @State private var pendingDownload: ToolService.RemoteFileEntry?
    @State private var preparing = false
    @State private var showNewFolder = false
    @State private var folderName = ""
    @State private var actionError: String?

    var body: some View {
        List {
            Section {
                LabeledContent("设备", value: device.name)
                if !tools.listing && tools.fileError == nil {
                    Label(tools.currentPath, rabbitIcon: .folder).font(.footnote.monospaced()).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
                Button("选择本机文件并上传") { showFilePicker = true }
                    .disabled(tools.listing || tools.fileError != nil || preparing)
                if preparing { ProgressView("正在准备传输…") }
                else if let feedback { Text(feedback).font(.footnote) }
            }
            Section("远端目录") {
                if !parents.isEmpty {
                    Button("上一级") {
                        if let path = parents.popLast() { list(path) }
                    }.disabled(tools.listing)
                }
                if let error = tools.fileError {
                    Text(error).foregroundStyle(.secondary)
                    Button("重试") { list(requestedPath) }
                }
                else if tools.listing { ProgressView("正在读取目录…") }
                else if tools.fileEntries.isEmpty { Text("暂无文件").foregroundStyle(.secondary) }
                ForEach(sortedEntries) { entry in
                    Button {
                        let path = (tools.currentPath as NSString).appendingPathComponent(entry.name)
                        if entry.isDir { parents.append(tools.currentPath); list(path) }
                        else { pendingDownload = entry }
                    } label: {
                        HStack {
                            Label(entry.name, rabbitIcon: entry.isDir ? .folder : .file)
                            Spacer()
                            if !entry.isDir { Text(bytes(entry.size)).font(.caption).foregroundStyle(.secondary) }
                            RabbitIcon(entry.isDir ? .chevronRight : .download, size: 18)
                                .foregroundStyle(.secondary)
                        }
                    }.disabled(!entry.isDir && preparing).accessibilityHint(entry.isDir ? "打开目录" : "查看下载选项")
                }
            }
            Section {
                if tools.transfers.isEmpty { Text("暂无传输任务").foregroundStyle(.secondary) }
                ForEach(tools.transfers) { item in
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading) {
                            Text(item.fileName).lineLimit(1).truncationMode(.middle)
                            if item.status == "active", item.totalBytes > 0 {
                                ProgressView(value: Double(item.doneBytes), total: Double(item.totalBytes))
                                Text("\(bytes(item.doneBytes)) / \(bytes(item.totalBytes))").font(.caption.monospacedDigit())
                            }
                            Text(item.error ?? (["done": "已完成", "cancelled": "已取消", "failed": "失败"][item.status] ?? "传输中")).font(.caption)
                        }
                        Spacer()
                        if item.status == "active" {
                            Button("取消") {
                                guard let sid = session.sessionID else { return }
                                actionError = tools.fileCancel(sessionID: sid, transferID: item.id)
                            }.buttonStyle(.bordered).controlSize(.small)
                        }
                    }
                }
            } header: {
                HStack {
                    Text("本次传输")
                    Spacer()
                    if tools.transfers.contains(where: { $0.status != "active" }) {
                        Button("清除") {
                            guard let sid = session.sessionID else { return }
                            actionError = tools.fileClearFinished(sessionID: sid)
                        }.font(.caption)
                    }
                }
            }
        }
        .navigationTitle("文件传输")
        .confirmationDialog("下载到本机？", isPresented: Binding(get: { pendingDownload != nil }, set: { if !$0 { pendingDownload = nil } }), presenting: pendingDownload) { entry in
            Button("下载文件") { download(entry) }
            Button("取消", role: .cancel) {}
        } message: { entry in
            Text("“\(entry.name)”（\(bytes(entry.size))）将保存到「文件 → 我的 iPhone/iPad → RabbitControl」。")
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { folderName = ""; showNewFolder = true } label: { RabbitIcon(.folderAdd, size: 20) }
                    .disabled(tools.listing || tools.fileError != nil).accessibilityLabel("新建文件夹").accessibilityIdentifier("files.newFolder")
                Button("刷新") { list(requestedPath) }.disabled(tools.listing)
            }
        }
        .alert("新建文件夹", isPresented: $showNewFolder) {
            TextField("文件夹名称", text: $folderName)
            Button("取消", role: .cancel) {}
            Button("创建") { createFolder() }.disabled(!validFolderName)
        }
        .alert("操作未完成", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("好", role: .cancel) {}
        } message: { Text(actionError ?? "") }
        .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.item]) { result in
            guard case let .success(url) = result, let sid = session.sessionID else { return }
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let staging = folder.appendingPathComponent(url.lastPathComponent)
            let remoteDir = tools.currentPath
            preparing = true
            Task {
                defer { preparing = false }
                do {
                    try await Task.detached(priority: .utility) {
                        let accessing = url.startAccessingSecurityScopedResource()
                        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                        try FileManager.default.copyItem(at: url, to: staging)
                    }.value
                    let id = await tools.fileUpload(sessionID: sid, localPath: staging.path, remoteDir: remoteDir)
                    if id == nil { try? FileManager.default.removeItem(at: folder) }
                    if session.sessionID == sid { feedback = id != nil ? "已开始上传" : "上传未开始，请重试" }
                } catch {
                    try? FileManager.default.removeItem(at: folder)
                    feedback = error.localizedDescription
                }
            }
        }
        .onAppear { if let sid = session.sessionID { tools.start(sessionID: sid); list(requestedPath) } }
        .onDisappear { tools.stop() }
    }

    private func list(_ path: String?) {
        requestedPath = path
        if let sid = session.sessionID { tools.fileList(sessionID: sid, path: path) }
    }

    private var sortedEntries: [ToolService.RemoteFileEntry] {
        tools.fileEntries.sorted {
            if $0.isDir != $1.isDir { return $0.isDir }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private func bytes(_ count: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: count), countStyle: .file)
    }

    private var validFolderName: Bool {
        let name = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        return !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\\")
    }

    private func createFolder() {
        guard validFolderName, let sid = session.sessionID else { return }
        let path = tools.currentPath
        actionError = tools.fileMkdir(sessionID: sid, parent: path, name: folderName.trimmingCharacters(in: .whitespacesAndNewlines))
        if actionError == nil {
            feedback = "已创建文件夹"
            list(path)
        }
    }

    private func download(_ entry: ToolService.RemoteFileEntry) {
        guard !preparing, let sid = session.sessionID else { return }
        let path = (tools.currentPath as NSString).appendingPathComponent(entry.name)
        preparing = true
        Task {
            defer { preparing = false }
            let id = await tools.fileDownload(sessionID: sid, remotePath: path)
            if session.sessionID == sid { feedback = id == nil ? "下载未开始，请重试" : "已开始下载，可在本次传输中查看进度。" }
        }
    }
}
