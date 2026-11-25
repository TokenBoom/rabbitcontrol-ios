import XCTest

final class RabbitControlIOSUITests: XCTestCase {

    /// 注入 mock 认证,UI 测试不依赖真实服务端。
    private func makeApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestingMockAuth"]
        return app
    }
    // XCUITest 的 API 隔离在 MainActor;测试方法需要显式标注,类本身则不能整体隔离
    @MainActor
    func testRootViewShowsDeviceList() {
        let app = makeApp()
        app.launch()

        let title = app.staticTexts["root.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 10), "根视图未显示「可控设备」标题")
        XCTAssertTrue(app.buttons["devices.allDevices"].exists, "缺少「全部设备」入口")
        XCTAssertTrue(app.buttons["device.mac-mini"].waitForExistence(timeout: 5), "缺少在线设备卡片")
    }

    @MainActor
    func testDeviceDetailEntersSession() {
        let app = makeApp()
        app.launch()

        app.buttons["device.mac-mini"].tap()

        let enter = app.buttons["detail.enterDesktop"]
        XCTAssertTrue(enter.waitForExistence(timeout: 5), "设备详情缺少「进入桌面」")
        enter.tap()

        XCTAssertTrue(app.descendants(matching: .any)["session.hud"].waitForExistence(timeout: 5), "会话界面缺少 HUD")
        XCTAssertTrue(app.buttons["session.controlCenter"].exists, "会话界面缺少「控制中心」")
    }

    @MainActor
    func testAssistTabShowsPartnerCard() {
        let app = makeApp()
        app.launch()

        app.buttons["tab.远程协助"].tap()

        XCTAssertTrue(app.textFields["assist.partnerID"].waitForExistence(timeout: 5), "缺少伙伴设备 ID 输入框")
        XCTAssertTrue(app.buttons["assist.connect"].exists, "缺少「开始远控」按钮")
        XCTAssertTrue(app.staticTexts["assist.localID"].exists, "缺少本设备 ID")
    }

    @MainActor
    func testAssistConnectDisabledWithoutInput() {
        let app = makeApp()
        app.launch()

        app.buttons["tab.远程协助"].tap()

        let connect = app.buttons["assist.connect"]
        XCTAssertTrue(connect.waitForExistence(timeout: 5))
        XCTAssertFalse(connect.isEnabled, "未输入设备 ID 时「开始远控」应禁用")

        let field = app.textFields["assist.partnerID"]
        field.tap()
        field.typeText("183435140")
        XCTAssertTrue(connect.isEnabled, "输入设备 ID 后「开始远控」应可用")
    }

    @MainActor
    func testProfileTabShowsAccount() {
        let app = makeApp()
        app.launch()

        app.buttons["tab.我的"].tap()

        XCTAssertTrue(app.staticTexts["profile.phone"].waitForExistence(timeout: 5), "缺少账户手机号")
    }

    @MainActor
    func testDeviceDetailOpensFileTransfer() {
        let app = makeApp()
        app.launch()

        app.buttons["device.mac-mini"].tap()
        let tool = app.buttons["detail.tool.文件传输"]
        XCTAssertTrue(tool.waitForExistence(timeout: 5), "设备详情缺少「文件传输」入口")
        // 工具入口在首屏下方,先滚动露出再点
        app.swipeUp()
        tool.tap()

        XCTAssertTrue(app.buttons["transfer.send"].waitForExistence(timeout: 5), "文件传输缺少发送按钮")
        XCTAssertFalse(app.buttons["transfer.send"].isEnabled, "未勾选文件时发送应禁用")
    }

    @MainActor
    func testPortMappingAddValidation() {
        let app = makeApp()
        app.launch()

        app.buttons["device.mac-mini"].tap()
        app.swipeUp()
        app.buttons["detail.tool.端口映射"].tap()
        XCTAssertTrue(app.buttons["portmap.add"].waitForExistence(timeout: 5), "端口映射缺少「添加」")
        app.buttons["portmap.add"].tap()

        let save = app.buttons["portmap.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 5), "添加弹窗缺少「保存」")
        save.tap()
        XCTAssertTrue(app.staticTexts["名称需为 1–64 个字符"].waitForExistence(timeout: 3), "空名称未触发校验错误")
    }

    /// 遍历主要界面并截图,附件随测试结果导出,供设计走查。
    @MainActor
    func testCaptureScreenshots() throws {
        let app = makeApp()
        app.launch()

        func shot(_ name: String) {
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }

        XCTAssertTrue(app.staticTexts["root.title"].waitForExistence(timeout: 10))
        shot("01-可控设备")

        app.buttons["tab.远程协助"].tap()
        XCTAssertTrue(app.textFields["assist.partnerID"].waitForExistence(timeout: 5))
        shot("02-远程协助")

        app.buttons["tab.我的"].tap()
        XCTAssertTrue(app.staticTexts["profile.phone"].waitForExistence(timeout: 5))
        shot("03-我的")

        app.buttons["tab.我的设备"].tap()
        app.buttons["device.mac-mini"].tap()
        XCTAssertTrue(app.buttons["detail.enterDesktop"].waitForExistence(timeout: 5))
        shot("04-设备详情")

        app.swipeUp()
        app.buttons["detail.tool.文件传输"].tap()
        XCTAssertTrue(app.buttons["transfer.send"].waitForExistence(timeout: 5))
        shot("05-文件传输")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        app.buttons["detail.tool.端口映射"].tap()
        XCTAssertTrue(app.buttons["portmap.add"].waitForExistence(timeout: 5))
        app.swipeUp()
        shot("06-端口映射")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        app.buttons["detail.tool.终端"].tap()
        sleep(1)
        shot("07-终端")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        app.swipeDown()
        app.buttons["detail.enterDesktop"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["session.hud"].waitForExistence(timeout: 5))
        sleep(1)
        shot("08-远控会话")

        app.buttons["session.controlCenter"].tap()
        sleep(1)
        shot("09-控制中心")
    }
}
