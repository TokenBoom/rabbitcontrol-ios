import Foundation
import RabbitControlCore

/// rabbitcontrol-core 移动端 FFI 的 Swift 封装。
///
/// 边界约定与 `crates/rc-mobile-ffi` 一致:过程式 C API,结构化数据走 JSON;
/// Rust 侧返回的字符串必须经 `rc_string_free` 释放(由 `withRustString` 收口)。
enum CoreClient {

    // MARK: - 基础

    /// 核心库版本号。
    nonisolated static var coreVersion: String {
        withRustString(rc_core_version()) ?? "unknown"
    }

    // MARK: - 局域网发现

    /// 启动局域网发现(幂等)。`instanceID` 为本机随机实例 ID,用于过滤自身回环包。
    @discardableResult
    nonisolated static func startLANDiscovery(instanceID: UInt64, deviceName: String) -> Bool {
        deviceName.withCString { ptr in
            rc_lan_discovery_start(instanceID, ptr) == 1
        }
    }

    nonisolated static func stopLANDiscovery() {
        rc_lan_discovery_stop()
    }

    /// 当前在线局域网节点快照。
    nonisolated static func lanPeers() -> [LANPeer] {
        guard let json = withRustString(rc_lan_peers_json()),
              let data = json.data(using: .utf8) else {
            return []
        }
        return (try? JSONDecoder().decode([LANPeer].self, from: data)) ?? []
    }

    // MARK: - 内部

    /// 接管 Rust 侧分配的字符串:转 Swift String 后保证释放。
    nonisolated private static func withRustString(_ ptr: UnsafeMutablePointer<CChar>?) -> String? {
        guard let ptr else { return nil }
        defer { rc_string_free(ptr) }
        return String(cString: ptr)
    }
}

/// 局域网在线被控端节点,字段与 core `LanPeer` 一致。
struct LANPeer: Codable, Identifiable, Hashable {
    let instanceID: UInt64
    let name: String
    let addr: String
    let requiresPassword: Bool
    let deviceID: String?

    var id: UInt64 { instanceID }

    enum CodingKeys: String, CodingKey {
        case instanceID = "instance_id"
        case name
        case addr
        case requiresPassword = "requires_password"
        case deviceID = "device_id"
    }
}
