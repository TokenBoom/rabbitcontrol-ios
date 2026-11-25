import XCTest

final class RabbitControlIOSUITests: XCTestCase {
    // XCUITest 的 API 隔离在 MainActor;测试方法需要显式标注,类本身则不能整体隔离
    @MainActor
    func testRootViewShowsDeviceList() {
        let app = XCUIApplication()
        app.launch()

        let title = app.staticTexts["root.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 10), "根视图未显示「可控设备」标题")
        XCTAssertTrue(app.buttons["devices.allDevices"].exists, "缺少「全部设备」入口")
        XCTAssertTrue(app.buttons["device.mac-mini"].waitForExistence(timeout: 5), "缺少在线设备卡片")
    }

    @MainActor
    func testDeviceDetailEntersSession() {
        let app = XCUIApplication()
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
        let app = XCUIApplication()
        app.launch()

        app.buttons["tab.远程协助"].tap()

        XCTAssertTrue(app.textFields["assist.partnerID"].waitForExistence(timeout: 5), "缺少伙伴设备 ID 输入框")
        XCTAssertTrue(app.buttons["assist.connect"].exists, "缺少「开始远控」按钮")
        XCTAssertTrue(app.staticTexts["assist.localID"].exists, "缺少本设备 ID")
    }

    @MainActor
    func testAssistConnectDisabledWithoutInput() {
        let app = XCUIApplication()
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
        let app = XCUIApplication()
        app.launch()

        app.buttons["tab.我的"].tap()

        XCTAssertTrue(app.staticTexts["profile.phone"].waitForExistence(timeout: 5), "缺少账户手机号")
    }
}
