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

    @Test func portCompletionSuggestsDefaultPortForBareIP() {
        #expect(AssistTarget.portCompletion(for: "192.168.1.10") == "192.168.1.10:9901")
        #expect(AssistTarget.portCompletion(for: "192.168.1.10:") == "192.168.1.10:9901")
        #expect(AssistTarget.portCompletion(for: "[::1]:") == "[::1]:9901")
        #expect(AssistTarget.portCompletion(for: "123") == nil)
        #expect(AssistTarget.portCompletion(for: "192.168.1.10:9901") == nil)
    }

    @Test func typingProgressDistinguishesValidPrefixFromInvalidInput() {
        #expect(AssistTarget.isTypingProgress("123"))
        #expect(AssistTarget.isTypingProgress("604 92"))
        #expect(AssistTarget.isTypingProgress("192.168.1."))
        #expect(AssistTarget.isTypingProgress("192.168.1.10:"))
        #expect(!AssistTarget.isTypingProgress("abc:42"))
        #expect(!AssistTarget.isTypingProgress("127.0.0.1:0"))
        #expect(!AssistTarget.isTypingProgress("127.0.0.1:65536"))
        #expect(!AssistTarget.isTypingProgress("123456789"))
    }
}
