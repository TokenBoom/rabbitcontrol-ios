import Foundation
import Testing

/// 校验 `project.yml` 里的工程配置确实落到了构建产物上（测试宿主是 RabbitControlIOS.app）。
struct AppBundleTests {
    private func string(_ key: String) -> String? {
        Bundle.main.object(forInfoDictionaryKey: key) as? String
    }

    @Test("显示名称为 RabbitControl")
    func displayName() {
        #expect(string("CFBundleDisplayName") == "RabbitControl")
    }

    @Test("版本号为三段式、构建号为纯数字")
    func version() {
        let components = (string("CFBundleShortVersionString") ?? "").split(separator: ".")
        #expect(components.count == 3)
        #expect(components.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) })

        let build = string("CFBundleVersion") ?? ""
        #expect(!build.isEmpty && build.allSatisfy(\.isNumber))
    }

    @Test("已声明本地网络权限的用途说明")
    func localNetworkUsageDescription() {
        #expect(!(string("NSLocalNetworkUsageDescription") ?? "").isEmpty)
    }
}
