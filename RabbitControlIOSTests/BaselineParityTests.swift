import CoreGraphics
import Foundation
import Testing
@testable import RabbitControlIOS

struct BaselineParityTests {

    @Test("AppLockStore 钥匙串哈希隔离、防爆破冷却、前后台超时锁定与门禁校验")
    @MainActor
    func appLockLifecycleAndCooldown() throws {
        let suiteName = "com.rabbitcontrol.test.applock.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let kcService = "com.rabbitcontrol.test.applock.kc.\(UUID().uuidString)"
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? SessionKeychain(service: kcService).remove()
        }

        let store = AppLockStore(defaults: defaults, keychainService: kcService)
        #expect(!store.isEnabled)
        try store.requireUnlocked()

        // 长度不足 4 位拒绝开启
        #expect(throws: RCUiErrorFailure.self) {
            try store.enable(newPassword: "123")
        }

        let secret = "Pin#8848"
        try store.enable(newPassword: secret)
        #expect(store.isEnabled)
        #expect(!store.isLocked)

        // 确认钥匙串只存摘要，绝不含明文
        let rawKC = try #require(try SessionKeychain(service: kcService).load())
        let rawText = String(decoding: rawKC, as: UTF8.self)
        #expect(!rawText.contains(secret))

        // 手动锁定后触发门禁阻断
        store.lockNow()
        #expect(store.isLocked)
        #expect(throws: RCUiErrorFailure.self) {
            try store.requireUnlocked()
        }

        // 连续输错 5 次触发防爆破冷却
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        for _ in 1...4 {
            if case .success = store.unlock(password: "wrong", now: t0) {
                Issue.record("错误口令不应解锁成功")
            }
        }
        let fifth = store.unlock(password: "wrong", now: t0)
        if case .failure(let err) = fifth {
            #expect(err.code == RCErrorCodes.networkRateLimited)
        } else {
            Issue.record("第 5 次错误应进入冷却")
        }

        // 冷却期内即使输入正确口令也拒绝
        if case .success = store.unlock(password: secret, now: t0.addingTimeInterval(1)) {
            Issue.record("冷却期内不应提前放行")
        }

        // 冷却结束后输入正确口令恢复解锁
        if case .failure(let err) = store.unlock(password: secret, now: t0.addingTimeInterval(10)) {
            Issue.record("冷却结束后正确口令应解锁成功: \(err)")
        }
        #expect(!store.isLocked)

        // 前后台超时自动上锁校验
        store.autoLockDelay = .oneMinute
        store.handleScenePhase(.background, now: t0)
        #expect(!store.isLocked)
        store.handleScenePhase(.active, now: t0.addingTimeInterval(30))
        #expect(!store.isLocked)

        store.handleScenePhase(.background, now: t0)
        store.handleScenePhase(.active, now: t0.addingTimeInterval(65))
        #expect(store.isLocked)
        _ = store.unlock(password: secret, now: t0.addingTimeInterval(66))
        #expect(!store.isLocked)

        // 修改口令与关闭应用锁
        try store.changePassword(current: secret, newPassword: "NewPin9901")
        store.lockNow()
        if case .failure = store.unlock(password: "NewPin9901") {
            Issue.record("新密码应可正常解锁")
        }
        try store.disable(current: "NewPin9901")
        #expect(!store.isEnabled)
    }

    @Test("P1/P3 设备过滤、稳定排序与离线清除 inSession 红线校验")
    @MainActor
    func deviceFilteringSortingAndReadOnlyParity() {
        let ownIos = AccountDevice(
            deviceID: "111222333",
            formattedID: "111 222 333",
            hostname: "My-iPhone",
            os: "ios",
            alias: "",
            allowRemoteAssist: false,
            allowRemoteControl: false,
            disabled: false,
            online: true,
            inSession: false
        )
        let androidControllerOnly = AccountDevice(
            deviceID: "222333444",
            formattedID: "222 333 444",
            hostname: "Pixel-9",
            os: "android",
            alias: "安卓手机",
            allowRemoteAssist: false,
            allowRemoteControl: false,
            disabled: false,
            online: true,
            inSession: false
        )
        let macOlder = AccountDevice(
            deviceID: "333444555",
            formattedID: "333 444 555",
            hostname: "Mac-Studio",
            os: "macos",
            alias: "旧活跃 Mac",
            allowRemoteAssist: false, // 关闭对外协助仍应允许同账号 P1 远控
            allowRemoteControl: true,
            disabled: false,
            online: true,
            inSession: true,
            lastSeenAt: "2026-11-27T10:00:00Z"
        )
        let macNewer = AccountDevice(
            deviceID: "444555666",
            formattedID: "444 555 666",
            hostname: "MacBook-Pro",
            os: "macos",
            alias: "新活跃 Mac",
            allowRemoteAssist: true,
            allowRemoteControl: true,
            disabled: false,
            online: true,
            inSession: false,
            lastSeenAt: "2026-11-27T12:00:00Z"
        )
        let winOfflineStaleSession = AccountDevice(
            deviceID: "555666777",
            formattedID: "555 666 777",
            hostname: "Win-PC",
            os: "windows",
            alias: "离线主机",
            allowRemoteAssist: true,
            allowRemoteControl: true,
            disabled: false,
            online: false,
            inSession: true, // 离线时应自动清除 inSession 占位
            wolCapable: true,
            lastSeenAt: "2026-11-27T13:00:00Z"
        )

        #expect(!winOfflineStaleSession.effectiveInSession)
        #expect(macOlder.effectiveInSession)

        let rawList = [winOfflineStaleSession, ownIos, macOlder, androidControllerOnly, macNewer]
        let p1List = DeviceListView.controllableDevices(
            accountDevices: rawList,
            peers: [],
            ownDeviceID: "111222333"
        )
        // P1 仅保留 allowRemoteControl == true 的 3 台桌面端，且按 online 置顶 + last_seen_at DESC 排列
        #expect(p1List.map(\.id) == ["444555666", "333444555", "555666777"])
        #expect(p1List.last?.inSession == false)

        // P3 保留全量 5 台设备，且正确标记本机与未开启远控设备
        let p3List = DeviceListView.allDevices(
            accountDevices: rawList,
            peers: [],
            ownDeviceID: "111222333"
        )
        #expect(p3List.count == 5)
        let iosCard = p3List.first { $0.id == "111222333" }
        let androidCard = p3List.first { $0.id == "222333444" }
        #expect(iosCard?.isSelfDevice == true)
        #expect(iosCard?.allowRemoteControl == false)
        #expect(androidCard?.isSelfDevice == false)
        #expect(androidCard?.allowRemoteControl == false)
    }

    @Test("出站代理与 ConnectionMode.p2pOnly 冲突校验返回 proxy.config_conflict")
    @MainActor
    func proxyAndConnectionModeConflictCheck() throws {
        defer {
            _ = ProxyConfigStore.applyToCoreSync(ProxyConfigStore.Config(mode: .none))
        }
        // 直连无代理时允许 p2pOnly
        try RuntimeService.validateProxyAndConnectionMode(.p2pOnly)

        // 启用手动代理时，选择 p2pOnly 应明确抛出 proxy.config_conflict
        let suiteName = "com.rabbitcontrol.test.modeproxy.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var target = AuthService.ServerTarget(
            host: "rc.example.com",
            useHTTPS: true,
            caFingerprintSha256: "AA:BB:CC",
            apiPort: 21118,
            signalPort: 31116,
            relayPort: 31117
        )
        #expect(target.runtimePayload["signal_port"] as? UInt16 == 31116)
        #expect(target.runtimePayload["relay_port"] as? UInt16 == 31117)
        #expect(target.runtimePayload["ca_fingerprint_sha256"] as? String == "AA:BB:CC")
        target.signalPort = nil
        #expect(target.effectiveSignalPort == 21116)
    }

    @Test("PortMapStore 按设备持久化、更新启停与删除")
    @MainActor
    func portMapPersistenceRoundtrip() throws {
        let suiteName = "com.rabbitcontrol.test.portmap.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = PortMapStore(defaults: defaults)
        store.upsertRule(
            deviceID: "604 928 235",
            name: "Postgres",
            localPort: 15432,
            targetAddr: "127.0.0.1",
            targetPort: 5432,
            enabled: true
        )
        #expect(store.rules(for: "604928235").count == 1)

        store.updateEnabled(deviceID: "604928235", localPort: 15432, enabled: false)
        let reloaded = PortMapStore(defaults: defaults)
        #expect(reloaded.rules(for: "604 928 235").first?.enabled == false)

        reloaded.removeRule(deviceID: "604928235", localPort: 15432)
        #expect(reloaded.rules(for: "604928235").isEmpty)
    }

    @Test("VT100/ANSI 终端屏幕缓冲器支持色彩、回车覆写、清屏、OSC 标题与备用屏幕恢复")
    func terminalEmulatorAnsiAndAltScreen() {
        var screen = TerminalScreenBuffer(cols: 40, rows: 10)
        // OSC 标题 + 回车覆写进度条 + ANSI 绿字
        screen.feed("\u{1B}]0;build@mac-studio\u{07}")
        #expect(screen.oscTitle == "build@mac-studio")

        screen.feed("Downloading 10%\rDownloading 100%\n\u{1B}[32mDONE\u{1B}[0m")
        let renderedPrimary = String(screen.renderAttributedString().characters)
        #expect(!renderedPrimary.contains("10%"))
        #expect(renderedPrimary.contains("Downloading 100%"))
        #expect(renderedPrimary.contains("DONE"))

        // 进入备用屏（如 vim / htop）写入内容后退出，主屏历史应完好保留
        screen.feed("\u{1B}[?1049h\u{1B}[2J\u{1B}[1;1H--- VIM BUFFER ---")
        #expect(screen.usingAltScreen)
        let altText = String(screen.renderAttributedString().characters)
        #expect(altText.contains("VIM BUFFER"))
        #expect(!altText.contains("Downloading 100%"))

        screen.feed("\u{1B}[?1049l")
        #expect(!screen.usingAltScreen)
        let restoredText = String(screen.renderAttributedString().characters)
        #expect(restoredText.contains("Downloading 100%"))
        #expect(restoredText.contains("DONE"))
    }

    @Test("终端系统锁屏状态解析与设备系统密码钥匙串存取清理")
    @MainActor
    func terminalLockStateAndKeychainStore() {
        let lock = SessionService.TerminalLockState.decode(from: [
            "required": true,
            "unlocked": false,
            "username": "veildawn",
            "retry_after_secs": 5,
        ])
        #expect(lock.required)
        #expect(!lock.unlocked)
        #expect(lock.username == "veildawn")
        #expect(lock.retryAfterSecs == 5)

        let unlockRes = SessionService.TerminalUnlockResult.decode(from: [
            "ok": false,
            "error": "系统密码不正确",
            "retryAfterSecs": 3,
        ])
        #expect(!unlockRes.ok)
        #expect(unlockRes.error == "系统密码不正确")
        #expect(unlockRes.retryAfterSecs == 3)

        let devID = "testdev-\(UUID().uuidString)"
        defer { TerminalUnlockKeychainStore.clearPassword(for: devID) }
        #expect(TerminalUnlockKeychainStore.loadPassword(for: devID) == nil)
        TerminalUnlockKeychainStore.savePassword("MacSysPass!1", for: devID)
        #expect(TerminalUnlockKeychainStore.loadPassword(for: devID) == "MacSysPass!1")
        TerminalUnlockKeychainStore.clearPassword(for: devID)
        #expect(TerminalUnlockKeychainStore.loadPassword(for: devID) == nil)
    }
}
