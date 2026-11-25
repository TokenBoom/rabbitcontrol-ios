import Foundation

/// 受控设备。字段与 `rabbitcontrol-core` 设计文档 §6.0 Mock 数据总表对齐;
/// 接入 `rc-client-core` 后由真实设备发现数据替换。
struct Device: Identifiable, Hashable {
    enum Kind: String, Hashable {
        case mac
        case windows
        case phone
        case tablet
    }

    enum Wallpaper: String, Hashable {
        case sunset
        case coast
        case lake
    }

    let id: String
    let name: String
    let kind: Kind
    let online: Bool
    let isLocal: Bool
    let wallpaper: Wallpaper
}
