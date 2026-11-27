import Dispatch
import SwiftUI
import Testing
import UIKit
@testable import RabbitControlIOS

struct DesignTokensTests {
    @Test("动态色可在非主线程安全解析（防止 SwiftUI AsyncRenderer 触发主线程隔离断言闪退）")
    func adaptiveColorsResolveOffMainThread() async {
        let queue = DispatchQueue(label: "test.swiftui.async-renderer")
        let resolved: [(CGFloat, CGFloat)] = await withCheckedContinuation { continuation in
            queue.async {
                dispatchPrecondition(condition: .notOnQueue(.main))
                let lightTraits = UITraitCollection(userInterfaceStyle: .light)
                let darkTraits = UITraitCollection(userInterfaceStyle: .dark)

                let candidates: [UIColor] = [
                    RCColor.adaptiveUIColor(0xEEF1F6, 0x18191C),
                    UIColor(RCColor.bgSidebar),
                    UIColor(RCColor.bgCard),
                    UIColor(RCColor.bgHover),
                    UIColor(RCColor.bgPage),
                    UIColor(RCColor.bgToolTile),
                    UIColor(RCColor.bgToolTilePressed),
                    UIColor(RCColor.textSecondary),
                    UIColor(RCColor.textDisabled),
                ]

                let pairs = candidates.map { dynamicColor -> (CGFloat, CGFloat) in
                    var lr: CGFloat = 0
                    var dr: CGFloat = 0
                    _ = dynamicColor.resolvedColor(with: lightTraits).getRed(&lr, green: nil, blue: nil, alpha: nil)
                    _ = dynamicColor.resolvedColor(with: darkTraits).getRed(&dr, green: nil, blue: nil, alpha: nil)
                    return (lr, dr)
                }
                continuation.resume(returning: pairs)
            }
        }

        #expect(resolved.count == 9)
        for (lightRed, darkRed) in resolved {
            #expect(abs(lightRed - darkRed) > 0.05)
        }
    }
}
