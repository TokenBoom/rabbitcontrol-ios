import Foundation
import Security
import Testing
@testable import RabbitControlIOS

struct CoreV020SyncTests {

    @Test("核心版本与 CoreBuildInfo ABI 元数据对齐 v0.2.2 / ABI v2")
    func coreVersionAndBuildInfoRoundtrip() throws {
        let ver = CoreClient.coreVersion
        #expect(!ver.isEmpty && ver != "unknown" && ver != "0.1.0")

        let info = try #require(CoreClient.buildInfo)
        #expect(info.coreVersion == ver)
        #expect(!info.gitCommit.isEmpty)
        #expect(!info.buildTimestamp.isEmpty)
        #expect(info.abiVersion >= 2)
        #expect(info.sessionProtocolVersion >= 1)
    }

    @Test("rc_ui_error_resolve 与 RCUiErrorCodec 解析标准码、wire 别名与原生系统错误")
    func uiErrorResolveAndCodecNormalization() {
        let tokenReuse = CoreClient.resolveUiError(code: RCErrorCodes.authTokenReuseDetected)
        #expect(tokenReuse.code == RCErrorCodes.authTokenReuseDetected)
        #expect(tokenReuse.suggestion.contains("钥匙串"))
        #expect(tokenReuse.action == .relogin)

        let aliased = CoreClient.resolveUiError(code: "wrong_password")
        #expect(aliased.code == RCErrorCodes.authInvalidCredentials)

        let unknown = CoreClient.resolveUiError(code: "nonexistent.future_code", detail: "diag-1")
        #expect(unknown.code == RCErrorCodes.commonUnknown)
        #expect(unknown.detail == "diag-1")

        let keychainErr = NSError(domain: NSOSStatusErrorDomain, code: Int(errSecAuthFailed))
        let mappedKeychain = RCUiErrorCodec.fromError(keychainErr)
        #expect(mappedKeychain.code == RCErrorCodes.platformIosKeychainError)

        let timeoutErr = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        let mappedTimeout = RCUiErrorCodec.fromError(timeoutErr)
        #expect(mappedTimeout.code == RCErrorCodes.networkTimeout)

        let snakeEnvelope: [String: Any] = [
            "error": "forbidden",
            "kind": "other",
            "ui_error": [
                "code": "tool_forbidden",
                "title": "权限受限",
                "message": "目标设备已禁用文件传输",
                "suggestion": "请在被控端开启权限",
                "severity": "warning",
                "presentation": "banner",
                "action": "none",
                "retryable": false,
            ],
        ]
        let parsedSnake = RCUiErrorCodec.extractEnvelopeError(from: snakeEnvelope)
        #expect(parsedSnake?.code == RCErrorCodes.toolForbidden)
        #expect(parsedSnake?.presentation == .banner)
    }

    @Test("RCErrorCenter 四级错误路由正确驱动 Toast / Banner / Modal")
    @MainActor
    func errorCenterRoutesAllPresentationLevels() {
        let center = RCErrorCenter.shared
        defer {
            center.dismissBanner()
            center.dismissModal()
        }

        let bannerErr = RCUiError(
            code: RCErrorCodes.networkUnreachable,
            title: "网络不可达",
            message: "无法连接信令服务",
            suggestion: "请检查网络设置",
            severity: .warning,
            presentation: .banner,
            action: .openSettings,
            retryable: true
        )
        center.present(bannerErr)
        #expect(center.banner?.error.code == RCErrorCodes.networkUnreachable)
        center.dismissBanner()
        #expect(center.banner == nil)

        let modalErr = RCUiError(
            code: RCErrorCodes.accountDisabled,
            title: "账号已禁用",
            message: "当前账号已被管理员停用",
            suggestion: "请联系管理员",
            severity: .critical,
            presentation: .modal,
            action: .contactAdmin,
            retryable: false
        )
        center.present(modalErr)
        #expect(center.modal?.error.code == RCErrorCodes.accountDisabled)
        center.dismissModal()
        #expect(center.modal == nil)
    }

    @Test("工具通道权限门控：关闭 allow_file_transfer 时立即收口目录加载并上报 tool.forbidden")
    @MainActor
    func toolPermissionsGateRevokesFileTransfer() throws {
        let session = SessionService.shared
        let tools = ToolService.shared
        defer { session.close() }

        let decoded = try #require(SessionService.ToolPermissions.decode(from: [
            "allow_file_transfer": false,
            "allow_terminal": true,
            "allow_port_map": false,
        ]))
        #expect(!decoded.allowFileTransfer)
        #expect(decoded.allowTerminal)
        #expect(!decoded.allowPortMap)

        session.applyToolPermissions(decoded)
        #expect(!session.toolPermissions.allowFileTransfer)
        #expect(tools.fileUiError?.code == RCErrorCodes.toolForbidden)
        #expect(SessionService.queryToolPermissions(sessionID: UInt64.max) == nil)
    }

    @Test("AV1 编解码解析与非对称硬件解码能力 fail-closed 校验")
    func av1CodecCapabilityAndFailClosedReconciliation() throws {
        #expect(VideoCodec.parse("av1") == .av1)
        #expect(VideoCodec.parse("AV01") == .av1)

        let payload: [String: Any] = [
            "width": 2560,
            "height": 1440,
            "fps": 60,
            "max_fps": 120,
            "presets": [],
            "codec": "hevc",
            "supported_codecs": ["h264", "hevc", "av1"],
            "client_supports_hevc": true,
        ]

        // 本机支持 AV1 硬解（如 A17 Pro+）时解锁 AV1 选项
        let av1Ready = try #require(SessionService.DisplayConfig.decode(from: payload, clientSupportsAv1: true))
        #expect(av1Ready.canUseAv1)
        #expect(av1Ready.selectableCodecs == [.av1, .hevc, .h264])
        #expect(SessionService.evaluateCodecReconciliation(
            display: av1Ready, preferred: .av1, userSelected: nil,
            didAutoAlign: false, negotiatedElapsed: 1.2
        ) == .send(.av1))

        // 本机不支持 AV1 硬解时严格 fail-closed 回退至 H.265
        let av1Blocked = try #require(SessionService.DisplayConfig.decode(from: payload, clientSupportsAv1: false))
        #expect(!av1Blocked.canUseAv1)
        #expect(av1Blocked.selectableCodecs == [.hevc, .h264])
        #expect(SessionService.evaluateCodecReconciliation(
            display: av1Blocked, preferred: .av1, userSelected: nil,
            didAutoAlign: false, negotiatedElapsed: 1.2
        ) == .markAligned)
    }

    @Test("出站代理 FFI 校验、密码钥匙串隔离存储与错误脱敏")
    @MainActor
    func outboundProxyValidationAndRedaction() async throws {
        defer {
            _ = ProxyConfigStore.applyToCoreSync(ProxyConfigStore.Config(mode: .none))
        }

        // 合法手动 SOCKS5 配置写入核心成功
        let secret = "Sup3rS3cretProxyPwd!"
        let validManual = ProxyConfigStore.Config(
            mode: .manual,
            proxyProtocol: .socks5,
            host: "127.0.0.1",
            port: 1080,
            username: "corp_user",
            password: secret
        )
        #expect(!String(reflecting: validManual).contains(secret))
        #expect(ProxyConfigStore.applyToCoreSync(validManual) == nil)

        // 非法配置（提供密码但无用户名 / 空主机）返回结构化错误且绝不泄露密码明文
        let invalidManual = ProxyConfigStore.Config(
            mode: .manual,
            proxyProtocol: .http,
            host: "",
            port: 7890,
            username: "",
            password: secret
        )
        let err = try #require(ProxyConfigStore.applyToCoreSync(invalidManual))
        #expect(!err.message.contains(secret))
        #expect(!(err.detail ?? "").contains(secret))

        // 隔离钥匙串与 UserDefaults 验证密码不进 UserDefaults
        let suiteName = "com.rabbitcontrol.test.proxy.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let keychainService = "com.rabbitcontrol.test.proxykc.\(UUID().uuidString)"
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? SessionKeychain(service: keychainService).remove()
        }
        let isolatedStore = ProxyConfigStore(defaults: defaults, keychainService: keychainService)
        try await isolatedStore.apply(validManual)
        #expect(defaults.string(forKey: "proxy.password") == nil)
        let reloaded = ProxyConfigStore(defaults: defaults, keychainService: keychainService)
        #expect(reloaded.config == validManual)
    }

    @Test("AccountDevice wol_capable 与 WolAck / SignalStatus 双命名风格解码")
    func wolAndSignalStatusDecoding() throws {
        let deviceJSON = """
        {
          "device_id": "604928235",
          "formatted_id": "604 928 235",
          "hostname": "office-pc",
          "os": "windows",
          "alias": "办公室台式机",
          "allow_remote_assist": true,
          "allow_remote_control": true,
          "disabled": false,
          "online": false,
          "in_session": false,
          "wol_capable": true
        }
        """.data(using: .utf8)!
        let decodedDevice = try JSONDecoder().decode(AccountDevice.self, from: deviceJSON)
        #expect(decodedDevice.wolCapable)
        #expect(!decodedDevice.online)

        let okAck = try RuntimeService.decodeWolResponse("""
        {"targetDeviceId":"604928235","ok":true,"method":"lan_peer","message":"已通过同局域网节点发送唤醒包"}
        """)
        #expect(okAck.ok)
        #expect(okAck.method == "lan_peer")

        // 服务端返回 camelCase uiError
        #expect(throws: RCUiErrorFailure.self) {
            _ = try RuntimeService.decodeWolResponse("""
            {
              "targetDeviceId": "604928235",
              "ok": false,
              "method": "none",
              "code": "wol_no_relay_peer",
              "message": "无可用局域网唤醒节点",
              "uiError": {
                "code": "wol.no_relay_peer",
                "title": "无法发送唤醒包",
                "message": "未找到同局域网在线辅助节点",
                "suggestion": "请确保同网段至少有一台在线设备",
                "severity": "warning",
                "presentation": "toast",
                "action": "none",
                "retryable": true
              }
            }
            """)
        }

        // 信令状态成功快照（camelCase uiError）与未启动错误信封（snake_case ui_error）区分
        let snapStatus = RuntimeService.interpretSignalStatus([
            "signalState": "reconnecting",
            "uiError": [
                "code": "network.timeout",
                "title": "连接超时",
                "message": "信令重连超时",
                "suggestion": "请检查网络",
                "severity": "warning",
                "presentation": "banner",
                "action": "retry",
                "retryable": true,
            ],
        ])
        #expect(snapStatus.connected == false)
        #expect(snapStatus.uiError?.code == RCErrorCodes.networkTimeout)

        let ffiErrStatus = RuntimeService.interpretSignalStatus([
            "error": "信令未启动",
            "kind": "other",
            "ui_error": [
                "code": "signal.not_started",
                "title": "信令未就绪",
                "message": "账号信令服务尚未启动",
                "suggestion": "请稍候重试",
                "severity": "warning",
                "presentation": "toast",
                "action": "retry",
                "retryable": true,
            ],
        ])
        #expect(ffiErrStatus.connected == false)
        #expect(ffiErrStatus.uiError?.code == RCErrorCodes.signalNotStarted)
    }
}
