import XCTest

final class RabbitControlIOSUITests: XCTestCase {
    func testRootViewShowsAppName() {
        let app = XCUIApplication()
        app.launch()

        let title = app.staticTexts["root.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 10), "根视图未显示应用名称")
    }
}
