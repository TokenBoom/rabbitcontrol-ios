import CryptoKit
import Foundation
import LocalAuthentication
import SwiftUI

/// 客户端本地应用锁（对齐 macOS 基线 §2.4 `client_lock` 与 §十一 iOS 生物识别/PIN 锁）。
///
/// 安全边界：
/// - 锁口令经随机 16 字节盐值 SHA-256 摘要后仅存系统钥匙串（`SessionKeychain`），绝不落盘明文；
/// - `isLocked == true` 时，`requireUnlocked()` 阻断一切出站连接与远程工具调用；
/// - 支持 Face ID / Touch ID 生物识别解锁及前后台超时自动锁定。
@Observable
final class AppLockStore {
    static let shared = AppLockStore()

    nonisolated enum AutoLockDelay: Int, CaseIterable, Identifiable, Sendable {
        case immediately = 0
        case oneMinute = 60
        case fiveMinutes = 300
        case fifteenMinutes = 900

        var id: Int { rawValue }

        var label: String {
            switch self {
            case .immediately: "切入后台立即锁定"
            case .oneMinute: "离开 1 分钟后"
            case .fiveMinutes: "离开 5 分钟后"
            case .fifteenMinutes: "离开 15 分钟后"
            }
        }
    }

    private nonisolated struct StoredVerifier: Codable, Equatable, Sendable {
        let saltHex: String
        let digestHex: String
    }

    private(set) var isEnabled: Bool
    private(set) var isLocked: Bool
    var biometricsEnabled: Bool {
        didSet { defaults.set(biometricsEnabled, forKey: "applock.biometrics") }
    }
    var autoLockDelay: AutoLockDelay {
        didSet { defaults.set(autoLockDelay.rawValue, forKey: "applock.delaySec") }
    }

    private(set) var failedAttempts: Int = 0
    private(set) var cooldownUntil: Date?

    private let defaults: UserDefaults
    private let keychain: SessionKeychain
    private var backgroundedAt: Date?

    init(
        defaults: UserDefaults = .standard,
        keychainService: String = "com.rabbitcontrol.ios.applock"
    ) {
        self.defaults = defaults
        self.keychain = SessionKeychain(service: keychainService)
        let hasVerifier = (try? self.keychain.load()) != nil
        let enabledPref = defaults.bool(forKey: "applock.enabled") && hasVerifier
        self.isEnabled = enabledPref
        self.biometricsEnabled = defaults.object(forKey: "applock.biometrics") == nil
            ? true
            : defaults.bool(forKey: "applock.biometrics")
        let rawDelay = defaults.object(forKey: "applock.delaySec") as? Int ?? AutoLockDelay.oneMinute.rawValue
        self.autoLockDelay = AutoLockDelay(rawValue: rawDelay) ?? .oneMinute
        // UI 测试注入默认不锁屏，除非测试显式调用 lock()
        self.isLocked = enabledPref && !AuthService.uiTestingMock
    }

    /// 检查设备硬件是否支持 Face ID / Touch ID。
    var biometricTypeLabel: String? {
        let context = LAContext()
        var err: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &err) else {
            return nil
        }
        switch context.biometryType {
        case .faceID: return "面容 ID"
        case .touchID: return "触控 ID"
        case .opticID: return "视网膜 ID"
        default: return "生物识别"
        }
    }

    /// 核心安全门禁：锁定时抛出结构化错误，阻断出站会话与敏感操作。
    func requireUnlocked() throws {
        guard !isLocked else {
            throw RCUiErrorFailure(
                uiError: CoreClient.resolveUiError(
                    code: RCErrorCodes.authUnauthorized,
                    detail: "客户端已锁定，请先验证本地锁密码或生物识别。"
                )
            )
        }
    }

    /// 首次启用本地应用锁（设置 4–32 位 PIN 或锁定密码）。
    func enable(newPassword: String) throws {
        let cleaned = newPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (4...32).contains(cleaned.count) else {
            throw RCUiErrorFailure(
                uiError: CoreClient.resolveUiError(
                    code: RCErrorCodes.validationInvalidInput,
                    detail: "应用锁密码长度需为 4–32 位。"
                )
            )
        }
        let verifier = Self.makeVerifier(password: cleaned)
        let encoded = try JSONEncoder().encode(verifier)
        try keychain.store(encoded)
        defaults.set(true, forKey: "applock.enabled")
        isEnabled = true
        isLocked = false
        failedAttempts = 0
        cooldownUntil = nil
    }

    /// 修改已启用的应用锁密码。
    func changePassword(current: String, newPassword: String) throws {
        guard verifyPassword(current) else {
            throw RCUiErrorFailure(
                uiError: CoreClient.resolveUiError(
                    code: RCErrorCodes.authInvalidCredentials,
                    detail: "当前应用锁密码不正确。"
                )
            )
        }
        try enable(newPassword: newPassword)
    }

    /// 验证原密码后关闭应用锁。
    func disable(current: String) throws {
        guard verifyPassword(current) else {
            throw RCUiErrorFailure(
                uiError: CoreClient.resolveUiError(
                    code: RCErrorCodes.authInvalidCredentials,
                    detail: "当前应用锁密码不正确。"
                )
            )
        }
        try keychain.remove()
        defaults.set(false, forKey: "applock.enabled")
        isEnabled = false
        isLocked = false
        failedAttempts = 0
        cooldownUntil = nil
    }

    /// 登出账号时同步解除锁定遮罩（不删除用户配置，或可安全复位）。
    func resetOnLogout() {
        isLocked = false
        failedAttempts = 0
        cooldownUntil = nil
    }

    /// 立即锁定客户端。
    func lockNow() {
        guard isEnabled else { return }
        SessionService.shared.releasePressedInput()
        isLocked = true
    }

    /// 使用密码尝试解锁（含连续 5 次错误后的防爆破冷却退避）。
    func unlock(password: String, now: Date = .now) -> Result<Void, RCUiError> {
        if let cooldownUntil, now < cooldownUntil {
            let secs = max(1, Int(ceil(cooldownUntil.timeIntervalSince(now))))
            return .failure(CoreClient.resolveUiError(
                code: RCErrorCodes.networkRateLimited,
                detail: "尝试次数过多，请在 \(secs) 秒后重试。"
            ))
        }
        if verifyPassword(password) {
            isLocked = false
            failedAttempts = 0
            cooldownUntil = nil
            return .success(())
        }
        failedAttempts += 1
        if failedAttempts >= 5 {
            let penalty = min(60, 5 * (1 << min(3, failedAttempts - 5)))
            cooldownUntil = now.addingTimeInterval(TimeInterval(penalty))
            return .failure(CoreClient.resolveUiError(
                code: RCErrorCodes.networkRateLimited,
                detail: "应用锁密码错误，已进入 \(penalty) 秒保护冷却。"
            ))
        }
        return .failure(CoreClient.resolveUiError(
            code: RCErrorCodes.authInvalidCredentials,
            detail: "应用锁密码错误（已失败 \(failedAttempts)/5 次）。"
        ))
    }

    /// 调用系统 Face ID / Touch ID 解锁。
    func unlockWithBiometrics() async -> Bool {
        guard isEnabled, isLocked, biometricsEnabled else { return !isLocked }
        let context = LAContext()
        context.localizedCancelTitle = "输入密码解锁"
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return false
        }
        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: "解锁 RabbitControl 以继续访问设备与远程会话"
            )
            if success {
                isLocked = false
                failedAttempts = 0
                cooldownUntil = nil
            }
            return success
        } catch {
            return false
        }
    }

    /// 响应 App 前后台切换，按用户设定的超时策略自动上锁。
    func handleScenePhase(_ phase: ScenePhase, now: Date = .now) {
        guard isEnabled else { return }
        switch phase {
        case .background:
            backgroundedAt = now
            if autoLockDelay == .immediately {
                lockNow()
            }
        case .active:
            if let bgAt = backgroundedAt {
                let elapsed = now.timeIntervalSince(bgAt)
                backgroundedAt = nil
                if elapsed >= TimeInterval(autoLockDelay.rawValue) {
                    lockNow()
                }
            }
        case .inactive:
            break
        @unknown default:
            break
        }
    }

    // MARK: - 摘要与常量时间比对

    private func verifyPassword(_ candidate: String) -> Bool {
        guard let data = try? keychain.load(),
              let stored = try? JSONDecoder().decode(StoredVerifier.self, from: data) else {
            return false
        }
        let cleaned = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        let computed = Self.computeDigestHex(password: cleaned, saltHex: stored.saltHex)
        return Self.constantTimeEqual(computed, stored.digestHex)
    }

    nonisolated private static func makeVerifier(password: String) -> StoredVerifier {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let saltHex = bytes.map { String(format: "%02x", $0) }.joined()
        let digestHex = computeDigestHex(password: password, saltHex: saltHex)
        return StoredVerifier(saltHex: saltHex, digestHex: digestHex)
    }

    nonisolated static func computeDigestHex(password: String, saltHex: String) -> String {
        var input = Data("rc-ios-applock-v1:\(saltHex):".utf8)
        input.append(Data(password.utf8))
        var hash = SHA256.hash(data: input)
        // 迭代 4096 轮增强轻量抗离线字典能力
        for _ in 0..<4096 {
            var roundData = Data(hash)
            roundData.append(Data(saltHex.utf8))
            hash = SHA256.hash(data: roundData)
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let lhs = Array(a.utf8)
        let rhs = Array(b.utf8)
        guard lhs.count == rhs.count else { return false }
        var diff: UInt8 = 0
        for i in lhs.indices {
            diff |= lhs[i] ^ rhs[i]
        }
        return diff == 0
    }
}
