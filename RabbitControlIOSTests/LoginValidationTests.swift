import Testing
@testable import RabbitControlIOS

struct LoginValidationTests {
    @Test("邮箱格式校验支持标准域名与内网主机，拦截残缺或含空白输入")
    func emailValidation() {
        #expect(LoginValidation.isValidEmail("user@example.com"))
        #expect(LoginValidation.isValidEmail("  ops+prod@company.internal  "))
        #expect(LoginValidation.isValidEmail("admin@localhost"))

        #expect(!LoginValidation.isValidEmail(""))
        #expect(!LoginValidation.isValidEmail("   "))
        #expect(!LoginValidation.isValidEmail("@"))
        #expect(!LoginValidation.isValidEmail("user@"))
        #expect(!LoginValidation.isValidEmail("@example.com"))
        #expect(!LoginValidation.isValidEmail("a@b@c.com"))
        #expect(!LoginValidation.isValidEmail("user name@example.com"))
        #expect(!LoginValidation.isValidEmail("user@.example.com"))
        #expect(!LoginValidation.isValidEmail("user@example..com"))
    }

    @Test("注册密码强度按长度与字符多样性分级")
    func passwordStrength() {
        #expect(LoginValidation.evaluatePassword("") == .empty)
        #expect(LoginValidation.evaluatePassword("12345") == .tooShort(remaining: 3))
        #expect(LoginValidation.evaluatePassword("abcdefgh") == .fair)
        #expect(LoginValidation.evaluatePassword("abcd1234") == .good)
        #expect(LoginValidation.evaluatePassword("Abcd1234!xyz") == .strong)
    }
}
