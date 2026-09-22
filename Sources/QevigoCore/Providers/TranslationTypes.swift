import Foundation

public struct TranslationRequest: Sendable {
    public var text: String
    public var targetLanguageCode: String
    /// Complete system prompt including the per-request direction.
    public var systemPrompt: String

    public init(text: String, targetLanguageCode: String, systemPrompt: String) {
        self.text = text
        self.targetLanguageCode = targetLanguageCode
        self.systemPrompt = systemPrompt
    }
}

public protocol TranslationBackend: Sendable {
    var provider: ProviderID { get }
    /// Emits translated text fragments. Non-streaming services emit once.
    func translate(_ request: TranslationRequest) -> AsyncThrowingStream<String, Error>
}

public enum TranslationFailure: Equatable, Sendable {
    case missingCredentials
    case unauthorized
    case rateLimited(retryAfter: TimeInterval?)
    case quotaExceeded
    case paymentRequired
    case timeout
    case network
    case server(Int)
    case badRequest
    case unsupportedLanguage
    case emptyResponse
    case garbled
    case invalidConfiguration
    case allFailed
    case other
}

public struct TranslationError: Error, LocalizedError, Equatable, Sendable {
    public let provider: ProviderID?
    public let failure: TranslationFailure
    public let detail: String?

    public init(provider: ProviderID?, _ failure: TranslationFailure, detail: String? = nil) {
        self.provider = provider
        self.failure = failure
        self.detail = detail
    }

    public var errorDescription: String? { message }

    public var reason: String {
        switch failure {
        case .missingCredentials: return tr("尚未配置 API Key", "API key is not configured")
        case .unauthorized: return tr("API Key 无效或权限不足", "API key is invalid or lacks permission")
        case .rateLimited: return tr("请求过于频繁或额度已用尽 (429)", "Rate limited or quota used up (429)")
        case .quotaExceeded: return tr("额度已用完", "Quota exceeded")
        case .paymentRequired: return tr("需要开通付费或账户未激活，请到服务商控制台的账单页面查看", "Payment required or account not activated; check the provider's billing page")
        case .timeout: return tr("响应超时", "Timed out")
        case .network: return tr("网络连接失败", "Network connection failed")
        case .server(let code): return tr("服务端错误 (HTTP \(code))", "Server error (HTTP \(code))")
        case .badRequest: return tr("请求被拒绝，请检查模型名称", "Request rejected; check the model name")
        case .unsupportedLanguage: return tr("不支持该语言", "Language not supported")
        case .emptyResponse: return tr("没有返回译文", "No translation returned")
        case .garbled: return tr("返回结果异常", "Returned an abnormal result")
        case .invalidConfiguration: return tr("服务配置不完整", "Service configuration is incomplete")
        case .allFailed: return tr("所有服务都失败了", "All services failed")
        case .other: return tr("请求失败", "Request failed")
        }
    }

    public var message: String {
        var text = reason
        if let provider {
            text = ProviderCatalog.descriptor(for: provider).displayName + ": " + text
        }
        if let detail, !detail.isEmpty, failure != .allFailed { text += " — " + detail }
        if failure == .allFailed, let detail { text += "\n" + detail }
        return text
    }

    /// How long the router should avoid this provider after this failure.
    public var cooldown: TimeInterval {
        switch failure {
        case .rateLimited(let retryAfter): return min(max(retryAfter ?? 60, 10), 600)
        case .quotaExceeded, .paymentRequired: return 3600
        case .unauthorized, .missingCredentials: return 900
        case .badRequest, .invalidConfiguration: return 300
        case .timeout, .server, .emptyResponse: return 30
        case .network: return 15
        case .unsupportedLanguage, .garbled, .allFailed, .other: return 0
        }
    }

    static func wrap(_ error: Error, provider: ProviderID) -> TranslationError {
        if let error = error as? TranslationError {
            return error.provider == nil
                ? TranslationError(provider: provider, error.failure, detail: error.detail)
                : error
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut: return TranslationError(provider: provider, .timeout)
            default: return TranslationError(provider: provider, .network, detail: urlError.localizedDescription)
            }
        }
        return TranslationError(provider: provider, .other, detail: error.localizedDescription)
    }

    static func exhausted(_ failures: [TranslationError]) -> TranslationError {
        if failures.count == 1, let only = failures.first { return only }
        let summary = failures.map(\.message).joined(separator: "\n")
        return TranslationError(provider: nil, .allFailed, detail: summary)
    }
}
