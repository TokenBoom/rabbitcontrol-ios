import XCTest
import RabbitControlCore
@testable import RabbitControlIOS

nonisolated final class SessionFeaturesTests: XCTestCase {
    @MainActor func testKeychainLifecycle() throws {
        let keychain = SessionKeychain(service: "com.rabbitcontrol.test.\(UUID().uuidString)")
        defer { try? keychain.remove() }
        XCTAssertNil(try keychain.load())
        try keychain.store(Data([1]))
        try keychain.store(Data([2]))
        XCTAssertEqual(try keychain.load(), Data([2]))
        try keychain.remove()
        XCTAssertNil(try keychain.load())
    }

    @MainActor func testPhysicalKeys() {
        XCTAssertEqual(RemoteKeys.strokes(for: "A~|")?.map(\.key), [0x1e, 0x29, 0x2b])
        XCTAssertEqual(RemoteKeys.strokes(for: "aA")?.map(\.shift), [false, true])
        XCTAssertNil(RemoteKeys.strokes(for: "中"))
    }

    @MainActor func testDeviceSearchAcceptsCopiedID() {
        let device = Device(id: "123456789", name: "Office Mac", kind: .mac, online: true, isLocal: false, wallpaper: .coast)
        XCTAssertEqual(device.displayID, "123 456 789")
        XCTAssertTrue(device.matches(search: " 123 456 789\n"))
        XCTAssertTrue(device.matches(search: "office"))
        XCTAssertFalse(device.matches(search: "987"))
    }
}

#if targetEnvironment(simulator)
// Opt in only on an isolated simulator with a disposable loopback server and Mac host.
nonisolated final class LoopbackAcceptanceTests: XCTestCase {
    struct Fixture: Decodable {
        let endpoint, password, directory: String
        let email, accountPassword, device: String
        let localPort, httpPort: UInt16
    }

    private func fixture() throws -> Fixture {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("rabbit-loopback-test.json")
        guard FileManager.default.fileExists(atPath: file.path) else { throw XCTSkip("未配置本地验收环境") }
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: file))
        guard fixture.endpoint.hasPrefix("127.0.0.1:"), !fixture.password.isEmpty else { throw XCTSkip("仅允许本机临时宿主") }
        return fixture
    }

    @MainActor private func waitFor(_ label: String, _ predicate: () -> Bool) async throws {
        let until = ContinuousClock.now + .seconds(15)
        while !predicate() {
            guard ContinuousClock.now < until else {
                throw NSError(domain: "LoopbackAcceptance", code: 1, userInfo: [NSLocalizedDescriptionKey: "验收超时：\(label)"])
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    @MainActor func testMacFilesTerminalAndWatching() async throws {
        let f = try fixture(), s = SessionService.shared, tools = ToolService.shared
        defer { tools.stop(); s.close() }
        s.open(connectAddr: f.endpoint, password: "incorrect", watchOnly: false)
        try await waitFor("拒绝错误密码") { if case .ended = s.state { true } else { false } }
        s.open(connectAddr: f.endpoint, password: f.password, watchOnly: false)
        try await waitFor("密码重试") { s.isConnected }
        let id = try XCTUnwrap(s.sessionID)
        tools.start(sessionID: id)
        try await waitFor("显示能力") { s.display != nil }
        s.setStream(fps: 15)
        try await waitFor("Mac 确认帧率") { s.display?.fps == 15 }
        s.setBitrate(2_000_000)
        s.setClipboardEnabled(true)
        try await waitFor("剪贴板就绪") { s.sendClipboard("ios-clip-test") }
        try await waitFor("独立测试剪贴板往返") { s.receivedText == "mac-clip-回传" }
        s.setClipboardEnabled(false)
        XCTAssertNil(s.receivedText)
        try await checkTools(f, id: id)
        let checksURL = try XCTUnwrap(URL(string: "http://127.0.0.1:\(f.httpPort)/checks"))
        let (before, _) = try await URLSession.shared.data(from: checksURL)
        // Never send a lock command to a normal desktop while running this test.
        guard String(decoding: before, as: UTF8.self) == "fixture-checks:0" else {
            throw NSError(domain: "需要未使用的隔离键鼠/锁屏测试宿主", code: 1)
        }
        s.sendMouseButton(button: "right", pressed: true)
        s.sendWheel(delta: 3)
        s.sendKey(scancode: 0x1e, pressed: true)
        s.releasePressedInput()
        s.lockRemoteScreen()
        let until = ContinuousClock.now + .seconds(5)
        while true {
            let (checks, _) = try await URLSession.shared.data(from: checksURL)
            if String(decoding: checks, as: UTF8.self) == "fixture-checks:63" { break }
            guard ContinuousClock.now < until else { XCTFail("Mac 未收到预期的键鼠、释放与锁屏命令"); return }
            try await Task.sleep(for: .milliseconds(100))
        }
        tools.stop()
        s.close()
        s.open(connectAddr: f.endpoint, password: f.password, watchOnly: true)
        try await waitFor("重新连接并仅查看") { s.isConnected && s.peerWatchOnly }
        s.setClipboardEnabled(true)
        XCTAssertFalse(s.clipboardEnabled)
        if let viewID = s.sessionID {
            XCTAssertNotNil(tools.portmapAdd(sessionID: viewID, name: "只读", localPort: f.localPort, remoteHost: "127.0.0.1", remotePort: f.httpPort))
        }
    }

    @MainActor private func checkTools(_ f: Fixture, id: UInt64) async throws {
        let tools = ToolService.shared
        tools.fileList(sessionID: id, path: f.directory)
        try await waitFor("目录响应") { !tools.listing }
        XCTAssertNil(tools.fileError)
        XCTAssertTrue(tools.fileEntries.contains { $0.name == "fixture.txt" })
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("roundtrip-\(UUID()).txt")
        let bytes = Data(UUID().uuidString.utf8)
        try bytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let uploadResult = await tools.fileUpload(sessionID: id, localPath: url.path, remoteDir: f.directory)
        let upload = try XCTUnwrap(uploadResult)
        try await waitFor("上传写盘") { tools.transfers.contains { $0.id == upload && $0.status == "done" } }
        let path = (f.directory as NSString).appendingPathComponent(url.lastPathComponent)
        let downloadResult = await tools.fileDownload(sessionID: id, remotePath: path)
        let download = try XCTUnwrap(downloadResult)
        try await waitFor("下载写盘") { tools.transfers.contains { $0.id == download && $0.status == "done" } }
        let saved = URL.documentsDirectory.appendingPathComponent(url.lastPathComponent)
        defer { try? FileManager.default.removeItem(at: saved) }
        XCTAssertEqual(try Data(contentsOf: saved), bytes)
        tools.terminalOpen(sessionID: id)
        XCTAssertTrue(tools.terminalInput(sessionID: id, text: "printf 'rabbit-%s\\n' terminal-ok\r"))
        try await waitFor("终端返回") { tools.terminalOutput.contains("rabbit-terminal-ok") }
        tools.terminalClose(sessionID: id)
        let error = tools.portmapAdd(sessionID: id, name: "验收", localPort: f.localPort, remoteHost: "127.0.0.1", remotePort: f.httpPort)
        XCTAssertNil(error)
        try await waitFor("端口映射监听") { tools.portmapRules.contains { $0.enabled && $0.localPort == f.localPort } }
        let mapping = try XCTUnwrap(tools.portmapRules.first { $0.localPort == f.localPort })
        XCTAssertNil(mapping.error)
        XCTAssertEqual(mapping.targetPort, f.httpPort)
        let urlForRule = try XCTUnwrap(URL(string: "http://127.0.0.1:\(f.localPort)/fixture"))
        let response: Data
        do {
            (response, _) = try await URLSession.shared.data(from: urlForRule)
        } catch {
            let reason = tools.portmapRules.first { $0.id == mapping.id }?.error ?? SessionService.shared.state.displayText
            XCTFail("映射未返回响应：\(error)，\(reason)，task.cancelled=\(Task.isCancelled)")
            throw error
        }
        XCTAssertEqual(String(decoding: response, as: UTF8.self), "rc-loopback")
        XCTAssertNil(tools.portmapRemove(sessionID: id, ruleID: mapping.id))
        try await waitFor("移除映射") { !tools.portmapRules.contains { $0.id == mapping.id } }
    }

    @MainActor func testOwnerSignalTools() async throws {
        let f = try fixture(), auth = AuthService.shared, session = SessionService.shared
        guard auth.serverTarget.host == "127.0.0.1", !auth.isLoggedIn else { throw XCTSkip("需要无现有登录的本机服务") }
        defer { ToolService.shared.stop(); session.close(); auth.logout() }
        try await auth.login(email: f.email, password: f.accountPassword)
        try await waitFor("主控端上线") { RuntimeService.shared.signalRunning }
        let result = try await RuntimeService.connect(targetID: f.device)
        session.adopt(sessionID: result.sessionID, watchOnly: false)
        try await waitFor("已认证的控制会话") { session.isConnected }
        guard result.ownerConnection, session.mutuallyAuthenticated == true, !session.peerWatchOnly else {
            XCTFail("工具验收需要通过双向认证的本账号会话"); return
        }
        ToolService.shared.start(sessionID: result.sessionID)
        try await checkTools(f, id: result.sessionID)
    }

    @MainActor func testLocalAccountAndDevice() async throws {
        _ = try fixture()
        let auth = AuthService.shared, runtime = RuntimeService.shared
        guard auth.serverTarget.host == "127.0.0.1", !auth.isLoggedIn else { throw XCTSkip("需要无现有登录的本机服务") }
        let email = "rc-\(UUID())@example.invalid", password = UUID().uuidString + "a9!"
        defer { auth.logout() }
        try await auth.register(email: email, password: password)
        try await waitFor("注册、设备证书与信令") { runtime.deviceID != nil || runtime.lastError != nil }
        XCTAssertNil(runtime.lastError)
        let id = try XCTUnwrap(runtime.deviceID)
        XCTAssertEqual(id.filter(\.isNumber).count, 9)
        auth.logout()
        try await auth.login(email: email, password: password)
        try await waitFor("登录后同一设备身份") { runtime.deviceID == id }
        let old = auth.session?.refreshToken
        let refreshed = await auth.refreshTokens()
        XCTAssertTrue(refreshed)
        XCTAssertTrue(auth.session?.refreshToken != old, "测试服务器应轮换刷新令牌")
        await auth.refreshDevices()
        XCTAssertTrue(auth.devices.contains { $0.deviceID == id })
        try await auth.renameDevice(deviceID: id, alias: "回归设备")
        XCTAssertTrue(auth.devices.contains { $0.deviceID == id && $0.alias == "回归设备" })
        try await auth.removeDevice(deviceID: id)
        XCTAssertFalse(auth.devices.contains { $0.deviceID == id })
    }

    @MainActor private func checkOwnerSignal(requireFrame: Bool) async throws {
        let f = try fixture(), auth = AuthService.shared, s = SessionService.shared
        guard auth.serverTarget.host == "127.0.0.1", !auth.isLoggedIn else { throw XCTSkip("需要无现有登录的本机服务") }
        defer { s.close(); auth.logout() }
        try await auth.login(email: f.email, password: f.accountPassword)
        try await waitFor("主控端上线") { RuntimeService.shared.signalRunning }
        for attempt in 0..<2 {
            let baseline = try XCTUnwrap(presentedFrames())
            let result = try await RuntimeService.connect(targetID: f.device, watchOnly: true)
            s.adopt(sessionID: result.sessionID, watchOnly: true)
            XCTAssertTrue(result.ownerConnection)
            try await waitFor("九位设备码会话") { s.isConnected || { if case .ended = s.state { true } else { false } }() }
            XCTAssertTrue(s.isConnected, s.state.displayText)
            XCTAssertEqual(s.mutuallyAuthenticated, true)
            if requireFrame { try await waitFor("解码新的桌面帧") { (self.presentedFrames() ?? 0) > baseline } }
            if attempt == 0 {
                var request = URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1:\(f.httpPort)/disconnect")))
                request.httpMethod = "POST"
                let (result, _) = try await URLSession.shared.data(for: request)
                XCTAssertEqual(String(decoding: result, as: UTF8.self), "fixture-disconnected")
                try await waitFor("Mac 主动断开") { if case .ended = s.state { true } else { false } }
                s.close()
            }
        }
    }

    @MainActor func testOwnerSignalReconnect() async throws {
        try await checkOwnerSignal(requireFrame: false)
    }

    @MainActor func testOwnerSignalDesktopFrames() async throws {
        let f = try fixture()
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(f.httpPort)/capture-mode"))
        let (mode, _) = try await URLSession.shared.data(from: url)
        guard String(decoding: mode, as: UTF8.self) == "display" else {
            throw XCTSkip("真实桌面验收需显式启用 --capture-display 和屏幕录制权限")
        }
        try await checkOwnerSignal(requireFrame: true)
    }

    @MainActor private func presentedFrames() -> Int? {
        guard let raw = RuntimeService.callSync(rc_apple_media_stats),
              let obj = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else { return nil }
        return obj["presented_cvpb"] as? Int
    }
}
#endif
