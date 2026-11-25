import SwiftUI

/// 远程协助连接历史:最近连接、收藏与最后连接时间,UserDefaults 持久化。
@Observable final class TargetHistory {
    static let shared = TargetHistory()

    private(set) var recent: [String] = []
    private(set) var favorites: [String] = []
    private(set) var lastConnected: [String: TimeInterval] = [:]

    private init() {
        let d = UserDefaults.standard
        recent = d.stringArray(forKey: "assist.recent") ?? []
        favorites = d.stringArray(forKey: "assist.favorites") ?? []
        lastConnected = (d.dictionary(forKey: "assist.lastConnected") as? [String: TimeInterval]) ?? [:]
    }

    /// 连接成功后记录:写入最近连接(去重置顶,最多 12 条)与最后连接时间。
    func recordConnect(_ target: String) {
        let key = normalize(target)
        guard !key.isEmpty else { return }
        var list = recent.filter { $0 != key }
        list.insert(key, at: 0)
        recent = Array(list.prefix(12))
        lastConnected[key] = Date.now.timeIntervalSince1970
        persist()
    }

    func isFavorite(_ target: String) -> Bool {
        favorites.contains(normalize(target))
    }

    func toggleFavorite(_ target: String) {
        let key = normalize(target)
        if let idx = favorites.firstIndex(of: key) { favorites.remove(at: idx) }
        else { favorites.insert(key, at: 0) }
        persist()
    }

    func removeRecent(_ target: String) {
        recent.removeAll { $0 == target }
        persist()
    }

    /// 去掉空格统一格式,九位码与直连地址都按原样小写存储。
    func normalize(_ target: String) -> String {
        target.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func lastConnectedText(_ target: String) -> String? {
        guard let ts = lastConnected[target] else { return nil }
        let interval = Date.now.timeIntervalSince1970 - ts
        switch interval {
        case ..<3600: return "\(max(1, Int(interval / 60))) 分钟前"
        case ..<86400: return "\(Int(interval / 3600)) 小时前"
        default: return "\(Int(interval / 86400)) 天前"
        }
    }

    private func persist() {
        let d = UserDefaults.standard
        d.set(recent, forKey: "assist.recent")
        d.set(favorites, forKey: "assist.favorites")
        d.set(lastConnected, forKey: "assist.lastConnected")
    }
}
