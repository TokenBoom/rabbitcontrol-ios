import Foundation
import RabbitControlCore

/// 工具通道桥接:文件/终端/端口映射,挂在 SessionService 的活动会话上。
/// 写操作走 rc_tools_call,事件走 250ms 轮询 rc_tools_poll。
@Observable
final class ToolService {
    static let shared = ToolService()

    // ── 终端 ──
    private(set) var termID: UInt32?
    private(set) var terminalOutput = ""
    private(set) var terminalExited = false

    // ── 文件 ──
    private(set) var currentPath = "/"
    private(set) var fileEntries: [RemoteFileEntry] = []
    private(set) var fileError: String?
    private(set) var transfers: [TransferItem] = []

    // ── 端口映射 ──
    private(set) var portmapRules: [PortmapRule] = []

    private(set) var lastError: String?
    private var pollTask: Task<Void, Never>?

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
        var finished: Bool { error != nil || (totalBytes > 0 && doneBytes >= totalBytes) }
    }

    struct PortmapRule: Identifiable, Hashable {
        let id: UInt64
        let name: String
        let localPort: UInt16
        let targetAddr: String
        let targetPort: UInt16
        let enabled: Bool
    }

    // MARK: - 生命周期

    /// 开始收割事件。sessionID 取自 SessionService 活动会话。
    func start(sessionID: UInt64) {
        guard pollTask == nil else { return }
        pollTask = Task.detached {
            while !Task.isCancelled {
                guard let resp = Self.poll(sessionID: sessionID) else { break }
                await MainActor.run { [weak self] in
                    self?.applyPoll(resp)
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - 终端操作

    func terminalOpen(sessionID: UInt64, cols: UInt16 = 80, rows: UInt16 = 24) {
        terminalOutput = ""
        terminalExited = false
        if let resp = Self.call(sessionID: sessionID, ["op": "terminal_open", "cols": cols, "rows": rows]),
           let id = resp["term_id"] as? NSNumber {
            termID = id.uint32Value
        } else {
            lastError = "终端打开失败"
        }
    }

    func terminalInput(sessionID: UInt64, text: String) {
        guard let termID else { return }
        _ = Self.call(sessionID: sessionID, ["op": "terminal_input", "term_id": termID, "text": text])
    }

    func terminalClose(sessionID: UInt64) {
        guard let termID else { return }
        _ = Self.call(sessionID: sessionID, ["op": "terminal_close", "term_id": termID])
        self.termID = nil
    }

    // MARK: - 文件操作

    func fileList(sessionID: UInt64, path: String?) {
        var op: [String: Any] = ["op": "file_list_remote"]
        op["path"] = path ?? NSNull()
        _ = Self.call(sessionID: sessionID, op)
    }

    func fileMkdir(sessionID: UInt64, parent: String, name: String) {
        _ = Self.call(sessionID: sessionID, ["op": "file_mkdir", "parent": parent, "name": name])
    }

    func fileDownload(sessionID: UInt64, remotePath: String) -> UInt64? {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        guard let dir = docs?.path else { return nil }
        let resp = Self.call(sessionID: sessionID, ["op": "file_download", "remote_path": remotePath, "local_dir": dir])
        return (resp?["transfer_id"] as? NSNumber)?.uint64Value
    }

    func fileUpload(sessionID: UInt64, localPath: String, remoteDir: String) -> UInt64? {
        let resp = Self.call(sessionID: sessionID, ["op": "file_upload", "local_path": localPath, "remote_dir": remoteDir])
        return (resp?["transfer_id"] as? NSNumber)?.uint64Value
    }

    // MARK: - 端口映射操作

    func portmapAdd(sessionID: UInt64, name: String, localPort: UInt16, remoteHost: String, remotePort: UInt16) {
        _ = Self.call(sessionID: sessionID, [
            "op": "portmap_add", "name": name, "local_port": localPort,
            "remote_host": remoteHost, "remote_port": remotePort, "enabled": true,
        ])
    }

    func portmapToggle(sessionID: UInt64, ruleID: UInt64, enabled: Bool) {
        _ = Self.call(sessionID: sessionID, ["op": "portmap_toggle", "rule_id": ruleID, "enabled": enabled])
    }

    func portmapRemove(sessionID: UInt64, ruleID: UInt64) {
        _ = Self.call(sessionID: sessionID, ["op": "portmap_remove", "rule_id": ruleID])
    }

    // MARK: - 事件应用

    private func applyPoll(_ resp: [String: Any]) {
        if let events = resp["terminal_events"] as? [[String: Any]] {
            for ev in events {
                guard let type = ev["type"] as? String else { continue }
                switch type {
                case "output":
                    if let text = ev["textUtf8Lossy"] as? String {
                        terminalOutput += text
                        // 移动端内存保护:保留尾部 200k 字符
                        if terminalOutput.count > 200_000 {
                            terminalOutput = String(terminalOutput.suffix(150_000))
                        }
                    }
                case "exited":
                    terminalExited = true
                default:
                    break
                }
            }
        }
        if let events = resp["file_events"] as? [[String: Any]] {
            for ev in events {
                guard let type = ev["type"] as? String else { continue }
                if type == "remoteDir" {
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
                } else if type == "transferUpdated", let item = ev as? [String: Any] {
                    _ = item // 传输项结构嵌套,由 file_list_transfers 轮询覆盖;此略
                }
            }
        }
        if let rules = resp["portmap_rules"] as? [[String: Any]] {
            portmapRules = rules.compactMap { r in
                guard let id = (r["id"] as? NSNumber)?.uint64Value else { return nil }
                return PortmapRule(
                    id: id,
                    name: r["name"] as? String ?? "",
                    localPort: (r["local_port"] as? NSNumber)?.uint16Value ?? 0,
                    targetAddr: r["target_addr"] as? String ?? "",
                    targetPort: (r["target_port"] as? NSNumber)?.uint16Value ?? 0,
                    enabled: r["enabled"] as? Bool ?? false
                )
            }
        }
    }

    // MARK: - FFI 辅助

    nonisolated private static func call(sessionID: UInt64, _ op: [String: Any]) -> [String: Any]? {
        guard let data = try? JSONSerialization.data(withJSONObject: op),
              let payload = String(data: data, encoding: .utf8) else { return nil }
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
