import Testing
@testable import RabbitControlIOS

struct AssistTargetTests {
    @Test func validTargets() {
        #expect(AssistTarget(" 127.0.0.1:9901 ") == .direct("127.0.0.1:9901"))
        #expect(AssistTarget("[::1]:65535") == .direct("[::1]:65535"))
        #expect(AssistTarget("123 456 789") == .account("123456789"))
    }
    @Test(arguments: ["", "123", "abc:42", "::1:1", "12345678a", "127.0.0.1:0", "127.0.0.1:65536"])
    func invalidTarget(_ text: String) { #expect(AssistTarget(text) == nil) }
}
