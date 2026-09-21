import Foundation

public enum ProviderID: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case zhipu, openai, deepl, groq, google, cerebras, together, ollama, custom

    public var id: String { rawValue }
}

public enum WireProtocol: Sendable {
    case openAICompatible
    case gemini
    case deepL
    case ollama
}

public struct ProviderDescriptor: Sendable {
    public let id: ProviderID
    public let wire: WireProtocol
    public let chineseName: String
    public let englishName: String
    public let symbol: String
    public let defaultBaseURL: String
    public let defaultModel: String
    public let fallbackModels: [String]
    public let requiresAPIKey: Bool
    public let supportsModelDiscovery: Bool
    public let editableBaseURL: Bool
    public let keyURL: URL?
    public let chineseNote: String
    public let englishNote: String
    /// Seconds to wait for the first token before failing over.
    public let firstTokenTimeout: TimeInterval

    public var displayName: String { tr(chineseName, englishName) }
    public var note: String { tr(chineseNote, englishNote) }
}

public enum ProviderCatalog {
    public static func descriptor(for id: ProviderID) -> ProviderDescriptor {
        switch id {
        case .zhipu:
            return ProviderDescriptor(
                id: id, wire: .openAICompatible, chineseName: "智谱 GLM", englishName: "Zhipu GLM",
                symbol: "sparkles", defaultBaseURL: "https://open.bigmodel.cn/api/paas/v4",
                defaultModel: "glm-4-flash-250414",
                fallbackModels: ["glm-4-flash-250414", "glm-4.7-flash"],
                requiresAPIKey: true, supportsModelDiscovery: true, editableBaseURL: false,
                keyURL: URL(string: "https://open.bigmodel.cn/usercenter/apikeys"),
                chineseNote: "默认推荐，提供免费模型，仍需申请自己的 API Key。",
                englishNote: "Recommended default. Offers a free model; you still need your own API key.",
                firstTokenTimeout: 10
            )
        case .openai:
            return ProviderDescriptor(
                id: id, wire: .openAICompatible, chineseName: "OpenAI", englishName: "OpenAI",
                symbol: "brain.head.profile", defaultBaseURL: "https://api.openai.com/v1",
                defaultModel: "gpt-4.1-mini",
                fallbackModels: ["gpt-4.1-mini", "gpt-4.1", "gpt-5-mini"],
                requiresAPIKey: true, supportsModelDiscovery: true, editableBaseURL: false,
                keyURL: URL(string: "https://platform.openai.com/api-keys"),
                chineseNote: "API 计费与 ChatGPT 订阅相互独立。",
                englishNote: "API billing is separate from a ChatGPT subscription.",
                firstTokenTimeout: 10
            )
        case .deepl:
            return ProviderDescriptor(
                id: id, wire: .deepL, chineseName: "DeepL", englishName: "DeepL",
                symbol: "character.book.closed", defaultBaseURL: "",
                defaultModel: "", fallbackModels: [],
                requiresAPIKey: true, supportsModelDiscovery: false, editableBaseURL: false,
                keyURL: URL(string: "https://www.deepl.com/pro-api"),
                chineseNote: "专用翻译接口，免费版每月有固定额度，自动识别 Free / Pro。",
                englishNote: "Dedicated translation API with a monthly free quota. Free / Pro is detected automatically.",
                firstTokenTimeout: 10
            )
        case .groq:
            return ProviderDescriptor(
                id: id, wire: .openAICompatible, chineseName: "Groq", englishName: "Groq",
                symbol: "bolt.horizontal.circle", defaultBaseURL: "https://api.groq.com/openai/v1",
                defaultModel: "qwen/qwen3.8-27b",
                fallbackModels: ["qwen/qwen3.8-27b", "openai/gpt-oss-20b", "openai/gpt-oss-120b"],
                requiresAPIKey: true, supportsModelDiscovery: true, editableBaseURL: false,
                keyURL: URL(string: "https://console.groq.com/keys"),
                chineseNote: "推理速度很快，免费层有每分钟与每日请求上限。",
                englishNote: "Very fast inference. The free tier has per-minute and per-day request limits.",
                firstTokenTimeout: 6
            )
        case .google:
            return ProviderDescriptor(
                id: id, wire: .gemini, chineseName: "Google AI", englishName: "Google AI",
                symbol: "g.circle", defaultBaseURL: "https://generativelanguage.googleapis.com/v1beta",
                defaultModel: "gemini-3.5-flash-lite",
                fallbackModels: ["gemini-3.5-flash-lite", "gemini-2.5-flash-lite", "gemini-2.5-flash"],
                requiresAPIKey: true, supportsModelDiscovery: true, editableBaseURL: false,
                keyURL: URL(string: "https://aistudio.google.com/apikey"),
                chineseNote: "Gemini 模型，使用 Google AI Studio 的 API Key。",
                englishNote: "Gemini models, using a Google AI Studio API key.",
                firstTokenTimeout: 10
            )
        case .cerebras:
            return ProviderDescriptor(
                id: id, wire: .openAICompatible, chineseName: "Cerebras", englishName: "Cerebras",
                symbol: "cpu", defaultBaseURL: "https://api.cerebras.ai/v1",
                defaultModel: "llama3.1-8b",
                fallbackModels: ["llama3.1-8b"],
                requiresAPIKey: true, supportsModelDiscovery: true, editableBaseURL: false,
                keyURL: URL(string: "https://cloud.cerebras.ai"),
                chineseNote: "速度极快，免费层按 token 计每日额度。可作为故障转移的备用服务。",
                englishNote: "Extremely fast; the free tier has a daily token allowance. A good failover backup.",
                firstTokenTimeout: 6
            )
        case .together:
            return ProviderDescriptor(
                id: id, wire: .openAICompatible, chineseName: "Together AI", englishName: "Together AI",
                symbol: "person.2", defaultBaseURL: "https://api.together.xyz/v1",
                defaultModel: "meta-llama/Llama-3.3-70B-Instruct-Turbo",
                fallbackModels: ["meta-llama/Llama-3.3-70B-Instruct-Turbo"],
                requiresAPIKey: true, supportsModelDiscovery: true, editableBaseURL: false,
                keyURL: URL(string: "https://api.together.ai/settings/api-keys"),
                chineseNote: "开源模型托管，免费额度与可用模型经常调整，请以「读取可用模型」为准。",
                englishNote: "Hosted open models. Free quota and models change often; use “Load Available Models”.",
                firstTokenTimeout: 8
            )
        case .ollama:
            return ProviderDescriptor(
                id: id, wire: .ollama, chineseName: "本地模型 (Ollama)", englishName: "Ollama (Local)",
                symbol: "desktopcomputer", defaultBaseURL: "http://localhost:11434",
                defaultModel: "qwen3:8b", fallbackModels: ["qwen3:8b"],
                requiresAPIKey: false, supportsModelDiscovery: true, editableBaseURL: true,
                keyURL: URL(string: "https://ollama.com"),
                chineseNote: "完全离线、免费，需要先在本机安装 Ollama 并拉取模型。",
                englishNote: "Fully offline and free. Install Ollama and pull a model first.",
                firstTokenTimeout: 45
            )
        case .custom:
            return ProviderDescriptor(
                id: id, wire: .openAICompatible, chineseName: "自定义端点", englishName: "Custom Endpoint",
                symbol: "server.rack", defaultBaseURL: "",
                defaultModel: "", fallbackModels: [],
                requiresAPIKey: false, supportsModelDiscovery: true, editableBaseURL: true,
                keyURL: nil,
                chineseNote: "任何兼容 /chat/completions 的服务，例如 OpenRouter、SiliconFlow、LM Studio。",
                englishNote: "Any service compatible with /chat/completions, e.g. OpenRouter, SiliconFlow, LM Studio.",
                firstTokenTimeout: 10
            )
        }
    }

    public static var all: [ProviderDescriptor] { ProviderID.allCases.map(descriptor(for:)) }
}
