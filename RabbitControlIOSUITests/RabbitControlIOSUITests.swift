import XCTest

final class RabbitControlIOSUITests: XCTestCase {
    @MainActor private func capture(_ name: String, app: XCUIApplication) {
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = name
        image.lifetime = .keepAlways
        add(image)
    }

    @MainActor private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestingMockAuth"]
        app.launch()
        return app
    }

    @MainActor func testBottomTabsUseStandardFullWidthSize() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "iPad 使用左侧常驻导航栏而非底部等分栏")
        let app = launch()
        let tabs = [
            app.buttons["tab.我的设备"],
            app.buttons["tab.远程协助"],
            app.buttons["tab.我的"],
        ]
        for tab in tabs {
            XCTAssertTrue(tab.waitForExistence(timeout: 5))
            XCTAssertTrue(tab.isHittable)
            XCTAssertGreaterThanOrEqual(tab.frame.width, app.frame.width / 3 - 1)
            XCTAssertGreaterThanOrEqual(tab.frame.height, 49)
        }
    }

    @MainActor func testAssistIsStandaloneAndReturnsToOrigin() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "iPad 协助页验证由专属分栏测试覆盖")
        let app = launch()
        capture("devices-home", app: app)
        app.buttons["tab.远程协助"].tap()
        let connect = app.buttons["assist.connect"]
        XCTAssertTrue(connect.waitForExistence(timeout: 5))
        XCTAssertFalse(connect.isEnabled)
        capture("assist-page", app: app)
        let target = app.textFields["assist.partnerID"]
        target.tap(); target.typeText("123")
        app.buttons["清除连接目标"].tap()
        XCTAssertEqual(target.value as? String, "九位设备 ID 或 IP:端口")
        // 协助页是底部 Tab,底栏在协助页可见、进会话后隐藏
        XCTAssertTrue(app.buttons["tab.我的设备"].exists)
        let field = app.textFields["assist.partnerID"]
        field.tap(); field.typeText("127.0.0.1:9901\n")
        let exit = app.buttons["session.exit"]
        XCTAssertTrue(exit.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["tab.我的"].exists)
        app.buttons["session.controlCenter"].tap()
        app.buttons["完成"].tap()
        exit.tap()
        XCTAssertTrue(connect.waitForExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, "127.0.0.1:9901")
    }

    @MainActor func testAccountDeviceSearchAndOfflineState() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "iPad 搜索已内联集成在设备分栏中")
        let app = launch()
        app.buttons["devices.allDevices"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        let tabGone = NSPredicate(format: "exists == false")
        expectation(for: tabGone, evaluatedWith: app.buttons["tab.我的"])
        waitForExpectations(timeout: 3)
        if !search.isHittable { app.swipeDown() }; search.tap(); search.typeText("Gaming")
        let row = app.buttons["all.device.gaming"]
        XCTAssertTrue(row.waitForExistence(timeout: 5)); row.tap()
        XCTAssertFalse(app.buttons["detail.enterDesktop"].isEnabled)
        XCTAssertFalse(app.buttons["detail.watchMode"].isEnabled)
        let wolButton = app.buttons["detail.wakeOnLan"]
        XCTAssertTrue(wolButton.waitForExistence(timeout: 3))
        XCTAssertTrue(wolButton.isEnabled)
        wolButton.tap()
        XCTAssertTrue(app.staticTexts["已发送远程开机指令"].waitForExistence(timeout: 2))
        capture("offline-detail", app: app)
        app.buttons["detail.copyID"].tap()
        XCTAssertTrue(app.staticTexts["已复制设备 ID"].waitForExistence(timeout: 2))
    }

    @MainActor func testClearUnmatchedSearchRestoresDevices() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "iPad 搜索已内联集成在设备分栏中")
        let app = launch()
        app.buttons["devices.allDevices"].tap()
        let search = app.searchFields.firstMatch
        if !search.isHittable { app.swipeDown() }
        search.tap(); search.typeText("no-such-device\n")
        let clear = app.buttons["清除搜索"]
        XCTAssertTrue(clear.waitForExistence(timeout: 5))
        clear.tap()
        XCTAssertTrue(app.buttons["all.device.mac-mini"].waitForExistence(timeout: 5))
    }

    @MainActor func testSignedOutRequiresLoginAndServerValidation() {
        let app = XCUIApplication()
        app.launchArguments = ["-auth.session", "signed-out"]
        app.launch()
        XCTAssertTrue(app.buttons["login.submit"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["login.submit"].isEnabled)
        XCTAssertFalse(app.buttons["tab.我的"].exists)
        capture("login-page", app: app)

        // 校验邮箱清理、明密文切换与注册强度反馈
        let emailField = app.textFields["login.email"]
        XCTAssertTrue(emailField.exists)
        emailField.tap()
        emailField.typeText("bad@")
        let securePass = app.secureTextFields["login.password"]
        securePass.tap()
        securePass.typeText("short1")
        XCTAssertFalse(app.buttons["login.submit"].isEnabled)
        app.buttons["login.clearEmail"].tap()
        emailField.typeText("demo@example.com")
        app.buttons["login.togglePassword"].tap()
        let plainPass = app.textFields["login.password"]
        XCTAssertTrue(plainPass.waitForExistence(timeout: 2))
        XCTAssertEqual(plainPass.value as? String, "short1")
        XCTAssertTrue(app.buttons["login.submit"].isEnabled)
        app.buttons["login.switchMode"].tap()
        XCTAssertFalse(app.buttons["login.submit"].isEnabled)
        XCTAssertTrue(app.otherElements["login.passwordStrength"].exists || app.staticTexts["login.passwordStrength"].exists)
        plainPass.tap()
        plainPass.typeText("2345")
        XCTAssertTrue(app.buttons["login.submit"].isEnabled)
        capture("register-page-filled", app: app)

        app.buttons["服务器设置"].tap()
        let addServer = app.buttons["server.add"]
        XCTAssertTrue(addServer.waitForExistence(timeout: 5))
        addServer.tap()
        let host = app.textFields["服务器主机名或 IP"]
        XCTAssertTrue(host.waitForExistence(timeout: 5))
        host.tap(); host.typeText("/path")
        XCTAssertFalse(app.buttons["server.editor.save"].isEnabled)
        XCTAssertFalse(app.buttons["server.editor.testConnection"].isEnabled)
        app.buttons["server.editor.cancel"].tap()
        XCTAssertTrue(app.buttons["关闭"].waitForExistence(timeout: 5))
        app.buttons["关闭"].tap()
        XCTAssertTrue(app.buttons["login.submit"].waitForExistence(timeout: 5))
    }

    @MainActor func testPasswordFieldsAndCancel() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "iPad 修改密码内嵌在设置分栏右侧")
        let app = launch()
        app.buttons["tab.我的"].tap()
        capture("profile-page", app: app)
        app.buttons["profile.修改密码"].tap()
        XCTAssertEqual(app.secureTextFields.count, 3)
        XCTAssertFalse(app.buttons["确定"].isEnabled)
        app.buttons["取消"].tap()
        XCTAssertTrue(app.buttons["profile.修改密码"].waitForExistence(timeout: 5))
    }

    @MainActor func testEndFromControlHubReturnsToDevice() {
        let app = launch()
        app.buttons["device.mac-mini"].tap()
        app.buttons["detail.enterDesktop"].tap()
        app.buttons["session.controlCenter"].tap()
        let end = app.buttons["结束远程协助"]
        XCTAssertTrue(end.waitForExistence(timeout: 5))
        XCTAssertTrue(end.isHittable)
        end.tap()
        app.buttons["结束会话"].tap()
        let button = app.buttons["detail.enterDesktop"]
        let returned = NSPredicate(format: "isHittable == true")
        expectation(for: returned, evaluatedWith: button)
        waitForExpectations(timeout: 5)
        XCTAssertFalse(app.buttons["session.exit"].exists)
    }

    @MainActor func testWatchSessionDoesNotExposeControlTools() {
        let app = launch()
        app.buttons["device.mac-mini"].tap()
        app.buttons["detail.watchMode"].tap()
        XCTAssertFalse(app.buttons["tab.我的设备"].exists)
        app.buttons["session.controlCenter"].tap()
        XCTAssertTrue(app.buttons["完成"].waitForExistence(timeout: 5))
        capture("watch-controls", app: app)
        XCTAssertFalse(app.buttons["文件传输"].exists)
        XCTAssertFalse(app.switches["在桌面上显示鼠标工具"].exists)
        app.buttons["完成"].tap(); app.buttons["session.exit"].tap()
        XCTAssertTrue(app.buttons["detail.enterDesktop"].waitForExistence(timeout: 5))
    }

    @MainActor func testProfileSettingsAndServerCancel() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "iPad 设置采用主从同屏内嵌面板")
        let app = launch()
        app.buttons["tab.我的"].tap(); app.buttons["profile.设置"].tap()
        XCTAssertTrue(app.switches["settings.showHUD"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["tab.我的设备"].exists)
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["profile.网络代理"].tap()
        XCTAssertTrue(app.buttons["proxy.save"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["profile.服务器设置"].tap()
        XCTAssertFalse(app.buttons["保存"].exists)
        app.buttons["关闭"].tap()
        XCTAssertTrue(app.buttons["profile.设置"].waitForExistence(timeout: 5))
    }

    @MainActor func testLandscapeRegistrationFitsAboveNavigationAfterClosingSettings() {
        let app = XCUIApplication()
        // Override the persisted account only in this launch's argument domain.
        app.launchArguments = ["-auth.session", "signed-out", "-AppleInterfaceStyle", "Dark"]
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        app.launch()
        app.buttons["login.switchMode"].tap()
        app.buttons["服务器设置"].tap()
        app.buttons["关闭"].tap()
        let submit = app.buttons["login.submit"]
        XCTAssertTrue(submit.waitForExistence(timeout: 5))
        XCTAssertEqual(submit.label, "注册并登录")
        XCTAssertFalse(submit.isEnabled)
        XCTAssertLessThanOrEqual(submit.frame.maxY, app.windows.firstMatch.frame.maxY)
    }

    @MainActor func testMoreToolsMenuUsesDesignedModalAndPowerConfirm() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "iPad 详情台直接平铺工具与电源磁贴")
        let app = launch()
        app.buttons["device.mac-mini"].tap()
        app.buttons["detail.more"].tap()

        XCTAssertTrue(app.staticTexts["更多工具"].waitForExistence(timeout: 5))
        for id in ["moreTools.files", "moreTools.watch", "moreTools.terminal", "moreTools.portMapping", "moreTools.reboot", "moreTools.shutdown"] {
            XCTAssertTrue(app.buttons[id].exists, id)
        }
        XCTAssertTrue(app.buttons["moreTools.reorder"].exists)
        XCTAssertTrue(app.buttons["moreTools.close"].exists)
        capture("more-tools-menu", app: app)

        app.buttons["moreTools.reboot"].tap()
        XCTAssertTrue(app.staticTexts["重启设备"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["powerConfirm.cancel"].exists)
        XCTAssertTrue(app.buttons["powerConfirm.confirm"].exists)
        capture("more-tools-power-confirm", app: app)
        app.buttons["powerConfirm.cancel"].tap()
        XCTAssertTrue(app.buttons["moreTools.files"].waitForExistence(timeout: 3))

        app.buttons["moreTools.close"].tap()
        let menuGone = NSPredicate(format: "exists == false")
        expectation(for: menuGone, evaluatedWith: app.staticTexts["更多工具"])
        waitForExpectations(timeout: 3)
    }

    @MainActor func testSessionPillQuickModeCollapseAndGuideReplay() {
        let app = launch()
        app.buttons["device.mac-mini"].tap()
        app.buttons["detail.enterDesktop"].tap()

        let quickMode = app.buttons["session.quickTouchMode"]
        XCTAssertTrue(quickMode.waitForExistence(timeout: 5))
        let initialLabel = quickMode.label
        quickMode.tap()
        XCTAssertNotEqual(quickMode.label, initialLabel)
        quickMode.tap()
        XCTAssertEqual(quickMode.label, initialLabel)

        app.buttons["session.collapseControls"].tap()
        let expand = app.buttons["session.expandControls"]
        XCTAssertTrue(expand.waitForExistence(timeout: 3))
        expand.tap()
        XCTAssertTrue(app.buttons["session.controlCenter"].waitForExistence(timeout: 3))

        app.buttons["session.controlCenter"].tap()
        XCTAssertTrue(app.buttons["完成"].waitForExistence(timeout: 5))
        let replay = app.buttons["hub.replayGuide"]
        for _ in 0..<2 where !replay.isHittable {
            app.collectionViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(replay.waitForExistence(timeout: 3))
        replay.tap()
        let skip = app.buttons["跳过"]
        XCTAssertTrue(skip.waitForExistence(timeout: 5))
        capture("session-gesture-guide", app: app)
        skip.tap()

        app.buttons["session.exit"].tap()
        XCTAssertTrue(app.buttons["detail.enterDesktop"].waitForExistence(timeout: 5))
    }

    // MARK: - iPad 独立分栏工作台验证

    @MainActor func testIPadWorkspaceSplitAndSessionInspector() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "仅在 iPad 模拟器运行分栏工作台验证")
        XCUIDevice.shared.orientation = .landscapeLeft

        let app = XCUIApplication()
        app.launchArguments = ["-uiTestingMockAuth", "-AppleInterfaceStyle", "Light"]
        app.launch()

        // 1. 左侧常驻导航 + 中栏设备列表 + 右栏常驻详情台同时同屏可见
        XCTAssertTrue(app.buttons["tab.我的设备"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["device.mac-mini"].exists)
        XCTAssertTrue(app.buttons["detail.enterDesktop"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["detail.files"].exists)
        XCTAssertTrue(app.buttons["detail.terminal"].exists)
        XCTAssertTrue(app.buttons["detail.portMapping"].exists)
        capture("ipad-01-devices-landscape-light", app: app)

        // 切换离线设备后右侧详情原地更新远程开机入口
        app.buttons["device.gaming"].tap()
        let wol = app.buttons["detail.wakeOnLan"]
        XCTAssertTrue(wol.waitForExistence(timeout: 3))
        XCTAssertTrue(wol.isEnabled)
        app.buttons["device.mac-mini"].tap()

        // 2. 远程协助双栏工作台 + 收藏与最近连接面板
        app.buttons["tab.远程协助"].tap()
        XCTAssertTrue(app.textFields["assist.partnerID"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["收藏与最近连接"].exists)
        capture("ipad-02-assist-landscape-light", app: app)

        // 3. 我的主从设置中心：右侧同屏切换配置面板
        app.buttons["tab.我的"].tap()
        XCTAssertTrue(app.buttons["settings.qualityPreset"].waitForExistence(timeout: 5))
        capture("ipad-03-profile-settings-landscape-light", app: app)
        app.buttons["profile.服务器设置"].tap()
        XCTAssertTrue(app.buttons["server.add"].waitForExistence(timeout: 3))
        app.buttons["profile.网络代理"].tap()
        XCTAssertTrue(app.buttons["proxy.save"].waitForExistence(timeout: 3))

        // 4. 远控会话舞台 + 右侧并排工具抽屉（不遮挡左侧舞台）
        app.buttons["tab.我的设备"].tap()
        app.buttons["detail.enterDesktop"].tap()
        let controlBtn = app.buttons["session.controlCenter"]
        XCTAssertTrue(controlBtn.waitForExistence(timeout: 5))
        controlBtn.tap()

        let termTab = app.buttons["inspector.tab.terminal"]
        XCTAssertTrue(termTab.waitForExistence(timeout: 3))
        // 右侧抽屉展开时，左侧舞台顶部退出按钮依然可点（非遮罩 Sheet）
        XCTAssertTrue(app.buttons["session.exit"].isHittable)
        capture("ipad-04-session-inspector-hub", app: app)

        termTab.tap()
        capture("ipad-05-session-inspector-terminal", app: app)
        app.buttons["inspector.close"].tap()
        app.buttons["session.exit"].tap()
        XCTAssertTrue(app.buttons["detail.enterDesktop"].waitForExistence(timeout: 5))
    }

    @MainActor func testIPadDarkAndForcedLandscapeLock() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "仅在 iPad 模拟器运行深色工作台与强制横屏验证")
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .landscapeLeft }

        // 1. 深色模式双栏登录工作台
        let loginApp = XCUIApplication()
        loginApp.launchArguments = ["-auth.session", "signed-out", "-AppleInterfaceStyle", "Dark"]
        loginApp.launch()
        XCTAssertTrue(loginApp.buttons["login.submit"].waitForExistence(timeout: 5))
        capture("ipad-06-login-landscape-dark", app: loginApp)
        loginApp.terminate()

        // 2. 深色模式主页 + 物理设备切至竖屏时界面依然强制维持三栏横屏
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestingMockAuth", "-AppleInterfaceStyle", "Dark"]
        app.launch()
        XCTAssertTrue(app.buttons["detail.enterDesktop"].waitForExistence(timeout: 5))
        capture("ipad-07-devices-landscape-dark", app: app)

        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(app.buttons["tab.我的设备"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["device.mac-mini"].exists)
        XCTAssertTrue(app.buttons["detail.enterDesktop"].exists)
        let windowFrame = app.windows.firstMatch.frame
        XCTAssertGreaterThan(windowFrame.width, windowFrame.height, "iPad 物理竖屏持握时应用窗口应强制维持横屏宽高比")
        capture("ipad-08-devices-forced-landscape", app: app)
    }
}
