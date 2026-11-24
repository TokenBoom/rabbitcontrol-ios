import XCTest

final class RabbitControlIOSUITests: XCTestCase {
    // XCUITest 的 API 隔离在 MainActor；测试方法需要显式标注，类本身则不能整体隔离
    @MainActor
    func testRootViewShowsAppName() {
        let app = XCUIApplication()
        app.launch()

        let title = app.staticTexts["root.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 10), "根视图未显示应用名称")
    }
}
