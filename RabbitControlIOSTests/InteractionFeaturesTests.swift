import Testing
import UIKit
@testable import RabbitControlIOS

struct InteractionFeaturesTests {
    @Test("最近连接去重置顶并记录时间，收藏可切换")
    func targetHistoryRecordsAndFavorites() {
        let history = TargetHistory.shared
        let a = "1\(Int.random(in: 10_000_000...99_999_999))"
        let b = "127.0.0.1:\(Int.random(in: 20_000...60_000))"
        history.recordConnect(a)
        history.recordConnect(b)
        history.recordConnect(a)
        #expect(history.recent.first == a)
        #expect(history.recent.filter { $0 == a }.count == 1)
        #expect(history.lastConnectedText(a) != nil)
        #expect(!history.isFavorite(b))
        history.toggleFavorite(b)
        #expect(history.isFavorite(b))
        history.toggleFavorite(b)
        #expect(!history.isFavorite(b))
        history.removeRecent(a)
        history.removeRecent(b)
        #expect(!history.recent.contains(a))
    }

    @Test("九位码按 3-3-3 分组显示")
    func assistDisplayGroupsDigits() {
        #expect(AssistView.display("604928235") == "604 928 235")
        #expect(AssistView.display("10.0.0.2:9901") == "10.0.0.2:9901")
    }

    @Test("交互偏好持久化")
    func interactionPrefsPersist() {
        let prefs = InteractionPrefs.shared
        let old = prefs.touchMode
        prefs.touchMode = old == .trackpad ? .directTouch : .trackpad
        #expect(UserDefaults.standard.string(forKey: "rc.touchMode") == prefs.touchMode.rawValue)
        prefs.touchMode = old
    }
}
