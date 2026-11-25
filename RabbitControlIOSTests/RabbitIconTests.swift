import Testing
import UIKit
@testable import RabbitControlIOS

struct RabbitIconTests {
    @Test("所有自绘 SVG 图标都能作为模板图像加载")
    func allIconsLoad() throws {
        for icon in RabbitIcon.Name.allCases {
            let image = try #require(UIImage(named: icon.rawValue))
            #expect(image.size.width > 0)
            #expect(image.size.height > 0)
        }
    }
}
