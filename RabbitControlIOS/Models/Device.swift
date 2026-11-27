import Foundation

/// 设备列表和会话共用的展示模型。
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

    var displayID: String {
        let digits = id.filter { !$0.isWhitespace }
        guard digits.count == 9, digits.allSatisfy(\.isNumber) else { return id }
        return "\(digits.prefix(3)) \(digits.dropFirst(3).prefix(3)) \(digits.suffix(3))"
    }

    func matches(search: String) -> Bool {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || name.localizedCaseInsensitiveContains(query) ||
            id.filter { !$0.isWhitespace }.localizedCaseInsensitiveContains(query.filter { !$0.isWhitespace })
    }

    let id: String
    let name: String
    let kind: Kind
    let online: Bool
    let isLocal: Bool
    let wallpaper: Wallpaper
    var allowRemoteControl: Bool = true
    var allowRemoteAssist: Bool = true
    var inSession: Bool = false
    var isSelfDevice: Bool = false
    var appVersion: String = ""
}

extension Device.Kind {
    var icon: RabbitIcon.Name {
        switch self {
        case .mac: .computer
        case .windows: .desktopPC
        case .phone: .phone
        case .tablet: .tablet
        }
    }

    /// 由服务端 os 字段推断设备类型。
    init(osString: String) {
        switch osString.lowercased() {
        case "macos", "mac": self = .mac
        case "windows", "win": self = .windows
        case "ipados", "tablet": self = .tablet
        case "ios", "android", "phone": self = .phone
        default: self = .mac
        }
    }
}

extension Device.Wallpaper {
    /// 设备列表占位壁纸。
    init(hashSeed: String) {
        let all: [Device.Wallpaper] = [.sunset, .coast, .lake]
        self = all[Int(hashSeed.hashValue.magnitude % UInt(all.count))]
    }
}

extension AccountDevice {
    func card(nearbyIDs: Set<String>, ownDeviceID: String? = nil) -> Device {
        let compactSelf = deviceID.replacingOccurrences(of: " ", with: "")
        let compactOwn = ownDeviceID?.replacingOccurrences(of: " ", with: "")
        let selfFlag = os.lowercased() == "ios" || (compactOwn != nil && !compactOwn!.isEmpty && compactSelf == compactOwn)
        return Device(
            id: deviceID,
            name: displayName,
            kind: Device.Kind(osString: os),
            online: online,
            isLocal: nearbyIDs.contains(compactSelf) || nearbyIDs.contains(formattedID.replacingOccurrences(of: " ", with: "")),
            wallpaper: Device.Wallpaper(hashSeed: deviceID),
            allowRemoteControl: allowRemoteControl && !selfFlag,
            allowRemoteAssist: allowRemoteAssist,
            inSession: effectiveInSession,
            isSelfDevice: selfFlag,
            appVersion: appVersion
        )
    }
}
