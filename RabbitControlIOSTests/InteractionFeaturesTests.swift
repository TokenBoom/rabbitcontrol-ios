import Foundation
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

    @Test("视频编码默认优先 H.265 且支持持久化切换")
    func preferredCodecDefaultsToHevcAndPersists() {
        #expect(VideoCodec.parse("hevc") == .hevc)
        #expect(VideoCodec.parse(" H265 ") == .hevc)
        #expect(VideoCodec.parse("h.265") == .hevc)
        #expect(VideoCodec.parse("h264") == .h264)
        #expect(VideoCodec.parse("AVC") == .h264)
        #expect(VideoCodec.parse("vp9") == nil)
        #expect(VideoCodec.parse(nil) == nil)

        let prefs = PrefsStore.shared
        let savedRaw = UserDefaults.standard.string(forKey: "prefs.preferredCodec")
        let original = prefs.preferredCodec
        defer {
            if let savedRaw, let restored = VideoCodec.parse(savedRaw) {
                prefs.preferredCodec = restored
            } else {
                prefs.preferredCodec = original
                UserDefaults.standard.removeObject(forKey: "prefs.preferredCodec")
            }
        }

        if savedRaw == nil {
            #expect(prefs.preferredCodec == .hevc)
        }
        prefs.preferredCodec = .h264
        #expect(UserDefaults.standard.string(forKey: "prefs.preferredCodec") == "h264")
        prefs.preferredCodec = .hevc
        #expect(UserDefaults.standard.string(forKey: "prefs.preferredCodec") == "hevc")
    }

    @Test("DisplayConfig 解析编码能力并兼容省略字段")
    func displayConfigDecodesCodecCapabilities() throws {
        let fullPayload: [String: Any] = [
            "width": 2560,
            "height": 1440,
            "fps": 60,
            "max_fps": 120,
            "presets": [
                ["width": 2560, "height": 1440, "label": "2560 × 1440 (HiDPI)", "is_native": true, "is_hidpi": true],
            ],
            "codec": "hevc",
            "supported_codecs": ["h264", "hevc"],
            "client_supports_hevc": true,
            "advisory": [
                "level": "optimal",
                "can_enable_hevc": false,
            ],
        ]
        let decoded = try #require(SessionService.DisplayConfig.decode(from: fullPayload))
        #expect(decoded.codec == .hevc)
        #expect(decoded.canUseHevc)
        #expect(decoded.supportedCodecs == [.h264, .hevc])
        #expect(decoded.presets.first?.isHidpi == true)
        #expect(decoded.updating(fps: 90).codec == .hevc)

        // 核心库在 supported_codecs 为空或 codec 为 None 时会省略对应键
        let minimalPayload: [String: Any] = [
            "width": 1920,
            "height": 1080,
            "fps": 30,
            "max_fps": 60,
            "presets": [],
            "client_supports_hevc": true,
        ]
        let minimal = try #require(SessionService.DisplayConfig.decode(from: minimalPayload))
        #expect(minimal.codec == nil)
        #expect(!minimal.canUseHevc)
        #expect(minimal.supportedCodecs == [.h264])
    }

    @Test("H.265 优先对账逻辑：窗口期内等待核心库自动切换，超时仍为 H.264 则补发一次")
    func codecReconciliationPrioritizesHevcSafely() {
        let hevcCapableH264 = SessionService.DisplayConfig(
            width: 1920, height: 1080, fps: 60, maxFps: 60, presets: [],
            codec: .h264, supportedCodecs: [.h264, .hevc], clientSupportsHevc: true
        )
        // 握手后 1s 内等待底层自动 SetCodec("hevc") 完成，不重复下发
        #expect(SessionService.evaluateCodecReconciliation(
            display: hevcCapableH264, preferred: .hevc, userSelected: nil,
            didAutoAlign: false, negotiatedElapsed: 0.3
        ) == .none)

        // 超过 1s 仍停留在 H.264（如首帧重配竞态跳过），自动补发一次 .hevc
        #expect(SessionService.evaluateCodecReconciliation(
            display: hevcCapableH264, preferred: .hevc, userSelected: nil,
            didAutoAlign: false, negotiatedElapsed: 1.2
        ) == .send(.hevc))

        // 已处于 H.265 时直接标记对齐完成
        let alreadyHevc = hevcCapableH264.updating(codec: .hevc)
        #expect(SessionService.evaluateCodecReconciliation(
            display: alreadyHevc, preferred: .hevc, userSelected: nil,
            didAutoAlign: false, negotiatedElapsed: 0.2
        ) == .markAligned)

        // 被控端不支持 H.265 时回退保持 H.264，不尝试发送 .hevc
        let h264Only = SessionService.DisplayConfig(
            width: 1920, height: 1080, fps: 30, maxFps: 60, presets: [],
            codec: .h264, supportedCodecs: [.h264], clientSupportsHevc: true
        )
        #expect(SessionService.evaluateCodecReconciliation(
            display: h264Only, preferred: .hevc, userSelected: nil,
            didAutoAlign: false, negotiatedElapsed: 2.0
        ) == .markAligned)

        // 用户偏好 H.264 兼容但远端切到了 H.265 时，切回 H.264
        #expect(SessionService.evaluateCodecReconciliation(
            display: alreadyHevc, preferred: .h264, userSelected: nil,
            didAutoAlign: false, negotiatedElapsed: 0.2
        ) == .send(.h264))

        // 已对齐后不再重复触发
        #expect(SessionService.evaluateCodecReconciliation(
            display: hevcCapableH264, preferred: .hevc, userSelected: nil,
            didAutoAlign: true, negotiatedElapsed: 3.0
        ) == .none)
    }

    @Test("局域网网卡过滤仅保留活跃 Wi-Fi / 有线 IPv4，排除回环、链路本地与隧道网卡")
    func lanInterfaceFilteringExcludesCellularLoopbackAndTunnels() {
        #expect(RuntimeService.isEligibleLANInterface(name: "en0", ipv4: "192.168.1.24"))
        #expect(RuntimeService.isEligibleLANInterface(name: "bridge100", ipv4: "172.20.10.1"))
        #expect(!RuntimeService.isEligibleLANInterface(name: "pdp_ip0", ipv4: "10.12.34.56"))
        #expect(!RuntimeService.isEligibleLANInterface(name: "utun3", ipv4: "10.8.0.2"))
        #expect(!RuntimeService.isEligibleLANInterface(name: "lo0", ipv4: "127.0.0.1"))
        #expect(!RuntimeService.isEligibleLANInterface(name: "en0", ipv4: "169.254.20.9"))
        #expect(!RuntimeService.isEligibleLANInterface(name: "en0", ipv4: "0.0.0.0"))
    }

    @Test("SessionUpdate 扩展状态解析：多显示器、防窥、远端静音、版本与壁纸 DataURL")
    func sessionExtendedStateDecoding() throws {
        let displaysPayload: [String: Any] = [
            "active_display_id": 2,
            "displays": [
                ["id": 1, "name": "Built-in Retina", "width": 2560, "height": 1600, "is_main": true, "is_virtual": false],
                ["id": 2, "name": "Virtual Display", "width": 1920, "height": 1080, "is_main": false, "is_virtual": true],
            ],
        ]
        let displays = try #require(SessionService.DisplaysState.decode(from: displaysPayload))
        #expect(displays.displays.count == 2)
        #expect(displays.activeDisplay?.id == "2")
        #expect(displays.activeDisplay?.isVirtual == true)

        let privacy = SessionService.PrivacyState.decode(from: ["supported": true, "enabled": true, "mode": "black"])
        #expect(privacy.supported && privacy.enabled)

        let mute = SessionService.HostMuteState.decode(from: ["supported": true, "muted": false])
        #expect(mute.supported && !mute.muted)

        let host = try #require(SessionService.RemoteHostInfo.decode(from: [
            "version": "0.1.18", "os": "macos", "arch": "aarch64",
            "updateCapable": true, "isOwnerSession": true, "serviceInstalled": false,
        ]))
        #expect(host.version == "0.1.18")
        #expect(host.updateCapable)

        let tinyPNG = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        #expect(SessionService.decodeDataURLImage(tinyPNG) != nil)
        #expect(SessionService.decodeDataURLImage("https://example.com/a.png") == nil)
        #expect(SessionHUD.formatFrameTime(4.26) == "帧 4.3 ms")
        #expect(SessionHUD.formatFrameTime(12.4) == "帧 12 ms")
        #expect(SessionHUD.formatFrameTime(nil) == nil)
    }

    @Test("ToolService 解析端口映射流量、文件时间/传输方向，并按视口计算终端网格")
    func toolServiceDecodesV0118TelemetryAndGrid() throws {
        let smallGrid = ToolService.calculateTerminalGrid(viewportSize: .zero)
        #expect(smallGrid.cols == 80 && smallGrid.rows == 24)

        let phoneGrid = ToolService.calculateTerminalGrid(viewportSize: CGSize(width: 390, height: 420))
        #expect(phoneGrid.cols >= 40 && phoneGrid.cols < 80)
        #expect(phoneGrid.rows >= 12)

        let padGrid = ToolService.calculateTerminalGrid(viewportSize: CGSize(width: 1180, height: 760))
        #expect(padGrid.cols > 120 && padGrid.rows > 35)

        let rules = ToolService.decodePortmapRules([[
            "id": 7,
            "name": "Web Dev",
            "localPort": 3000,
            "targetAddr": "127.0.0.1",
            "targetPort": 5173,
            "enabled": true,
            "status": "listening",
            "activeConns": 3,
            "bytesTx": 4096,
            "bytesRx": 65536,
        ]])
        let rule = try #require(rules.first)
        #expect(rule.statusLabel == "监听中")
        #expect(rule.activeConns == 3)
        #expect(rule.bytesTx == 4096 && rule.bytesRx == 65536)

        let entry = try #require(ToolService.decodeRemoteFileEntry([
            "name": "report.pdf", "isDir": false, "size": 2048, "modifiedSec": 1_735_000_000,
        ]))
        #expect(entry.modifiedSec == 1_735_000_000)

        let transfer = try #require(ToolService.decodeTransferItem([
            "id": 42, "name": "archive.zip", "direction": "upload",
            "status": "done", "totalBytes": 1024, "doneBytes": 1024, "toPath": "/tmp/archive.zip",
        ]))
        #expect(transfer.isUpload)
        #expect(transfer.isTerminal)
        #expect(transfer.toPath == "/tmp/archive.zip")
    }
}
