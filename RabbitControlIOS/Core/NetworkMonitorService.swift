import Foundation
import Network

/// 系统网络路由/网卡变更监听器（对齐 macOS 基线 §4.3 `network_monitor`）。
///
/// 当前台发生 Wi-Fi ↔ 蜂窝切网、热点切换或网卡恢复时：
/// 1. 清空旧局域网节点快照并重启 LAN 多播发现；
/// 2. 刷新本机活跃局域网 IPv4 并触发信令即时重连；
/// 3. 对在途远控会话发送 `probe_now` 快速活性探针（或加速等待中的自动重连）。
@Observable
final class NetworkMonitorService {
    static let shared = NetworkMonitorService()

    private(set) var isConnected = true
    private(set) var interfaceKind = "unknown"
    /// 每次确认切网后递增，供 `SessionView` / `StandaloneToolSessionView` 唤醒重连退避。
    private(set) var networkEpoch: Int = 0

    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "com.rabbitcontrol.network.monitor", qos: .utility)
    private var started = false
    private var lastSignature: String?
    private var debounceTask: Task<Void, Never>?

    private init() {}

    func start() {
        guard !started, !AuthService.uiTestingMock else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            let kind: String
            if path.usesInterfaceType(.wifi) {
                kind = "wifi"
            } else if path.usesInterfaceType(.wiredEthernet) {
                kind = "wired"
            } else if path.usesInterfaceType(.cellular) {
                kind = "cellular"
            } else if satisfied {
                kind = "other"
            } else {
                kind = "none"
            }
            let lanIPs = RuntimeService.localLANIPv4Addresses().sorted().joined(separator: ",")
            let sig = "\(satisfied)|\(kind)|\(lanIPs)"
            Task { @MainActor [weak self] in
                self?.handlePathUpdate(satisfied: satisfied, kind: kind, signature: sig)
            }
        }
        monitor.start(queue: monitorQueue)
    }

    private func handlePathUpdate(satisfied: Bool, kind: String, signature: String) {
        isConnected = satisfied
        interfaceKind = kind
        guard let previous = lastSignature else {
            lastSignature = signature
            return
        }
        guard previous != signature else { return }
        lastSignature = signature

        debounceTask?.cancel()
        debounceTask = Task { @MainActor [weak self] in
            // 留出 600ms 等待 DHCP / 路由表稳定后再重绑信令与探测链路
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, let self else { return }
            self.networkEpoch += 1
            LANDiscoveryService.shared.restartForNetworkChange(hasLAN: kind == "wifi" || kind == "wired")
            if satisfied {
                RuntimeService.shared.handleNetworkChange()
                SessionService.shared.probeNow()
                await AuthService.shared.refreshDevices()
            }
        }
    }
}
