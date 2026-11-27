import CoreGraphics
import Foundation
import RabbitControlCore

/// 工具通道桥接:文件/终端/端口映射,挂在 SessionService 的活动会话上。
/// 随控制会话生命周期保持轮询,避免离开子页面中断后台传输进度或映射状态同步。
@Observable
final class ToolService {
    static let shared = ToolService()

    // ── 终端(多会话并存,支持远端持久化会话恢复与动态尺寸同步) ──
    nonisolated struct TerminalTab: Identifiable, Equatable, Sendable {
        let id: UInt32
        var index: Int
        var title: String = ""
        var cwd: String? = nil
        var cols: UInt16 = 80
        var rows: UInt16 = 24
        var attached: Bool = true
        var output = ""
        var screen = TerminalScreenBuffer(cols: 80, rows: 24)
        var exited = false

        var displayTitle: String {
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
            if let osc = screen.oscTitle, !osc.isEmpty { return osc }
            return "终端 #\(index)"
        }
    }

    private(set) var terminals: [TerminalTab] = []
    private(set) var activeTermID: UInt32?
    private var terminalSerial = 0
    private var preferredCols: UInt16 = 80
    private var preferredRows: UInt16 = 24
    private var pendingAutoOpenIfEmpty = false
    private var sessionListFallbackTask: Task<Void, Never>?

    var termID: UInt32? { activeTermID }
    var activeTerminal: TerminalTab? { terminals.first { $0.id == activeTermID } }
    var terminalOutput: String { activeTerminal?.output ?? "" }
    var terminalExited: Bool { activeTerminal?.exited ?? false }

    // ── 文件 ──
    private(set) var currentPath = "/"
    private(set) var fileEntries: [RemoteFileEntry] = []
    private(set) var listing = false
    private(set) var fileError: String?
    private(set) var fileUiError: RCUiError?
    private(set) var transfers: [TransferItem] = []
    private var stagedUploadFolders: [UInt64: URL] = [:]

    // ── 端口映射 ──
    private(set) var portmapRules: [PortmapRule] = []

    private(set) var lastError: String?
    private(set) var lastUiError: RCUiError?
    private var owner: UInt64?
    private var pollTask: Task<Void, Never>?
    private var listingTimeout: Task<Void, Never>?
    private var listingRequest = UUID()
    private let opQueue = DispatchQueue(label: "com.rabbitcontrol.tools.ops", qos: .userInitiated)

    private init() {}

    nonisolated struct RemoteFileEntry: Identifiable, Hashable, Sendable {
        let name: String
        let isDir: Bool
        let size: UInt64
        let modifiedSec: UInt64?

        init(name: String, isDir: Bool, size: UInt64, modifiedSec: UInt64? = nil) {
            self.name = name
            self.isDir = isDir
            self.size = size
            self.modifiedSec = modifiedSec
        }

        var id: String { name }
    }

    nonisolated struct TransferItem: Identifiable, Hashable, Sendable {
        let id: UInt64
        let fileName: String
        let direction: String
        let totalBytes: UInt64
        let doneBytes: UInt64
        let toPath: String?
        let error: String?
        let status: String

        init(
            id: UInt64,
            fileName: String,
            direction: String = "download",
            totalBytes: UInt64,
            doneBytes: UInt64,
            toPath: String? = nil,
            error: String? = nil,
            status: String
        ) {
            self.id = id
            self.fileName = fileName
            self.direction = direction
            self.totalBytes = totalBytes
            self.doneBytes = doneBytes
            self.toPath = toPath
            self.error = error
            self.status = status
        }

        var isUpload: Bool { direction == "upload" }
        var isTerminal: Bool { status == "done" || status == "failed" || status == "cancelled" }
    }

    nonisolated struct PortmapRule: Identifiable, Hashable, Sendable {
        let id: UInt64
        let name: String
        let localPort: UInt16
        let targetAddr: String
        let targetPort: UInt16
        let enabled: Bool
        let status: String
        let activeConns: UInt32
        let bytesTx: UInt64
        let bytesRx: UInt64
        let error: String?

        init(
            id: UInt64,
            name: String,
            localPort: UInt16,
            targetAddr: String,
            targetPort: UInt16,
            enabled: Bool,
            status: String = "",
            activeConns: UInt32 = 0,
            bytesTx: UInt64 = 0,
            bytesRx: UInt64 = 0,
            error: String? = nil
        ) {
            self.id = id
            self.name = name
            self.localPort = localPort
            self.targetAddr = targetAddr
            self.targetPort = targetPort
            self.enabled = enabled
            self.status = status
            self.activeConns = activeConns
            self.bytesTx = bytesTx
            self.bytesRx = bytesRx
            self.error = error
        }

        var statusLabel: String {
            if !enabled { return "已暂停" }
            if error != nil { return "异常" }
            switch status {
            case "listening", "active", "running", "ready":
                return "监听中"
            case "pending", "starting":
                return "启动中"
            case "stopped", "disabled":
                return "已停止"
            case "error", "failed":
                return "异常"
            default:
                return status.isEmpty ? "监听中" : status
            }
        }
    }

    /// 按可视区域与字号估算等宽终端网格行列数。
    nonisolated static func calculateTerminalGrid(viewportSize: CGSize, fontSize: CGFloat = 13) -> (cols: UInt16, rows: UInt16) {
        guard viewportSize.width > 60, viewportSize.height > 60 else {
            return (80, 24)
        }
        let scale = max(10, min(22, fontSize)) / 13.0
        let charW = 7.8 * scale
        let lineH = 17.0 * scale
        let usableW = max(0, viewportSize.width - 24)
        let usableH = max(0, viewportSize.height - 24)
        let rawCols = Int((usableW / charW).rounded(.down))
        let rawRows = Int((usableH / lineH).rounded(.down))
        let cols = UInt16(min(240, max(32, rawCols)))
        let rows = UInt16(min(80, max(10, rawRows)))
        return (cols, rows)
    }

    // MARK: - 生命周期

    /// 开始收割事件。sessionID 取自 SessionService 活动会话。
    func start(sessionID: UInt64) {
        guard Self.canControl(sessionID) else { return }
        if owner != sessionID {
            stop(clearSessionID: owner)
            owner = sessionID
            transfers = []; fileEntries = []; portmapRules = []; currentPath = "/"
            fileError = nil; fileUiError = nil; terminals = []; activeTermID = nil; terminalSerial = 0
            pendingAutoOpenIfEmpty = false; lastError = nil; lastUiError = nil
        }
        guard pollTask == nil else { return }
        pollTask = Task.detached {
            while !Task.isCancelled {
                guard let resp = Self.poll(sessionID: sessionID) else { break }
                await MainActor.run { [weak self] in
                    guard !Task.isCancelled, self?.owner == sessionID else { return }
                    self?.applyPoll(resp)
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    func stop(clearSessionID: UInt64? = nil) {
        pollTask?.cancel()
        pollTask = nil
        listingTimeout?.cancel()
        sessionListFallbackTask?.cancel()
        sessionListFallbackTask = nil
        pendingAutoOpenIfEmpty = false
        listingRequest = UUID()
        listing = false
        if clearSessionID != nil {
            cleanupAllStagedUploads()
            if owner == clearSessionID {
                owner = nil
                terminals = []
                activeTermID = nil
                terminalSerial = 0
                transfers = []
                portmapRules = []
                fileEntries = []
                currentPath = "/"
                fileError = nil
                fileUiError = nil
                lastError = nil
                lastUiError = nil
            }
        }
    }

    /// 被控端实时关闭文件传输权限时立即收口在途目录加载并记录 `tool.forbidden`。
    func handleFileTransferRevoked(uiError: RCUiError? = nil) {
        listingTimeout?.cancel()
        listingRequest = UUID()
        listing = false
        fileEntries = []
        let resolved = uiError ?? CoreClient.resolveUiError(code: RCErrorCodes.toolForbidden)
        fileUiError = resolved
        fileError = resolved.message.isEmpty ? resolved.title : resolved.message
    }

    // MARK: - 终端操作

    /// 进入终端页时优先枚举并恢复远端存活的持久化会话;若无存活会话则自动新开一个。
    func terminalConnectOrOpen(sessionID: UInt64, cols: UInt16? = nil, rows: UInt16? = nil) {
        guard Self.canControl(sessionID) else { return }
        start(sessionID: sessionID)
        if let cols, cols > 0 { preferredCols = cols }
        if let rows, rows > 0 { preferredRows = rows }
        lastError = nil

        let targetCols = preferredCols
        let targetRows = preferredRows

        // 本地已有未退出标签时直接重连附着并同步尺寸,同时后台拉一次列表对齐远端标签
        if let liveTab = terminals.first(where: { !$0.exited }) {
            if activeTermID == nil || activeTerminal?.exited == true {
                activeTermID = liveTab.id
            }
            for idx in terminals.indices where !terminals[idx].exited {
                let id = terminals[idx].id
                if !terminals[idx].attached {
                    terminals[idx].attached = true
                    terminalAttachAsync(sessionID: sessionID, termID: id, cols: targetCols, rows: targetRows)
                } else if terminals[idx].cols != targetCols || terminals[idx].rows != targetRows {
                    terminals[idx].cols = targetCols
                    terminals[idx].rows = targetRows
                    terminalResizeAsync(sessionID: sessionID, termID: id, cols: targetCols, rows: targetRows)
                }
            }
            requestTerminalListAsync(sessionID: sessionID, openFallbackOnFailure: false)
            return
        }

        pendingAutoOpenIfEmpty = true
        sessionListFallbackTask?.cancel()
        requestTerminalListAsync(sessionID: sessionID, openFallbackOnFailure: true)
        sessionListFallbackTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled,
                  let self,
                  self.owner == sessionID,
                  self.pendingAutoOpenIfEmpty else { return }
            self.pendingAutoOpenIfEmpty = false
            if self.terminals.allSatisfy(\.exited) {
                self.terminalOpen(sessionID: sessionID, cols: self.preferredCols, rows: self.preferredRows)
            }
        }
    }

    private func requestTerminalListAsync(sessionID: UInt64, openFallbackOnFailure: Bool) {
        guard let listPayload = Self.payload(["op": "terminal_list"]) else { return }
        opQueue.async { [weak self] in
            let resp = Self.callFFI(sessionID: sessionID, listPayload)
            let ok = resp?["ok"] as? Bool == true
            if let inlineSessions = (resp?["sessions"] ?? resp?["items"]) as? [[String: Any]] {
                Task { @MainActor [weak self] in
                    guard let self, self.owner == sessionID else { return }
                    self.applyTerminalSessionList(inlineSessions, sessionID: sessionID)
                }
            } else if !ok, openFallbackOnFailure {
                Task { @MainActor [weak self] in
                    guard let self, self.owner == sessionID, self.pendingAutoOpenIfEmpty else { return }
                    self.pendingAutoOpenIfEmpty = false
                    self.sessionListFallbackTask?.cancel()
                    if self.terminals.allSatisfy(\.exited) {
                        self.terminalOpen(sessionID: sessionID, cols: self.preferredCols, rows: self.preferredRows)
                    }
                }
            }
        }
    }

    /// 新开一个终端会话并切为当前标签。
    func terminalOpen(sessionID: UInt64, cols: UInt16? = nil, rows: UInt16? = nil) {
        lastError = nil
        lastUiError = nil
        pendingAutoOpenIfEmpty = false
        sessionListFallbackTask?.cancel()
        let c = cols ?? preferredCols
        let r = rows ?? preferredRows
        preferredCols = c
        preferredRows = r
        let resp = Self.call(sessionID: sessionID, ["op": "terminal_open", "cols": c, "rows": r])
        if let idNum = resp?["term_id"] as? NSNumber {
            let id = idNum.uint32Value
            if let existing = terminals.firstIndex(where: { $0.id == id }) {
                terminals[existing].attached = true
                terminals[existing].exited = false
                terminals[existing].cols = c
                terminals[existing].rows = r
            } else {
                terminalSerial += 1
                terminals.append(TerminalTab(
                    id: id,
                    index: terminalSerial,
                    cols: c,
                    rows: r,
                    attached: true,
                    screen: TerminalScreenBuffer(cols: Int(c), rows: Int(r))
                ))
            }
            activeTermID = id
        } else {
            let uiErr = Self.extractToolUiError(from: resp, fallbackCode: RCErrorCodes.toolTerminalFailed)
            lastUiError = uiErr
            lastError = uiErr.message.isEmpty ? uiErr.title : uiErr.message
            if uiErr.code == RCErrorCodes.toolForbidden {
                RCErrorCenter.shared.present(uiErr)
            }
        }
    }

    func terminalSelect(_ id: UInt32, sessionID: UInt64? = nil) {
        guard let idx = terminals.firstIndex(where: { $0.id == id }) else { return }
        activeTermID = id
        let sid = sessionID ?? owner
        guard let sid, Self.canControl(sid), !terminals[idx].exited else { return }
        if !terminals[idx].attached {
            terminals[idx].attached = true
            terminals[idx].cols = preferredCols
            terminals[idx].rows = preferredRows
            terminalAttachAsync(sessionID: sid, termID: id, cols: preferredCols, rows: preferredRows)
        } else if terminals[idx].cols != preferredCols || terminals[idx].rows != preferredRows {
            terminals[idx].cols = preferredCols
            terminals[idx].rows = preferredRows
            terminalResizeAsync(sessionID: sid, termID: id, cols: preferredCols, rows: preferredRows)
        }
    }

    func terminalResize(sessionID: UInt64, cols: UInt16, rows: UInt16) {
        guard cols > 0, rows > 0 else { return }
        preferredCols = cols
        preferredRows = rows
        guard Self.canControl(sessionID),
              let id = activeTermID,
              let idx = terminals.firstIndex(where: { $0.id == id }),
              !terminals[idx].exited else { return }
        guard terminals[idx].cols != cols || terminals[idx].rows != rows else { return }
        terminals[idx].cols = cols
        terminals[idx].rows = rows
        terminals[idx].screen.resize(cols: Int(cols), rows: Int(rows))
        terminalResizeAsync(sessionID: sessionID, termID: id, cols: cols, rows: rows)
    }

    /// 重命名终端会话标签（同步更新本地标题并向远端发送 `terminal_rename`）。
    func terminalRename(sessionID: UInt64, termID: UInt32, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let idx = terminals.firstIndex(where: { $0.id == termID }) {
            terminals[idx].title = trimmed
        }
        guard let p = Self.payload(["op": "terminal_rename", "term_id": termID, "name": trimmed]) else { return }
        opQueue.async { _ = Self.callFFI(sessionID: sessionID, p) }
    }

    /// 被控端处于锁屏/登录窗口时提交系统口令解锁远程终端（基线 §7.2 `v0.2.1`）。
    func submitTerminalUnlock(sessionID: UInt64, password: String) async -> Result<Void, RCUiError> {
        guard Self.canControl(sessionID) else {
            return .failure(CoreClient.resolveUiError(code: RCErrorCodes.sessionDisconnected))
        }
        if let toolPayload = Self.payload(["op": "terminal_unlock", "password": password]) {
            enum UnlockOutcome: Sendable {
                case ok
                case fallback
                case failed(RCUiError)
            }
            let outcome: UnlockOutcome = await Task.detached(priority: .userInitiated) {
                let resp = Self.callFFI(sessionID: sessionID, toolPayload)
                if resp?["ok"] as? Bool == true {
                    return .ok
                }
                if let errText = resp?["error"] as? String, !errText.contains("unknown variant") {
                    return .failed(Self.extractToolUiError(from: resp, fallbackCode: RCErrorCodes.authInvalidCredentials))
                }
                return .fallback
            }.value
            switch outcome {
            case .ok:
                return .success(())
            case .failed(let err):
                return .failure(err)
            case .fallback:
                break
            }
        }
        // 回退走会话控制通道下发
        if let err = await SessionService.shared.sendExtendedControlCommand([
            "type": "terminal_unlock",
            "password": password,
        ]) {
            return .failure(err)
        }
        return .success(())
    }

    /// 离开终端视图时仅解除输出订阅,不终止远端正在运行的 Shell 进程。
    func terminalDetachAll(sessionID: UInt64) {
        sessionListFallbackTask?.cancel()
        pendingAutoOpenIfEmpty = false
        guard Self.canControl(sessionID) else { return }
        var idsToDetach: [UInt32] = []
        for idx in terminals.indices where terminals[idx].attached && !terminals[idx].exited {
            terminals[idx].attached = false
            idsToDetach.append(terminals[idx].id)
        }
        guard !idsToDetach.isEmpty else { return }
        let payloads = idsToDetach.compactMap { Self.payload(["op": "terminal_detach", "term_id": $0]) }
        opQueue.async {
            for p in payloads {
                _ = Self.callFFI(sessionID: sessionID, p)
            }
        }
    }

    private func terminalAttachAsync(sessionID: UInt64, termID: UInt32, cols: UInt16, rows: UInt16) {
        guard let p = Self.payload(["op": "terminal_attach", "term_id": termID, "cols": cols, "rows": rows]) else { return }
        opQueue.async { _ = Self.callFFI(sessionID: sessionID, p) }
    }

    private func terminalResizeAsync(sessionID: UInt64, termID: UInt32, cols: UInt16, rows: UInt16) {
        guard let p = Self.payload(["op": "terminal_resize", "term_id": termID, "cols": cols, "rows": rows]) else { return }
        opQueue.async { _ = Self.callFFI(sessionID: sessionID, p) }
    }

    @discardableResult func terminalInput(sessionID: UInt64, text: String) -> Bool {
        guard let termID else { return false }
        return Self.call(sessionID: sessionID, ["op": "terminal_input", "term_id": termID, "text": text])?["ok"] as? Bool == true
    }

    /// 关闭指定终端(真正终止远端 Shell),并自动切到相邻标签。
    func terminalClose(sessionID: UInt64, termID id: UInt32? = nil) {
        guard let target = id ?? activeTermID else { return }
        _ = Self.call(sessionID: sessionID, ["op": "terminal_close", "term_id": target])
        let idx = terminals.firstIndex { $0.id == target }
        terminals.removeAll { $0.id == target }
        if activeTermID == target {
            if let nextID = idx.flatMap({ terminals.indices.contains($0) ? terminals[$0].id : terminals.last?.id }) {
                terminalSelect(nextID, sessionID: sessionID)
            } else {
                activeTermID = nil
            }
        }
    }

    func terminalCloseAll(sessionID: UInt64) {
        for tab in terminals { _ = Self.call(sessionID: sessionID, ["op": "terminal_close", "term_id": tab.id]) }
        terminals = []
        activeTermID = nil
    }

    // MARK: - 文件操作

    func fileList(sessionID: UInt64, path: String?) {
        guard owner == sessionID, Self.canControl(sessionID) else {
            let uiErr = CoreClient.resolveUiError(code: RCErrorCodes.toolForbidden)
            fileUiError = uiErr
            fileError = uiErr.message
            return
        }
        guard SessionService.shared.toolPermissions.allowFileTransfer else {
            handleFileTransferRevoked()
            return
        }
        listingTimeout?.cancel()
        let request = UUID()
        listingRequest = request
        var op: [String: Any] = ["op": "file_list_remote"]
        op["path"] = path ?? NSNull()
        fileEntries = []
        guard let payload = Self.payload(op) else {
            listing = false
            let uiErr = CoreClient.resolveUiError(code: RCErrorCodes.validationInvalidInput, detail: "目录路径无效")
            fileUiError = uiErr
            fileError = uiErr.message
            return
        }
        listing = true
        fileError = nil
        fileUiError = nil
        Task { [weak self] in
            let uiErr: RCUiError? = await Task.detached(priority: .medium) {
                let result = Self.callFFI(sessionID: sessionID, payload)
                guard result?["ok"] as? Bool != true else { return nil }
                return Self.extractToolUiError(from: result, fallbackCode: RCErrorCodes.toolFileTransferFailed)
            }.value
            guard let self, let uiErr, owner == sessionID, listingRequest == request, listing else { return }
            listingTimeout?.cancel()
            listing = false
            fileUiError = uiErr
            fileError = uiErr.message.isEmpty ? uiErr.title : uiErr.message
            if uiErr.code == RCErrorCodes.toolForbidden {
                RCErrorCenter.shared.present(uiErr)
            }
        }
        listingTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled, let self, owner == sessionID, listingRequest == request, listing else { return }
            listing = false
            let uiErr = CoreClient.resolveUiError(
                code: RCErrorCodes.networkTimeout,
                detail: "对方未返回目录。请重试，或确认对方已开启文件服务。"
            )
            fileUiError = uiErr
            fileError = "对方未返回目录。请重试，或确认对方已开启文件服务。"
        }
    }

    @discardableResult func fileMkdir(sessionID: UInt64, parent: String, name: String) -> String? {
        guard SessionService.shared.toolPermissions.allowFileTransfer else {
            let uiErr = CoreClient.resolveUiError(code: RCErrorCodes.toolForbidden)
            RCErrorCenter.shared.present(uiErr)
            return uiErr.message
        }
        let result = Self.call(sessionID: sessionID, ["op": "file_mkdir", "parent": parent, "name": name])
        guard result?["ok"] as? Bool != true else { return nil }
        let uiErr = Self.extractToolUiError(from: result, fallbackCode: RCErrorCodes.toolFileTransferFailed)
        if uiErr.code == RCErrorCodes.toolForbidden { RCErrorCenter.shared.present(uiErr) }
        return uiErr.message.isEmpty ? uiErr.title : uiErr.message
    }

    @discardableResult func fileCancel(sessionID: UInt64, transferID: UInt64) -> String? {
        let result = Self.call(sessionID: sessionID, ["op": "file_cancel", "id": transferID])
        if result?["ok"] as? Bool == true {
            cleanupStagedUpload(for: transferID)
            return nil
        }
        let uiErr = Self.extractToolUiError(from: result, fallbackCode: RCErrorCodes.toolFileTransferFailed)
        return uiErr.message.isEmpty ? uiErr.title : uiErr.message
    }

    @discardableResult func fileClearFinished(sessionID: UInt64) -> String? {
        let result = Self.call(sessionID: sessionID, ["op": "file_clear_finished"])
        if result?["ok"] as? Bool == true {
            let finishedIDs = transfers.filter(\.isTerminal).map(\.id)
            for id in finishedIDs { cleanupStagedUpload(for: id) }
            transfers.removeAll(where: \.isTerminal)
            return nil
        }
        let uiErr = Self.extractToolUiError(from: result, fallbackCode: RCErrorCodes.toolFileTransferFailed)
        return uiErr.message.isEmpty ? uiErr.title : uiErr.message
    }

    /// 移除单条已完成/失败/已取消的传输记录（对齐 §7.1 `file_remove_transfer`）。
    func fileRemoveTransfer(sessionID: UInt64, transferID: UInt64) {
        cleanupStagedUpload(for: transferID)
        transfers.removeAll { $0.id == transferID }
        if let p = Self.payload(["op": "file_remove_transfer", "id": transferID]) {
            opQueue.async { _ = Self.callFFI(sessionID: sessionID, p) }
        }
    }

    /// 远端文件或文件夹重命名（对齐 §7.1 `file_rename_remote`）。
    func fileRenameRemote(sessionID: UInt64, path: String, newName: String) async -> RCUiError? {
        guard SessionService.shared.toolPermissions.allowFileTransfer else {
            return CoreClient.resolveUiError(code: RCErrorCodes.toolForbidden)
        }
        guard let payload = Self.payload(["op": "file_rename_remote", "path": path, "new_name": newName]) else {
            return CoreClient.resolveUiError(code: RCErrorCodes.validationInvalidInput)
        }
        return await Task.detached(priority: .userInitiated) {
            let resp = Self.callFFI(sessionID: sessionID, payload)
            if resp?["ok"] as? Bool == true { return nil }
            if let errStr = resp?["error"] as? String, errStr.contains("unknown variant") {
                return CoreClient.resolveUiError(
                    code: RCErrorCodes.validationInvalidConfig,
                    detail: "当前预编译核心库尚未开放远端重命名 FFI，升级最新 xcframework 后自动生效。"
                )
            }
            return Self.extractToolUiError(from: resp, fallbackCode: RCErrorCodes.toolFileTransferFailed)
        }.value
    }

    /// 远端文件或目录删除（对齐 §7.1 `file_delete_remote`）。
    func fileDeleteRemote(sessionID: UInt64, path: String) async -> RCUiError? {
        guard SessionService.shared.toolPermissions.allowFileTransfer else {
            return CoreClient.resolveUiError(code: RCErrorCodes.toolForbidden)
        }
        guard let payload = Self.payload(["op": "file_delete_remote", "path": path]) else {
            return CoreClient.resolveUiError(code: RCErrorCodes.validationInvalidInput)
        }
        return await Task.detached(priority: .userInitiated) {
            let resp = Self.callFFI(sessionID: sessionID, payload)
            if resp?["ok"] as? Bool == true { return nil }
            if let errStr = resp?["error"] as? String, errStr.contains("unknown variant") {
                return CoreClient.resolveUiError(
                    code: RCErrorCodes.validationInvalidConfig,
                    detail: "当前预编译核心库尚未开放远端删除 FFI，升级最新 xcframework 后自动生效。"
                )
            }
            return Self.extractToolUiError(from: resp, fallbackCode: RCErrorCodes.toolFileTransferFailed)
        }.value
    }

    func fileDownload(sessionID: UInt64, remotePath: String) async -> UInt64? {
        await startTransfer(sessionID: sessionID, [
            "op": "file_download",
            "remote_path": remotePath,
            "local_dir": URL.documentsDirectory.path,
        ])
    }

    func fileUpload(
        sessionID: UInt64,
        localPath: String,
        remoteDir: String,
        stagingCleanupURL: URL? = nil
    ) async -> UInt64? {
        let id = await startTransfer(sessionID: sessionID, [
            "op": "file_upload",
            "local_path": localPath,
            "remote_dir": remoteDir,
        ])
        if let stagingCleanupURL {
            if let id {
                stagedUploadFolders[id] = stagingCleanupURL
                // 若轮询先于此处到达并已标记终态，立即补做清理
                if transfers.first(where: { $0.id == id })?.isTerminal == true {
                    cleanupStagedUpload(for: id)
                }
            } else {
                Self.removeTempURLAsync(stagingCleanupURL)
            }
        }
        return id
    }

    private func cleanupStagedUpload(for transferID: UInt64) {
        guard let url = stagedUploadFolders.removeValue(forKey: transferID) else { return }
        Self.removeTempURLAsync(url)
    }

    private func cleanupAllStagedUploads() {
        let urls = Array(stagedUploadFolders.values)
        stagedUploadFolders.removeAll()
        for url in urls {
            Self.removeTempURLAsync(url)
        }
    }

    nonisolated private static func removeTempURLAsync(_ url: URL) {
        DispatchQueue.global(qos: .utility).async {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func startTransfer(sessionID: UInt64, _ op: [String: Any]) async -> UInt64? {
        guard Self.canControl(sessionID) else { return nil }
        guard SessionService.shared.toolPermissions.allowFileTransfer else {
            let uiErr = CoreClient.resolveUiError(code: RCErrorCodes.toolForbidden)
            fileUiError = uiErr
            fileError = uiErr.message
            RCErrorCenter.shared.present(uiErr)
            return nil
        }
        guard let payload = Self.payload(op) else { return nil }
        let (transferID, uiErr): (UInt64?, RCUiError?) = await Task.detached(priority: .medium) {
            let result = Self.callFFI(sessionID: sessionID, payload)
            if let tid = (result?["transfer_id"] as? NSNumber)?.uint64Value {
                return (tid, nil)
            }
            return (nil, Self.extractToolUiError(from: result, fallbackCode: RCErrorCodes.toolFileTransferFailed))
        }.value
        if let uiErr {
            fileUiError = uiErr
            if uiErr.code == RCErrorCodes.toolForbidden {
                fileError = uiErr.message
                RCErrorCenter.shared.present(uiErr)
            }
        }
        return transferID
    }

    // MARK: - 端口映射操作

    func portmapRefresh(sessionID: UInt64) {
        guard Self.canControl(sessionID), let listPayload = Self.payload(["op": "portmap_list"]) else { return }
        opQueue.async { [weak self] in
            guard let resp = Self.callFFI(sessionID: sessionID, listPayload),
                  let rules = resp["rules"] as? [[String: Any]] else { return }
            let decoded = Self.decodePortmapRules(rules)
            Task { @MainActor [weak self] in
                guard let self, self.owner == sessionID else { return }
                self.portmapRules = decoded
            }
        }
    }

    func portmapAdd(
        sessionID: UInt64,
        name: String,
        localPort: UInt16,
        remoteHost: String,
        remotePort: UInt16,
        enabled: Bool = true,
        persistDeviceID: String? = nil
    ) -> String? {
        guard SessionService.shared.toolPermissions.allowPortMap else {
            let uiErr = CoreClient.resolveUiError(code: RCErrorCodes.toolForbidden)
            RCErrorCenter.shared.present(uiErr)
            return uiErr.message
        }
        let result = Self.call(sessionID: sessionID, [
            "op": "portmap_add", "name": name, "local_port": localPort,
            "remote_host": remoteHost, "remote_port": remotePort, "enabled": enabled,
        ])
        if result?["ok"] as? Bool == true {
            if let persistDeviceID {
                PortMapStore.shared.upsertRule(
                    deviceID: persistDeviceID,
                    name: name,
                    localPort: localPort,
                    targetAddr: remoteHost,
                    targetPort: remotePort,
                    enabled: enabled
                )
            }
            return nil
        }
        let uiErr = Self.extractToolUiError(from: result, fallbackCode: RCErrorCodes.toolPortmapBindFailed)
        if uiErr.code == RCErrorCodes.toolForbidden { RCErrorCenter.shared.present(uiErr) }
        return uiErr.message.isEmpty ? uiErr.title : uiErr.message
    }

    @discardableResult func portmapToggle(
        sessionID: UInt64,
        ruleID: UInt64,
        enabled: Bool,
        localPort: UInt16? = nil,
        persistDeviceID: String? = nil
    ) -> String? {
        let result = Self.call(sessionID: sessionID, ["op": "portmap_toggle", "rule_id": ruleID, "enabled": enabled])
        if result?["ok"] as? Bool == true {
            if let persistDeviceID, let localPort {
                PortMapStore.shared.updateEnabled(deviceID: persistDeviceID, localPort: localPort, enabled: enabled)
            }
            return nil
        }
        let uiErr = Self.extractToolUiError(from: result, fallbackCode: RCErrorCodes.toolPortmapBindFailed)
        return uiErr.message.isEmpty ? uiErr.title : uiErr.message
    }

    @discardableResult func portmapRemove(
        sessionID: UInt64,
        ruleID: UInt64,
        localPort: UInt16? = nil,
        persistDeviceID: String? = nil
    ) -> String? {
        let result = Self.call(sessionID: sessionID, ["op": "portmap_remove", "rule_id": ruleID])
        if result?["ok"] as? Bool == true {
            if let persistDeviceID, let localPort {
                PortMapStore.shared.removeRule(deviceID: persistDeviceID, localPort: localPort)
            }
            return nil
        }
        let uiErr = Self.extractToolUiError(from: result, fallbackCode: RCErrorCodes.toolPortmapBindFailed)
        return uiErr.message.isEmpty ? uiErr.title : uiErr.message
    }

    /// 编辑已有端口映射规则（原子删除旧规则后按新参数重建并更新持久化）。
    func portmapUpdate(
        sessionID: UInt64,
        existingRule: PortmapRule,
        name: String,
        localPort: UInt16,
        remoteHost: String,
        remotePort: UInt16,
        persistDeviceID: String?
    ) -> String? {
        if let err = portmapRemove(
            sessionID: sessionID,
            ruleID: existingRule.id,
            localPort: existingRule.localPort,
            persistDeviceID: persistDeviceID
        ) {
            return err
        }
        return portmapAdd(
            sessionID: sessionID,
            name: name,
            localPort: localPort,
            remoteHost: remoteHost,
            remotePort: remotePort,
            enabled: existingRule.enabled,
            persistDeviceID: persistDeviceID
        )
    }

    // MARK: - 事件解析与应用

    nonisolated static func decodeRemoteFileEntry(_ dict: [String: Any]) -> RemoteFileEntry? {
        guard let name = dict["name"] as? String else { return nil }
        let modified = (dict["modifiedSec"] as? NSNumber ?? dict["modified_sec"] as? NSNumber)?.uint64Value
        return RemoteFileEntry(
            name: name,
            isDir: dict["is_dir"] as? Bool ?? dict["isDir"] as? Bool ?? false,
            size: (dict["size"] as? NSNumber)?.uint64Value ?? 0,
            modifiedSec: (modified ?? 0) > 0 ? modified : nil
        )
    }

    nonisolated static func decodeTransferItem(_ dict: [String: Any]) -> TransferItem? {
        guard let id = (dict["id"] as? NSNumber)?.uint64Value,
              let name = dict["name"] as? String,
              let status = dict["status"] as? String else { return nil }
        return TransferItem(
            id: id,
            fileName: name,
            direction: dict["direction"] as? String ?? dict["kind"] as? String ?? "download",
            totalBytes: (dict["totalBytes"] as? NSNumber)?.uint64Value ?? 0,
            doneBytes: (dict["doneBytes"] as? NSNumber)?.uint64Value ?? 0,
            toPath: dict["toPath"] as? String,
            error: dict["error"] as? String,
            status: status
        )
    }

    nonisolated static func decodePortmapRules(_ rawRules: [[String: Any]]) -> [PortmapRule] {
        rawRules.compactMap { r in
            guard let id = (r["id"] as? NSNumber)?.uint64Value else { return nil }
            return PortmapRule(
                id: id,
                name: r["name"] as? String ?? "",
                localPort: (r["localPort"] as? NSNumber)?.uint16Value ?? 0,
                targetAddr: r["targetAddr"] as? String ?? "",
                targetPort: (r["targetPort"] as? NSNumber)?.uint16Value ?? 0,
                enabled: r["enabled"] as? Bool ?? false,
                status: r["status"] as? String ?? "",
                activeConns: (r["activeConns"] as? NSNumber)?.uint32Value ?? 0,
                bytesTx: (r["bytesTx"] as? NSNumber)?.uint64Value ?? 0,
                bytesRx: (r["bytesRx"] as? NSNumber)?.uint64Value ?? 0,
                error: r["error"] as? String
            )
        }
    }

    private func applyTerminalSessionList(_ list: [[String: Any]], sessionID: UInt64) {
        sessionListFallbackTask?.cancel()
        let shouldAutoOpen = pendingAutoOpenIfEmpty
        pendingAutoOpenIfEmpty = false

        var discoveredIDs: [UInt32] = []
        for s in list {
            guard let id = (s["termId"] as? NSNumber ?? s["term_id"] as? NSNumber)?.uint32Value else { continue }
            discoveredIDs.append(id)
            let title = s["title"] as? String ?? ""
            let cwd = s["cwd"] as? String
            let cols = (s["cols"] as? NSNumber)?.uint16Value ?? preferredCols
            let rows = (s["rows"] as? NSNumber)?.uint16Value ?? preferredRows
            let remoteAttached = s["attached"] as? Bool ?? false

            if let idx = terminals.firstIndex(where: { $0.id == id }) {
                if !title.isEmpty { terminals[idx].title = title }
                if let cwd, !cwd.isEmpty { terminals[idx].cwd = cwd }
                terminals[idx].cols = cols
                terminals[idx].rows = rows
                terminals[idx].screen.resize(cols: Int(cols), rows: Int(rows))
                terminals[idx].exited = false
            } else {
                terminalSerial += 1
                terminals.append(TerminalTab(
                    id: id,
                    index: terminalSerial,
                    title: title,
                    cwd: cwd,
                    cols: cols,
                    rows: rows,
                    attached: remoteAttached,
                    output: "",
                    screen: TerminalScreenBuffer(cols: Int(cols), rows: Int(rows)),
                    exited: false
                ))
            }
        }

        if discoveredIDs.isEmpty {
            if shouldAutoOpen, terminals.allSatisfy(\.exited) {
                terminalOpen(sessionID: sessionID, cols: preferredCols, rows: preferredRows)
            }
            return
        }

        if activeTermID == nil || activeTerminal?.exited == true {
            activeTermID = discoveredIDs.first
        }

        // 对当前选中的会话(或待恢复的会话)执行 attach 以同步回放缓冲与实时输出
        if let activeID = activeTermID,
           let idx = terminals.firstIndex(where: { $0.id == activeID }),
           !terminals[idx].exited,
           !terminals[idx].attached {
            terminals[idx].attached = true
            terminals[idx].cols = preferredCols
            terminals[idx].rows = preferredRows
            terminalAttachAsync(sessionID: sessionID, termID: activeID, cols: preferredCols, rows: preferredRows)
        }
    }

    private func applyPoll(_ resp: [String: Any]) {
        if let events = resp["terminal_events"] as? [[String: Any]] {
            for ev in events {
                guard let type = ev["type"] as? String else { continue }
                switch type {
                case "sessionList":
                    if let sid = owner {
                        let rawSessions = (ev["sessions"] ?? ev["items"] ?? ev["list"]) as? [[String: Any]] ?? []
                        applyTerminalSessionList(rawSessions, sessionID: sid)
                    }
                case "opened":
                    guard let id = (ev["termId"] as? NSNumber)?.uint32Value else { continue }
                    let info = ev["session"] as? [String: Any]
                    let title = info?["title"] as? String ?? ""
                    let cwd = info?["cwd"] as? String
                    if let idx = terminals.firstIndex(where: { $0.id == id }) {
                        if !title.isEmpty { terminals[idx].title = title }
                        if let cwd, !cwd.isEmpty { terminals[idx].cwd = cwd }
                        terminals[idx].exited = false
                    } else {
                        terminalSerial += 1
                        terminals.append(TerminalTab(
                            id: id,
                            index: terminalSerial,
                            title: title,
                            cwd: cwd,
                            cols: preferredCols,
                            rows: preferredRows,
                            attached: true
                        ))
                        if activeTermID == nil { activeTermID = id }
                    }
                case "renamed":
                    guard let id = (ev["termId"] as? NSNumber)?.uint32Value,
                          let idx = terminals.firstIndex(where: { $0.id == id }) else { continue }
                    if let title = ev["title"] as? String, !title.isEmpty {
                        terminals[idx].title = title
                    }
                    if let cwd = ev["cwd"] as? String, !cwd.isEmpty {
                        terminals[idx].cwd = cwd
                    }
                case "output":
                    guard let id = (ev["termId"] as? NSNumber)?.uint32Value else { continue }
                    let idx: Int
                    if let existing = terminals.firstIndex(where: { $0.id == id }) {
                        idx = existing
                    } else {
                        terminalSerial += 1
                        terminals.append(TerminalTab(id: id, index: terminalSerial, cols: preferredCols, rows: preferredRows, attached: true))
                        idx = terminals.count - 1
                        if activeTermID == nil { activeTermID = id }
                    }
                    if let text = ev["textUtf8Lossy"] as? String {
                        terminals[idx].output += text
                        terminals[idx].screen.feed(text)
                        // 移动端内存保护:每个终端保留尾部 200k 原始字符
                        if terminals[idx].output.count > 200_000 {
                            terminals[idx].output = String(terminals[idx].output.suffix(150_000))
                        }
                    }
                case "exited":
                    if let id = (ev["termId"] as? NSNumber)?.uint32Value,
                       let idx = terminals.firstIndex(where: { $0.id == id }) {
                        terminals[idx].exited = true
                        terminals[idx].attached = false
                    }
                default:
                    break
                }
            }
        }
        if let events = resp["file_events"] as? [[String: Any]] {
            for ev in events {
                guard let type = ev["type"] as? String else { continue }
                switch type {
                case "remoteDir":
                    listingTimeout?.cancel()
                    listing = false
                    currentPath = ev["path"] as? String ?? currentPath
                    if let rawErr = ev["error"] as? String, !rawErr.isEmpty {
                        let uiErr = CoreClient.resolveUiError(code: RCErrorCodes.toolFileTransferFailed, detail: rawErr)
                        fileUiError = uiErr
                        fileError = rawErr
                    } else {
                        fileUiError = nil
                        fileError = nil
                    }
                    let raw = ev["entries"] as? [[String: Any]] ?? []
                    fileEntries = raw.compactMap(Self.decodeRemoteFileEntry)
                case "transferUpdated":
                    guard let item = Self.decodeTransferItem(ev) else { continue }
                    if let index = transfers.firstIndex(where: { $0.id == item.id }) {
                        transfers[index] = item
                    } else {
                        transfers.insert(item, at: 0)
                    }
                    if item.isTerminal {
                        cleanupStagedUpload(for: item.id)
                    }
                case "mkdirResult":
                    if ev["ok"] as? Bool == false, let err = ev["error"] as? String {
                        fileError = err
                    }
                default:
                    break
                }
            }
        }
        if let rules = resp["portmap_rules"] as? [[String: Any]] {
            portmapRules = Self.decodePortmapRules(rules)
        }
    }

    // MARK: - FFI 辅助

    private static func canControl(_ id: UInt64) -> Bool {
        let session = SessionService.shared
        return session.sessionID == id
            && session.isConnected
            && !session.effectiveWatchOnly
            && !AppLockStore.shared.isLocked
    }

    private static func call(sessionID: UInt64, _ op: [String: Any]) -> [String: Any]? {
        guard canControl(sessionID) else {
            let uiErr = CoreClient.resolveUiError(code: RCErrorCodes.toolForbidden, detail: "当前会话不允许远程工具操作")
            return ["error": uiErr.message]
        }
        guard let payload = payload(op) else { return nil }
        return callFFI(sessionID: sessionID, payload)
    }

    nonisolated private static func extractToolUiError(
        from resp: [String: Any]?,
        fallbackCode: String
    ) -> RCUiError {
        if let resp, let uiErr = RCUiErrorCodec.extractEnvelopeError(from: resp, fallbackCode: fallbackCode) {
            return uiErr
        }
        return CoreClient.resolveUiError(code: fallbackCode)
    }

    private static func payload(_ op: [String: Any]) -> String? {
        (try? JSONSerialization.data(withJSONObject: op)).flatMap { String(data: $0, encoding: .utf8) }
    }

    nonisolated private static func callFFI(sessionID: UInt64, _ payload: String) -> [String: Any]? {
        payload.withCString { cstr in
            guard let ptr = rc_tools_call(sessionID, cstr) else { return nil }
            defer { rc_string_free(ptr) }
            let s = String(cString: ptr)
            guard let d = s.data(using: .utf8) else { return nil }
            return try? JSONSerialization.jsonObject(with: d) as? [String: Any]
        }
    }

    nonisolated private static func poll(sessionID: UInt64) -> [String: Any]? {
        guard let ptr = rc_tools_poll(sessionID) else { return nil }
        defer { rc_string_free(ptr) }
        let s = String(cString: ptr)
        guard let d = s.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: d) as? [String: Any]
    }
}
