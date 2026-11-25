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

    @MainActor func testBottomTabsUseStandardFullWidthSize() {
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

    @MainActor func testAssistIsStandaloneAndReturnsToOrigin() {
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
        XCTAssertEqual(target.value as? String, "设备 ID 或 IP:端口")
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

    @MainActor func testAccountDeviceSearchAndOfflineState() {
        let app = launch()
        app.buttons["devices.allDevices"].tap()
        XCTAssertFalse(app.buttons["tab.我的"].exists)
        let search = app.searchFields.firstMatch
        if !search.isHittable { app.swipeDown() }; search.tap(); search.typeText("Gaming")
        let row = app.buttons["all.device.gaming"]
        XCTAssertTrue(row.waitForExistence(timeout: 5)); row.tap()
        XCTAssertFalse(app.buttons["detail.enterDesktop"].isEnabled)
        XCTAssertFalse(app.buttons["detail.watchMode"].isEnabled)
        capture("offline-detail", app: app)
        app.buttons["detail.copyID"].tap()
        XCTAssertTrue(app.staticTexts["已复制设备 ID"].waitForExistence(timeout: 2))
    }

    @MainActor func testClearUnmatchedSearchRestoresDevices() {
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
        XCTAssertFalse(app.buttons["tab.我的"].exists)
        capture("login-page", app: app)
        app.buttons["服务器设置"].tap()
        let host = app.textFields["服务器主机名或 IP"]
        host.tap(); host.typeText("/path")
        XCTAssertFalse(app.buttons["保存"].isEnabled)
        XCTAssertFalse(app.buttons["测试连接"].isEnabled)
        app.buttons["关闭"].tap()
        XCTAssertTrue(app.buttons["login.submit"].waitForExistence(timeout: 5))
    }

    @MainActor func testPasswordFieldsAndCancel() {
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

    @MainActor func testProfileSettingsAndServerCancel() {
        let app = launch()
        app.buttons["tab.我的"].tap(); app.buttons["profile.设置"].tap()
        XCTAssertTrue(app.switches["settings.showHUD"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["tab.我的设备"].exists)
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
}
