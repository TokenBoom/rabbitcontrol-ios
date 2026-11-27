import Foundation

/// 端口映射规则本地持久化与重连自动恢复（对齐 macOS 基线 §7.3 `portmaps_restored`）。
@Observable
final class PortMapStore {
    static let shared = PortMapStore()

    nonisolated struct SavedRule: Codable, Identifiable, Equatable, Hashable, Sendable {
        var id: UUID = UUID()
        var deviceKey: String
        var name: String
        var localPort: UInt16
        var targetAddr: String
        var targetPort: UInt16
        var enabled: Bool
    }

    private(set) var savedRules: [SavedRule] = []
    private let defaults: UserDefaults
    private let storageKey = "portmap.savedRules.v1"
    private var restoredSessionIDs = Set<UInt64>()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([SavedRule].self, from: data) {
            self.savedRules = decoded
        }
    }

    func rules(for deviceID: String) -> [SavedRule] {
        let key = Self.normalizeDeviceKey(deviceID)
        return savedRules.filter { $0.deviceKey == key }
    }

    func upsertRule(
        deviceID: String,
        name: String,
        localPort: UInt16,
        targetAddr: String,
        targetPort: UInt16,
        enabled: Bool
    ) {
        let key = Self.normalizeDeviceKey(deviceID)
        guard !key.isEmpty else { return }
        if let idx = savedRules.firstIndex(where: { $0.deviceKey == key && $0.localPort == localPort }) {
            savedRules[idx].name = name
            savedRules[idx].targetAddr = targetAddr
            savedRules[idx].targetPort = targetPort
            savedRules[idx].enabled = enabled
        } else {
            savedRules.append(SavedRule(
                deviceKey: key,
                name: name,
                localPort: localPort,
                targetAddr: targetAddr,
                targetPort: targetPort,
                enabled: enabled
            ))
        }
        persist()
    }

    func updateEnabled(deviceID: String, localPort: UInt16, enabled: Bool) {
        let key = Self.normalizeDeviceKey(deviceID)
        guard let idx = savedRules.firstIndex(where: { $0.deviceKey == key && $0.localPort == localPort }) else { return }
        savedRules[idx].enabled = enabled
        persist()
    }

    func removeRule(deviceID: String, localPort: UInt16) {
        let key = Self.normalizeDeviceKey(deviceID)
        savedRules.removeAll { $0.deviceKey == key && $0.localPort == localPort }
        persist()
    }

    /// 会话握手成功后按目标设备自动恢复已持久化的本地端口转发规则。
    func restorePersistedRulesIfNeeded(sessionID: UInt64, deviceID: String?) {
        guard let deviceID else { return }
        let candidates = rules(for: deviceID)
        guard !candidates.isEmpty, !restoredSessionIDs.contains(sessionID) else { return }
        restoredSessionIDs.insert(sessionID)
        Task.detached(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(350))
            await MainActor.run {
                guard SessionService.shared.sessionID == sessionID,
                      SessionService.shared.isConnected,
                      SessionService.shared.toolPermissions.allowPortMap else { return }
                let existingPorts = Set(ToolService.shared.portmapRules.map(\.localPort))
                var restoredCount = 0
                for item in candidates where !existingPorts.contains(item.localPort) {
                    let err = ToolService.shared.portmapAdd(
                        sessionID: sessionID,
                        name: item.name,
                        localPort: item.localPort,
                        remoteHost: item.targetAddr,
                        remotePort: item.targetPort,
                        enabled: item.enabled,
                        persistDeviceID: nil
                    )
                    if err == nil { restoredCount += 1 }
                }
                if restoredCount > 0 {
                    ToolService.shared.portmapRefresh(sessionID: sessionID)
                    ToastCenter.shared.show("已自动恢复 \(restoredCount) 条端口映射规则")
                }
            }
        }
    }

    nonisolated static func normalizeDeviceKey(_ raw: String) -> String {
        raw.replacingOccurrences(of: " ", with: "").lowercased()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(savedRules) {
            defaults.set(data, forKey: storageKey)
        }
    }
}
