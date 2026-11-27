import Foundation
import RabbitControlCore
@_exported import RabbitControlSpec

/// rabbitcontrol-core 移动端 FFI 的 Swift 封装。
///
/// 边界约定与 `crates/rc-mobile-ffi` 一致:过程式 C API,结构化数据走 JSON;
/// Rust 侧返回的字符串必须经 `rc_string_free` 释放(由 `withRustString` 收口)。
enum CoreClient {

    // MARK: - 基础与构建信息

    /// 核心库构建与协议版本元数据(对应 core `CoreBuildInfo` camelCase JSON)。
    nonisolated struct BuildInfo: Codable, Equatable, Sendable {
        let coreVersion: String
        let gitCommit: String
        let buildTimestamp: String
        let sessionProtocolVersion: UInt32
        let punchVersion: UInt32
        let beaconVersion: UInt32
        let abiVersion: UInt32
    }

    /// 核心库语义版本号(如 `"0.2.2"`)。
    nonisolated static var coreVersion: String {
        withRustString(rc_core_version()) ?? "unknown"
    }

    /// 核心库完整构建与协议版本信息。
    nonisolated static var buildInfo: BuildInfo? {
        guard let json = withRustString(rc_core_build_info_json()),
              let data = json.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(BuildInfo.self, from: data)
    }

    // MARK: - 统一结构化错误目录解析

    /// 按 iOS 平台解析规范错误码或 wire alias，返回标准 `RCUiError`。
    nonisolated static func resolveUiError(code: String, detail: String? = nil) -> RCUiError {
        let trimmedDetail = detail?.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveDetail = (trimmedDetail?.isEmpty == false) ? trimmedDetail : nil
        let rawJSON: String? = code.withCString { codePtr in
            if let effectiveDetail {
                return effectiveDetail.withCString { detailPtr in
                    withRustString(rc_ui_error_resolve(codePtr, detailPtr))
                }
            } else {
                return withRustString(rc_ui_error_resolve(codePtr, nil))
            }
        }
        if let rawJSON,
           let data = rawJSON.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(RCUiError.self, from: data) {
            return decoded
        }
        let canonical = RCErrorCodes.resolveWireAlias(code) ?? RCErrorCodes.commonUnknown
        return RCUiError(
            code: canonical,
            title: "操作未完成",
            message: effectiveDetail ?? "发生未知错误，请稍后重试。",
            suggestion: "请检查网络连接或稍后重试。",
            severity: .error,
            presentation: .toast,
            action: .none,
            retryable: false,
            detail: effectiveDetail
        )
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
    nonisolated static func withRustString(_ ptr: UnsafeMutablePointer<CChar>?) -> String? {
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
