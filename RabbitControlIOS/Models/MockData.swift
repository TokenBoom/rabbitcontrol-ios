import Foundation

/// Mock 数据总表,逐字取自 `rabbitcontrol-core` 设计文档 §6.0;
/// 接入 `rabbitcontrol-core` 后删除,由真实数据替换。
enum MockData {
    static let devices: [Device] = [
        Device(id: "mac-mini", name: "Mac mini", kind: .mac, online: true, isLocal: false, wallpaper: .sunset),
        Device(id: "mbp-14", name: "MacBook Pro 14", kind: .mac, online: true, isLocal: false, wallpaper: .coast),
        Device(id: "gaming", name: "Gaming", kind: .windows, online: false, isLocal: false, wallpaper: .lake),
        Device(id: "mbp-16", name: "MacBook Pro 16", kind: .mac, online: false, isLocal: false, wallpaper: .coast),
    ]

    /// P2 本设备:ID=183 435 140(三位一组空格分隔);验证码=9ZGQ30ES。
    static let localDeviceID = "183 435 140"
    static let localVerifyCode = "9ZGQ30ES"
    static let verifyModes = ["仅使用临时验证码", "自定义验证码"]

    /// O3 账户:手机号=151******21。
    static let accountPhone = "151******21"
}
