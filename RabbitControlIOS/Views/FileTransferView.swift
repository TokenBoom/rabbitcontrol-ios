import SwiftUI
import UniformTypeIdentifiers

/// W2 文件传输（对齐 macOS 基线 §7.1 双栏浏览 + 多选批量互传 + 传输队列控制 + #6 权限门控）。
struct FileTransferView: View {
    enum Pane: String, CaseIterable, Identifiable {
        case remote = "远端文件"
        case local = "本机接收库"
        case queue = "传输列表"
        var id: String { rawValue }
    }

    struct LocalFileItem: Identifiable, Hashable {
        let url: URL
        let name: String
        let isDir: Bool
        let size: UInt64
        let modifiedAt: Date?
        var id: String { url.path }
    }

    var device: Device
    @State private var activePane: Pane = .remote
    @State private var tools = ToolService.shared
    @State private var session = SessionService.shared

    // 远端状态与多选
    @State private var parents: [String] = []
    @State private var requestedPath: String?
    @State private var isSelectingRemote = false
    @State private var selectedRemoteNames = Set<String>()
    @State private var renamingRemoteEntry: ToolService.RemoteFileEntry?
    @State private var remoteRenameText = ""
    @State private var deletingRemoteEntry: ToolService.RemoteFileEntry?

    // 本机接收库（Documents）状态
    @State private var localCurrentURL: URL = URL.documentsDirectory
    @State private var localParents: [URL] = []
    @State private var localEntries: [LocalFileItem] = []
    @State private var showLocalNewFolder = false
    @State private var localFolderName = ""
    @State private var renamingLocalItem: LocalFileItem?
    @State private var localRenameText = ""

    // 上传/下载交互
    @State private var showFilePicker = false
    @State private var feedback: String?
    @State private var pendingDownload: ToolService.RemoteFileEntry?
    @State private var preparing = false
    @State private var showNewFolder = false
    @State private var folderName = ""
    @State private var actionError: String?

    private static let modifiedFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    private var fileAllowed: Bool {
        session.toolPermissions.allowFileTransfer
    }

    private var activeTransferCount: Int {
        tools.transfers.filter { $0.status == "active" }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("文件视图", selection: $activePane) {
                Text("远端目录").tag(Pane.remote)
                Text("本机文件").tag(Pane.local)
                Text(activeTransferCount > 0 ? "传输 (\(activeTransferCount))" : "传输 (\(tools.transfers.count))").tag(Pane.queue)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(RCColor.bgPage)

            List {
                switch activePane {
                case .remote:
                    remoteHeaderSection
                    remoteDirectorySection
                case .local:
                    localHeaderSection
                    localDirectorySection
                case .queue:
                    transferQueueSection
                }
            }
        }
        .navigationTitle("文件传输")
        .confirmationDialog(
            "下载到本机？",
            isPresented: Binding(get: { pendingDownload != nil }, set: { if !$0 { pendingDownload = nil } }),
            presenting: pendingDownload
        ) { entry in
            Button("下载文件") { download(entry) }
            Button("取消", role: .cancel) {}
        } message: { entry in
            Text("“\(entry.name)”（\(bytes(entry.size))）将保存到「本机文件（我的 iPhone/iPad → RabbitControl）」。")
        }
        .confirmationDialog(
            "删除远端项目？",
            isPresented: Binding(get: { deletingRemoteEntry != nil }, set: { if !$0 { deletingRemoteEntry = nil } }),
            presenting: deletingRemoteEntry
        ) { entry in
            Button("删除“\(entry.name)”", role: .destructive) { deleteRemote(entry) }
            Button("取消", role: .cancel) {}
        } message: { entry in
            Text("将从远端目录永久删除“\(entry.name)”。")
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if activePane == .remote {
                    if fileAllowed && !sortedRemoteFilesOnly.isEmpty {
                        Button(isSelectingRemote ? "完成" : "多选") {
                            isSelectingRemote.toggle()
                            if !isSelectingRemote { selectedRemoteNames.removeAll() }
                        }
                    }
                    Button { folderName = ""; showNewFolder = true } label: { RabbitIcon(.folderAdd, size: 20) }
                        .disabled(!fileAllowed || tools.listing || tools.fileError != nil)
                        .accessibilityLabel("新建文件夹")
                        .accessibilityIdentifier("files.newFolder")
                    Button("刷新") { list(requestedPath) }
                        .disabled(!fileAllowed || tools.listing)
                } else if activePane == .local {
                    Button { localFolderName = ""; showLocalNewFolder = true } label: { RabbitIcon(.folderAdd, size: 20) }
                        .accessibilityLabel("新建本机文件夹")
                    Button("刷新") { reloadLocalDirectory() }
                }
            }
        }
        .alert("新建远端文件夹", isPresented: $showNewFolder) {
            TextField("文件夹名称", text: $folderName)
            Button("取消", role: .cancel) {}
            Button("创建") { createFolder() }.disabled(!isValidName(folderName))
        }
        .alert("重命名远端项目", isPresented: Binding(get: { renamingRemoteEntry != nil }, set: { if !$0 { renamingRemoteEntry = nil } })) {
            TextField("新名称", text: $remoteRenameText)
            Button("取消", role: .cancel) { renamingRemoteEntry = nil }
            Button("保存") {
                if let entry = renamingRemoteEntry { renameRemote(entry, to: remoteRenameText) }
                renamingRemoteEntry = nil
            }.disabled(!isValidName(remoteRenameText))
        }
        .alert("新建本机文件夹", isPresented: $showLocalNewFolder) {
            TextField("文件夹名称", text: $localFolderName)
            Button("取消", role: .cancel) {}
            Button("创建") { createLocalFolder() }.disabled(!isValidName(localFolderName))
        }
        .alert("重命名本机项目", isPresented: Binding(get: { renamingLocalItem != nil }, set: { if !$0 { renamingLocalItem = nil } })) {
            TextField("新名称", text: $localRenameText)
            Button("取消", role: .cancel) { renamingLocalItem = nil }
            Button("保存") {
                if let item = renamingLocalItem { renameLocalItem(item, to: localRenameText) }
                renamingLocalItem = nil
            }.disabled(!isValidName(localRenameText))
        }
        .alert("操作未完成", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("好", role: .cancel) {}
        } message: { Text(actionError ?? "") }
        .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard case let .success(urls) = result, !urls.isEmpty, let sid = session.sessionID else { return }
            uploadPickedSecurityScopedURLs(urls, sessionID: sid, remoteDir: tools.currentPath)
        }
        .onAppear {
            reloadLocalDirectory()
            if let sid = session.sessionID {
                tools.start(sessionID: sid)
                list(requestedPath)
            }
        }
        .onChange(of: tools.transfers) {
            if activePane == .local {
                reloadLocalDirectory()
            }
        }
    }

    // MARK: - 远端分栏

    private var remoteHeaderSection: some View {
        Section {
            LabeledContent("设备", value: device.name)
            if fileAllowed && !tools.listing && tools.fileError == nil {
                Label(tools.currentPath, rabbitIcon: .folder)
                    .font(.footnote.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            if fileAllowed {
                Button("选择本机文件并批量上传") { showFilePicker = true }
                    .disabled(tools.listing || tools.fileError != nil || preparing)
            }
            if isSelectingRemote {
                HStack {
                    Button(selectedRemoteNames.count == sortedRemoteFilesOnly.count ? "取消全选" : "全选文件") {
                        if selectedRemoteNames.count == sortedRemoteFilesOnly.count {
                            selectedRemoteNames.removeAll()
                        } else {
                            selectedRemoteNames = Set(sortedRemoteFilesOnly.map(\.name))
                        }
                    }
                    Spacer()
                    Button("批量下载 (\(selectedRemoteNames.count))") {
                        downloadSelectedRemoteFiles()
                    }
                    .fontWeight(.semibold)
                    .disabled(selectedRemoteNames.isEmpty || preparing)
                }
            }
            if preparing { ProgressView("正在准备传输…") }
            else if let feedback { Text(feedback).font(.footnote).foregroundStyle(.secondary) }
        }
    }

    private var remoteDirectorySection: some View {
        Section("远端目录") {
            if !fileAllowed {
                RCInlineErrorView(
                    error: tools.fileUiError ?? CoreClient.resolveUiError(code: RCErrorCodes.toolForbidden)
                )
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            } else {
                if !parents.isEmpty {
                    Button("上一级") {
                        if let path = parents.popLast() { list(path) }
                    }.disabled(tools.listing)
                }
                if let uiErr = tools.fileUiError {
                    RCInlineErrorView(
                        error: uiErr,
                        actionLabelOverride: "重试",
                        onAction: { _ in list(requestedPath) }
                    )
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                } else if let error = tools.fileError {
                    Text(error).foregroundStyle(.secondary)
                    Button("重试") { list(requestedPath) }
                } else if tools.listing {
                    ProgressView("正在读取目录…")
                } else if tools.fileEntries.isEmpty {
                    Text("暂无文件").foregroundStyle(.secondary)
                }
                ForEach(sortedEntries) { entry in
                    remoteEntryRow(entry)
                }
            }
        }
    }

    private func remoteEntryRow(_ entry: ToolService.RemoteFileEntry) -> some View {
        let isSelected = selectedRemoteNames.contains(entry.name)
        return Button {
            if isSelectingRemote {
                guard !entry.isDir else { return }
                if isSelected { selectedRemoteNames.remove(entry.name) }
                else { selectedRemoteNames.insert(entry.name) }
            } else {
                let path = (tools.currentPath as NSString).appendingPathComponent(entry.name)
                if entry.isDir {
                    parents.append(tools.currentPath)
                    list(path)
                } else {
                    pendingDownload = entry
                }
            }
        } label: {
            HStack(spacing: 10) {
                if isSelectingRemote && !entry.isDir {
                    RabbitIcon(isSelected ? .checkmark : .file, size: 17)
                        .foregroundStyle(isSelected ? RCColor.accent : RCColor.textDisabled)
                } else {
                    RabbitIcon(entry.isDir ? .folder : .file, size: 18)
                        .foregroundStyle(entry.isDir ? RCColor.accent : RCColor.textSecondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                        .foregroundStyle(RCColor.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let meta = entrySubtitle(entry) {
                        Text(meta)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if !isSelectingRemote {
                    RabbitIcon(entry.isDir ? .chevronRight : .download, size: 18)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .disabled(!entry.isDir && preparing)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                deletingRemoteEntry = entry
            } label: {
                Label("删除", rabbitIcon: .trash)
            }
            Button {
                remoteRenameText = entry.name
                renamingRemoteEntry = entry
            } label: {
                Label("重命名", rabbitIcon: .pencil)
            }
            .tint(RCColor.accent)
        }
    }

    // MARK: - 本机文件分栏（对称浏览 / 分享 / 上传至远端）

    private var localHeaderSection: some View {
        Section {
            Label(localRelativePathText, rabbitIcon: .folder)
                .font(.footnote.monospaced())
                .lineLimit(1)
            Text("从远端下载的文件保存在此处；向左滑动或点击右侧菜单可一键上传至远端当前目录、分享、重命名或删除。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var localDirectorySection: some View {
        Section("本机文件库") {
            if !localParents.isEmpty {
                Button("返回上一级") {
                    if let prev = localParents.popLast() {
                        localCurrentURL = prev
                        reloadLocalDirectory()
                    }
                }
            }
            if localEntries.isEmpty {
                Text("本机接收目录暂无文件").foregroundStyle(.secondary)
            }
            ForEach(localEntries) { item in
                HStack(spacing: 10) {
                    Button {
                        if item.isDir {
                            localParents.append(localCurrentURL)
                            localCurrentURL = item.url
                            reloadLocalDirectory()
                        } else if fileAllowed {
                            uploadLocalItemToRemote(item)
                        }
                    } label: {
                        HStack(spacing: 10) {
                            RabbitIcon(item.isDir ? .folder : .file, size: 18)
                                .foregroundStyle(item.isDir ? RCColor.accent : RCColor.textSecondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name)
                                    .foregroundStyle(RCColor.textPrimary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text(localSubtitle(item))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Menu {
                        if !item.isDir && fileAllowed {
                            Button {
                                uploadLocalItemToRemote(item)
                            } label: {
                                Label("上传到远端当前目录", rabbitIcon: .arrowUp)
                            }
                        }
                        ShareLink(item: item.url) {
                            Label("分享 / 导出", systemImage: "square.and.arrow.up")
                        }
                        Button {
                            localRenameText = item.name
                            renamingLocalItem = item
                        } label: {
                            Label("重命名", rabbitIcon: .pencil)
                        }
                        Button(role: .destructive) {
                            deleteLocalItem(item)
                        } label: {
                            Label("删除", rabbitIcon: .trash)
                        }
                    } label: {
                        RabbitIcon(.ellipsis, size: 18)
                            .foregroundStyle(.secondary)
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.plain)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        deleteLocalItem(item)
                    } label: {
                        Label("删除", rabbitIcon: .trash)
                    }
                    if !item.isDir && fileAllowed {
                        Button {
                            uploadLocalItemToRemote(item)
                        } label: {
                            Label("上传", rabbitIcon: .arrowUp)
                        }
                        .tint(RCColor.accent)
                    }
                }
            }
        }
    }

    // MARK: - 传输队列分栏

    private var transferQueueSection: some View {
        Section {
            if tools.transfers.isEmpty {
                Text("暂无传输任务").foregroundStyle(.secondary)
            }
            ForEach(tools.transfers) { item in
                HStack(alignment: .center, spacing: 12) {
                    RabbitIcon(item.isUpload ? .arrowUp : .arrowDown, size: 16)
                        .foregroundStyle(item.isUpload ? RCColor.accent : RCColor.online)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(item.fileName)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(item.isUpload ? "上传" : "下载")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.secondary.opacity(0.12), in: Capsule())
                        }
                        if item.status == "active", item.totalBytes > 0 {
                            ProgressView(value: Double(item.doneBytes), total: Double(item.totalBytes))
                            Text("\(bytes(item.doneBytes)) / \(bytes(item.totalBytes))")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Text(item.error ?? (["done": "已完成", "cancelled": "已取消", "failed": "失败"][item.status] ?? "传输中"))
                            .font(.caption)
                            .foregroundStyle(item.error != nil || item.status == "failed" ? RCColor.danger : .secondary)
                    }
                    Spacer()
                    if item.status == "active" {
                        Button("取消") {
                            guard let sid = session.sessionID else { return }
                            actionError = tools.fileCancel(sessionID: sid, transferID: item.id)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    } else {
                        Button {
                            guard let sid = session.sessionID else { return }
                            tools.fileRemoveTransfer(sessionID: sid, transferID: item.id)
                        } label: {
                            RabbitIcon(.close, size: 13)
                                .foregroundStyle(.secondary)
                                .frame(width: 28, height: 28)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("移除记录 \(item.fileName)")
                    }
                }
            }
        } header: {
            HStack {
                Text("本次传输")
                Spacer()
                if tools.transfers.contains(where: { $0.status != "active" }) {
                    Button("清除已完成") {
                        guard let sid = session.sessionID else { return }
                        actionError = tools.fileClearFinished(sessionID: sid)
                    }.font(.caption)
                }
            }
        }
    }

    // MARK: - 辅助动作

    private var localRelativePathText: String {
        let base = URL.documentsDirectory.standardizedFileURL.path
        let cur = localCurrentURL.standardizedFileURL.path
        if cur == base { return "RabbitControl（本机文稿）" }
        let suffix = cur.replacingOccurrences(of: base, with: "")
        return "RabbitControl\(suffix)"
    }

    private func reloadLocalDirectory() {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: localCurrentURL,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            localEntries = []
            return
        }
        let items: [LocalFileItem] = urls.compactMap { url in
            let vals = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
            return LocalFileItem(
                url: url,
                name: url.lastPathComponent,
                isDir: vals?.isDirectory ?? false,
                size: UInt64(max(0, vals?.fileSize ?? 0)),
                modifiedAt: vals?.contentModificationDate
            )
        }
        localEntries = items.sorted {
            if $0.isDir != $1.isDir { return $0.isDir }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private func localSubtitle(_ item: LocalFileItem) -> String {
        let dateStr = item.modifiedAt.map { Self.modifiedFormatter.string(from: $0) }
        if item.isDir { return dateStr ?? "文件夹" }
        let sz = bytes(item.size)
        return dateStr.map { "\(sz) · \($0)" } ?? sz
    }

    private func createLocalFolder() {
        let trimmed = localFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidName(trimmed) else { return }
        let target = localCurrentURL.appendingPathComponent(trimmed, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            reloadLocalDirectory()
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func renameLocalItem(_ item: LocalFileItem, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidName(trimmed) else { return }
        let dest = item.url.deletingLastPathComponent().appendingPathComponent(trimmed)
        do {
            try FileManager.default.moveItem(at: item.url, to: dest)
            reloadLocalDirectory()
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func deleteLocalItem(_ item: LocalFileItem) {
        do {
            try FileManager.default.removeItem(at: item.url)
            reloadLocalDirectory()
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func uploadLocalItemToRemote(_ item: LocalFileItem) {
        guard !item.isDir, let sid = session.sessionID else { return }
        let remoteDir = tools.currentPath
        Task {
            let id = await tools.fileUpload(sessionID: sid, localPath: item.url.path, remoteDir: remoteDir)
            if id != nil {
                ToastCenter.shared.show("已开始上传「\(item.name)」至远端 \(remoteDir)")
                activePane = .queue
            }
        }
    }

    private func uploadPickedSecurityScopedURLs(_ urls: [URL], sessionID: UInt64, remoteDir: String) {
        preparing = true
        Task {
            defer { preparing = false }
            var startedCount = 0
            for url in urls {
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                let staging = folder.appendingPathComponent(url.lastPathComponent)
                do {
                    try await Task.detached(priority: .utility) {
                        let accessing = url.startAccessingSecurityScopedResource()
                        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                        try FileManager.default.copyItem(at: url, to: staging)
                    }.value
                    let id = await tools.fileUpload(
                        sessionID: sessionID,
                        localPath: staging.path,
                        remoteDir: remoteDir,
                        stagingCleanupURL: folder
                    )
                    if id != nil { startedCount += 1 }
                } catch {
                    try? FileManager.default.removeItem(at: folder)
                    feedback = error.localizedDescription
                }
            }
            if session.sessionID == sessionID, startedCount > 0 {
                feedback = "已开始上传 \(startedCount) 个文件，可在「传输」栏查看进度。"
            }
        }
    }

    private func downloadSelectedRemoteFiles() {
        guard !preparing, let sid = session.sessionID else { return }
        let names = Array(selectedRemoteNames)
        guard !names.isEmpty else { return }
        let baseDir = tools.currentPath
        preparing = true
        Task {
            defer { preparing = false }
            var count = 0
            for name in names {
                let remotePath = (baseDir as NSString).appendingPathComponent(name)
                if await tools.fileDownload(sessionID: sid, remotePath: remotePath) != nil {
                    count += 1
                }
            }
            selectedRemoteNames.removeAll()
            isSelectingRemote = false
            if count > 0 {
                feedback = "已加入 \(count) 个下载任务。"
                ToastCenter.shared.show("已开始下载 \(count) 个文件")
            }
        }
    }

    private func renameRemote(_ entry: ToolService.RemoteFileEntry, to newName: String) {
        guard let sid = session.sessionID else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        let fullPath = (tools.currentPath as NSString).appendingPathComponent(entry.name)
        let dirToRefresh = tools.currentPath
        Task {
            if let err = await tools.fileRenameRemote(sessionID: sid, path: fullPath, newName: trimmed) {
                RCErrorCenter.shared.present(err)
            } else {
                list(dirToRefresh)
            }
        }
    }

    private func deleteRemote(_ entry: ToolService.RemoteFileEntry) {
        guard let sid = session.sessionID else { return }
        let fullPath = (tools.currentPath as NSString).appendingPathComponent(entry.name)
        let dirToRefresh = tools.currentPath
        Task {
            if let err = await tools.fileDeleteRemote(sessionID: sid, path: fullPath) {
                RCErrorCenter.shared.present(err)
            } else {
                list(dirToRefresh)
            }
        }
    }

    private func entrySubtitle(_ entry: ToolService.RemoteFileEntry) -> String? {
        let dateText = entry.modifiedSec.map {
            Self.modifiedFormatter.string(from: Date(timeIntervalSince1970: TimeInterval($0)))
        }
        if entry.isDir {
            return dateText
        }
        let sizeText = bytes(entry.size)
        if let dateText {
            return "\(sizeText) · \(dateText)"
        }
        return sizeText
    }

    private func list(_ path: String?) {
        requestedPath = path
        selectedRemoteNames.removeAll()
        if let sid = session.sessionID { tools.fileList(sessionID: sid, path: path) }
    }

    private var sortedEntries: [ToolService.RemoteFileEntry] {
        tools.fileEntries.sorted {
            if $0.isDir != $1.isDir { return $0.isDir }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private var sortedRemoteFilesOnly: [ToolService.RemoteFileEntry] {
        sortedEntries.filter { !$0.isDir }
    }

    private func bytes(_ count: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: count), countStyle: .file)
    }

    private func isValidName(_ raw: String) -> Bool {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\\")
    }

    private func createFolder() {
        guard isValidName(folderName), let sid = session.sessionID else { return }
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
            if session.sessionID == sid {
                feedback = id == nil ? "下载未开始，请重试" : "已开始下载，可在「传输」或「本机文件」中查看。"
            }
        }
    }
}
