import Foundation
import Security

/// 携带规范 `RCUiError` 的可抛出错误包装。
nonisolated struct RCUiErrorFailure: LocalizedError, Equatable, Sendable {
    let uiError: RCUiError

    var errorDescription: String? {
        let msg = uiError.message.trimmingCharacters(in: .whitespacesAndNewlines)
        return msg.isEmpty ? uiError.title : msg
    }

    var recoverySuggestion: String? {
        let sug = uiError.suggestion.trimmingCharacters(in: .whitespacesAndNewlines)
        return sug.isEmpty ? nil : sug
    }
}

/// 统一结构化错误解码与原生系统错误归一化工具。
///
/// 对齐 `rabbitcontrol-spec` v1.0.0 与 `rc-mobile-ffi` 错误信封约定：
/// - 统一 FFI 错误信封与 `SessionUpdate` 使用 snake_case `ui_error`；
/// - `ServerStatusSnapshot` 与 `WolAckResult` 成功载荷内使用 camelCase `uiError`；
/// - 本地 Keychain (`OSStatus`) 与 `URLError` 统一经 `rc_ui_error_resolve` 归一化为 iOS 中文目录。
nonisolated enum RCUiErrorCodec {

    /// 从 JSON 字典解码 `RCUiError`（兼容 wire alias 归一化）。
    static func decode(from dict: [String: Any]?) -> RCUiError? {
        guard let dict,
              let codeRaw = (dict["code"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !codeRaw.isEmpty else {
            return nil
        }
        guard JSONSerialization.isValidJSONObject(dict),
              let data = try? JSONSerialization.data(withJSONObject: dict),
              let decoded = try? JSONDecoder().decode(RCUiError.self, from: data) else {
            return nil
        }
        let canonical = RCErrorCodes.resolveWireAlias(decoded.code) ?? decoded.code
        let title = decoded.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = decoded.message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty || !message.isEmpty else { return nil }
        if canonical == decoded.code && !message.isEmpty {
            return decoded
        }
        return RCUiError(
            code: canonical,
            title: title.isEmpty ? message : title,
            message: message.isEmpty ? title : message,
            suggestion: decoded.suggestion,
            severity: decoded.severity,
            presentation: decoded.presentation,
            action: decoded.action,
            retryable: decoded.retryable,
            status: decoded.status,
            detail: decoded.detail
        )
    }

    /// 从原始 JSON 字符串解码单个 `RCUiError` 对象。
    static func decodeJSON(_ raw: String?) -> RCUiError? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              raw.hasPrefix("{"),
              let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return decode(from: obj)
    }

    /// 从 FFI 响应字典提取错误：优先解码内嵌 `ui_error` / `uiError`，缺失时回退按 `kind`/`code`/`error` 解析目录。
    static func extractEnvelopeError(
        from obj: [String: Any],
        preferCamelCase: Bool = false,
        fallbackCode: String = RCErrorCodes.commonUnknown
    ) -> RCUiError? {
        let primaryKey = preferCamelCase ? "uiError" : "ui_error"
        let secondaryKey = preferCamelCase ? "ui_error" : "uiError"
        if let primary = obj[primaryKey] as? [String: Any], let ui = decode(from: primary) {
            return ui
        }
        if let secondary = obj[secondaryKey] as? [String: Any], let ui = decode(from: secondary) {
            return ui
        }
        guard let rawError = (obj["error"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawError.isEmpty else {
            return nil
        }
        let candidateCode = (obj["code"] as? String)
            ?? (obj["kind"] as? String)
            ?? fallbackCode
        let canonical = RCErrorCodes.resolveWireAlias(candidateCode)
            ?? RCErrorCodes.resolveWireAlias(rawError)
            ?? fallbackCode
        let resolved = CoreClient.resolveUiError(code: canonical, detail: rawError)
        if resolved.code == RCErrorCodes.commonUnknown {
            return RCUiError(
                code: resolved.code,
                title: resolved.title,
                message: rawError,
                suggestion: resolved.suggestion,
                severity: resolved.severity,
                presentation: resolved.presentation,
                action: resolved.action,
                retryable: resolved.retryable,
                status: resolved.status,
                detail: rawError
            )
        }
        return resolved
    }

    /// 从原始 FFI JSON 字符串提取错误信封。
    static func extractEnvelopeError(
        fromRawJSON raw: String?,
        preferCamelCase: Bool = false,
        fallbackCode: String = RCErrorCodes.commonUnknown
    ) -> RCUiError? {
        guard let raw,
              let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return extractEnvelopeError(from: obj, preferCamelCase: preferCamelCase, fallbackCode: fallbackCode)
    }

    /// 将 Swift `Error`（含 Keychain `OSStatus`、`URLError`、`RCUiErrorFailure`）统一转换为 `RCUiError`。
    static func fromError(_ error: any Error, fallbackCode: String = RCErrorCodes.commonUnknown) -> RCUiError {
        if let wrapped = error as? RCUiErrorFailure {
            return wrapped.uiError
        }
        if let ui = error as? RCUiError {
            return ui
        }
        let nsError = error as NSError
        if nsError.domain == NSOSStatusErrorDomain {
            return CoreClient.resolveUiError(
                code: RCErrorCodes.platformIosKeychainError,
                detail: "OSStatus \(nsError.code)"
            )
        }
        if nsError.domain == NSURLErrorDomain {
            let mappedCode: String
            switch nsError.code {
            case NSURLErrorTimedOut:
                mappedCode = RCErrorCodes.networkTimeout
            case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
                mappedCode = RCErrorCodes.networkDnsFailed
            case NSURLErrorCannotConnectToHost:
                mappedCode = RCErrorCodes.networkConnectionRefused
            default:
                mappedCode = RCErrorCodes.networkUnreachable
            }
            return CoreClient.resolveUiError(code: mappedCode, detail: nsError.localizedDescription)
        }
        let detail = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if let inline = decodeJSON(detail) {
            return inline
        }
        return CoreClient.resolveUiError(code: fallbackCode, detail: detail.isEmpty ? nil : detail)
    }
}
