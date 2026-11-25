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

extension Device.Kind {
    /// 由服务端 os 字段推断设备类型。
    init(osString: String) {
        switch osString.lowercased() {
        case "macos", "mac": self = .mac
        case "windows", "win": self = .windows
        case "ios", "ipados": self = .tablet
        case "android": self = .phone
        default: self = .mac
        }
    }
}

extension Device.Wallpaper {
    /// 由设备 ID 稳定选择壁纸(占位视觉,后续由真实截图替换)。
    init(hashSeed: String) {
        let all: [Device.Wallpaper] = [.sunset, .coast, .lake]
        self = all[abs(hashSeed.hashValue) % all.count]
    }
}
