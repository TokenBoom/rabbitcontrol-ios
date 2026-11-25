import Foundation
import UIKit

/// 局域网发现服务:App 启动后开启监听,周期轮询 core 的节点快照并发布给 UI。
///
/// 移动端作为主控端只监听不广播(`rc-client-core` 默认行为);
/// 轮询间隔 2s,与信标广播周期(1s)和 TTL 匹配,发现延迟可接受且几乎零功耗。
@Observable
final class LANDiscoveryService {
    static let shared = LANDiscoveryService()

    private(set) var peers: [LANPeer] = []
    private var pollingTask: Task<Void, Never>?

    /// 本机随机实例 ID(过滤自身回环包),持久化保证同一安装内稳定。
    private var instanceID: UInt64 {
        let key = "lan.instanceID"
        if let saved = UserDefaults.standard.object(forKey: key) as? UInt64 {
            return saved
        }
        let generated = UInt64.random(in: 1...UInt64.max)
        UserDefaults.standard.set(generated, forKey: key)
        return generated
    }

    private init() {}

    func start() {
        guard pollingTask == nil else { return }
        CoreClient.startLANDiscovery(instanceID: instanceID, deviceName: UIDevice.current.name)
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                let snapshot = await Task.detached(priority: .utility) {
                    CoreClient.lanPeers()
                }.value
                guard let self, !Task.isCancelled else { return }
                if snapshot != peers {
                    peers = snapshot
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
        CoreClient.stopLANDiscovery()
    }
}
