import Foundation
import RabbitControlCore

/// 工具通道桥接:文件/终端/端口映射,挂在 SessionService 的活动会话上。
/// 写操作走 rc_tools_call,事件走 250ms 轮询 rc_tools_poll。
@Observable
final class ToolService {
    static let shared = ToolService()

    // ── 终端(多会话并存,activeTermID 为当前标签) ──
    struct TerminalTab: Identifiable, Equatable {
        let id: UInt32
        var index: Int
        var output = ""
        var exited = false
    }
    private(set) var terminals: [TerminalTab] = []
    private(set) var activeTermID: UInt32?
    private var terminalSerial = 0
    var termID: UInt32? { activeTermID }
    var terminalOutput: String { terminals.first { $0.id == activeTermID }?.output ?? "" }
    var terminalExited: Bool { terminals.first { $0.id == activeTermID }?.exited ?? false }

    // ── 文件 ──
    private(set) var currentPath = "/"
    private(set) var fileEntries: [RemoteFileEntry] = []
    private(set) var listing = false
    private(set) var fileError: String?
    private(set) var transfers: [TransferItem] = []

    // ── 端口映射 ──
    private(set) var portmapRules: [PortmapRule] = []

    private(set) var lastError: String?
    private var owner: UInt64?
    private var pollTask: Task<Void, Never>?
    private var listingTimeout: Task<Void, Never>?
    private var listingRequest = UUID()

    private init() {}

    struct RemoteFileEntry: Identifiable, Hashable {
        let name: String
        let isDir: Bool
        let size: UInt64
        var id: String { name }
    }

    struct TransferItem: Identifiable, Hashable {
        let id: UInt64
        let fileName: String
        let totalBytes: UInt64
        let doneBytes: UInt64
        let error: String?
        let status: String
    }

    struct PortmapRule: Identifiable, Hashable {
        let id: UInt64
        let name: String
        let localPort: UInt16
        let targetAddr: String
        let targetPort: UInt16
        let enabled: Bool
        let error: String?
    }

    // MARK: - 生命周期

    /// 开始收割事件。sessionID 取自 SessionService 活动会话。
    func start(sessionID: UInt64) {
        guard Self.canControl(sessionID) else { return }
        if owner != sessionID {
            stop()
            owner = sessionID
            transfers = []; fileEntries = []; portmapRules = []; currentPath = "/"
            fileError = nil; terminals = []; activeTermID = nil; terminalSerial = 0; lastError = nil
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

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        listingTimeout?.cancel()
        listingRequest = UUID()
        listing = false
    }

    // MARK: - 终端操作

    /// 新开一个终端会话并切为当前标签。
    func terminalOpen(sessionID: UInt64, cols: UInt16 = 80, rows: UInt16 = 24) {
        lastError = nil
        if let resp = Self.call(sessionID: sessionID, ["op": "terminal_open", "cols": cols, "rows": rows]),
           let id = resp["term_id"] as? NSNumber {
            terminalSerial += 1
            terminals.append(TerminalTab(id: id.uint32Value, index: terminalSerial))
            activeTermID = id.uint32Value
        } else {
            lastError = "终端打开失败"
        }
    }

    func terminalSelect(_ id: UInt32) {
        guard terminals.contains(where: { $0.id == id }) else { return }
        activeTermID = id
    }

    @discardableResult func terminalInput(sessionID: UInt64, text: String) -> Bool {
        guard let termID else { return false }
        return Self.call(sessionID: sessionID, ["op": "terminal_input", "term_id": termID, "text": text])?["ok"] as? Bool == true
    }

    /// 关闭指定终端(默认当前标签),切到相邻标签。
    func terminalClose(sessionID: UInt64, termID id: UInt32? = nil) {
        guard let target = id ?? activeTermID else { return }
        _ = Self.call(sessionID: sessionID, ["op": "terminal_close", "term_id": target])
        let idx = terminals.firstIndex { $0.id == target }
        terminals.removeAll { $0.id == target }
        if activeTermID == target {
            activeTermID = idx.flatMap { terminals.indices.contains($0) ? terminals[$0].id : terminals.last?.id }
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
            fileError = "当前会话不允许远程工具操作"
            return
        }
        listingTimeout?.cancel()
        let request = UUID()
        listingRequest = request
        var op: [String: Any] = ["op": "file_list_remote"]
        op["path"] = path ?? NSNull()
        fileEntries = []
        guard let payload = Self.payload(op) else { listing = false; fileError = "目录路径无效"; return }
        listing = true
        fileError = nil
        Task { [weak self] in
            let error: String? = await Task.detached(priority: .medium) {
                let result = Self.callFFI(sessionID: sessionID, payload)
                return result?["ok"] as? Bool == true ? nil : (result?["error"] as? String ?? "目录读取失败")
            }.value
            guard let self, let error, owner == sessionID, listingRequest == request, listing else { return }
            listingTimeout?.cancel()
            listing = false
            fileError = error
        }
        listingTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled, let self, owner == sessionID, listingRequest == request, listing else { return }
            listing = false
            fileError = "对方未返回目录。请重试，或确认对方已开启文件服务。"
        }
    }

    @discardableResult func fileMkdir(sessionID: UInt64, parent: String, name: String) -> String? {
        let result = Self.call(sessionID: sessionID, ["op": "file_mkdir", "parent": parent, "name": name])
        return result?["ok"] as? Bool == true ? nil : (result?["error"] as? String ?? "无法新建文件夹")
    }

    @discardableResult func fileCancel(sessionID: UInt64, transferID: UInt64) -> String? {
        let result = Self.call(sessionID: sessionID, ["op": "file_cancel", "id": transferID])
        return result?["ok"] as? Bool == true ? nil : (result?["error"] as? String ?? "无法取消传输")
    }

    @discardableResult func fileClearFinished(sessionID: UInt64) -> String? {
        let result = Self.call(sessionID: sessionID, ["op": "file_clear_finished"])
        return result?["ok"] as? Bool == true ? nil : (result?["error"] as? String ?? "无法清除已完成传输")
    }

    func fileDownload(sessionID: UInt64, remotePath: String) async -> UInt64? {
        await startTransfer(sessionID: sessionID, ["op": "file_download", "remote_path": remotePath,
                                                  "local_dir": URL.documentsDirectory.path])
    }

    func fileUpload(sessionID: UInt64, localPath: String, remoteDir: String) async -> UInt64? {
        await startTransfer(sessionID: sessionID, ["op": "file_upload", "local_path": localPath,
                                                  "remote_dir": remoteDir])
    }

    private func startTransfer(sessionID: UInt64, _ op: [String: Any]) async -> UInt64? {
        guard Self.canControl(sessionID), let payload = Self.payload(op) else { return nil }
        return await Task.detached(priority: .medium) {
            let result = Self.callFFI(sessionID: sessionID, payload)
            return (result?["transfer_id"] as? NSNumber)?.uint64Value
        }.value
    }

    // MARK: - 端口映射操作

    func portmapAdd(sessionID: UInt64, name: String, localPort: UInt16, remoteHost: String, remotePort: UInt16) -> String? {
        let result = Self.call(sessionID: sessionID, [
            "op": "portmap_add", "name": name, "local_port": localPort,
            "remote_host": remoteHost, "remote_port": remotePort, "enabled": true,
        ])
        return result?["ok"] as? Bool == true ? nil : (result?["error"] as? String ?? "无法添加映射")
    }

    @discardableResult func portmapToggle(sessionID: UInt64, ruleID: UInt64, enabled: Bool) -> String? {
        let result = Self.call(sessionID: sessionID, ["op": "portmap_toggle", "rule_id": ruleID, "enabled": enabled])
        return result?["ok"] as? Bool == true ? nil : (result?["error"] as? String ?? "未能切换映射状态")
    }

    @discardableResult func portmapRemove(sessionID: UInt64, ruleID: UInt64) -> String? {
        let result = Self.call(sessionID: sessionID, ["op": "portmap_remove", "rule_id": ruleID])
        return result?["ok"] as? Bool == true ? nil : (result?["error"] as? String ?? "未能移除映射")
    }

    // MARK: - 事件应用

    private func applyPoll(_ resp: [String: Any]) {
        if let events = resp["terminal_events"] as? [[String: Any]] {
            for ev in events {
                guard let type = ev["type"] as? String else { continue }
                switch type {
                case "output":
                    guard let id = (ev["termId"] as? NSNumber)?.uint32Value,
                          let idx = terminals.firstIndex(where: { $0.id == id }) else { continue }
                    if let text = ev["textUtf8Lossy"] as? String {
                        terminals[idx].output += text
                        // 移动端内存保护:每个终端保留尾部 200k 字符
                        if terminals[idx].output.count > 200_000 {
                            terminals[idx].output = String(terminals[idx].output.suffix(150_000))
                        }
                    }
                case "exited":
                    if let id = (ev["termId"] as? NSNumber)?.uint32Value,
                       let idx = terminals.firstIndex(where: { $0.id == id }) { terminals[idx].exited = true }
                default:
                    break
                }
            }
        }
        if let events = resp["file_events"] as? [[String: Any]] {
            for ev in events {
                guard let type = ev["type"] as? String else { continue }
                if type == "remoteDir" {
                    listingTimeout?.cancel()
                    listing = false
                    currentPath = ev["path"] as? String ?? currentPath
                    fileError = ev["error"] as? String
                    let raw = ev["entries"] as? [[String: Any]] ?? []
                    fileEntries = raw.compactMap { e in
                        guard let name = e["name"] as? String else { return nil }
                        return RemoteFileEntry(
                            name: name,
                            isDir: e["is_dir"] as? Bool ?? e["isDir"] as? Bool ?? false,
                            size: (e["size"] as? NSNumber)?.uint64Value ?? 0
                        )
                    }
                } else if type == "transferUpdated", let id = (ev["id"] as? NSNumber)?.uint64Value,
                          let name = ev["name"] as? String, let status = ev["status"] as? String {
                    let item = TransferItem(id: id, fileName: name, totalBytes: (ev["totalBytes"] as? NSNumber)?.uint64Value ?? 0,
                                            doneBytes: (ev["doneBytes"] as? NSNumber)?.uint64Value ?? 0,
                                            error: ev["error"] as? String, status: status)
                    if let index = transfers.firstIndex(where: { $0.id == id }) { transfers[index] = item }
                    else { transfers.insert(item, at: 0) }
                }
            }
        }
        if let rules = resp["portmap_rules"] as? [[String: Any]] {
            portmapRules = rules.compactMap { r in
                guard let id = (r["id"] as? NSNumber)?.uint64Value else { return nil }
                return PortmapRule(
                    id: id,
                    name: r["name"] as? String ?? "",
                    localPort: (r["localPort"] as? NSNumber)?.uint16Value ?? 0,
                    targetAddr: r["targetAddr"] as? String ?? "",
                    targetPort: (r["targetPort"] as? NSNumber)?.uint16Value ?? 0,
                    enabled: r["enabled"] as? Bool ?? false,
                    error: r["error"] as? String
                )
            }
        }
    }

    // MARK: - FFI 辅助

    private static func canControl(_ id: UInt64) -> Bool {
        let session = SessionService.shared
        return session.sessionID == id && session.isConnected && !session.peerWatchOnly
    }

    private static func call(sessionID: UInt64, _ op: [String: Any]) -> [String: Any]? {
        guard canControl(sessionID) else { return ["error": "当前会话不允许远程工具操作"] }
        guard let payload = payload(op) else { return nil }
        return callFFI(sessionID: sessionID, payload)
    }

    private static func payload(_ op: [String: Any]) -> String? {
        (try? JSONSerialization.data(withJSONObject: op)).flatMap { String(data: $0, encoding: .utf8) }
    }

    nonisolated private static func callFFI(sessionID: UInt64, _ payload: String) -> [String: Any]? {
        return payload.withCString { cstr in
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
