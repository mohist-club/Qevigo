import Foundation

/// Shared driver for line-oriented streaming responses.
private func streamingTranslation(
    provider: ProviderID,
    makeRequest: @escaping @Sendable () throws -> URLRequest,
    decode: @escaping @Sendable (String) -> StreamLine.Event,
    filterThinking: Bool
) -> AsyncThrowingStream<String, Error> {
    AsyncThrowingStream { continuation in
        let task = Task {
            do {
                let lines = try await HTTP.lines(for: try makeRequest(), provider: provider)
                var filter = ThinkTagFilter()
                var emitted = false
                loop: for try await line in lines {
                    switch decode(line) {
                    case .content(let text):
                        let clean = filterThinking ? filter.push(text) : text
                        if !clean.isEmpty {
                            emitted = true
                            continuation.yield(clean)
                        }
                    case .failure(let message):
                        throw TranslationError(provider: provider, .other, detail: message)
                    case .done:
                        break loop
                    case .ignore:
                        continue
                    }
                }
                if filterThinking {
                    let tail = filter.finish()
                    if !tail.isEmpty {
                        emitted = true
                        continuation.yield(tail)
                    }
                }
                guard emitted else { throw TranslationError(provider: provider, .emptyResponse) }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
    }
}

private func jsonBody(_ object: [String: Any]) -> Data? {
    try? JSONSerialization.data(withJSONObject: object)
}

/// OpenAI, Zhipu, Groq, Cerebras, Together and any custom `/chat/completions` service.
public struct OpenAICompatibleBackend: TranslationBackend {
    public let provider: ProviderID
    let baseURL: String
    let model: String
    let apiKey: String

    public init(provider: ProviderID, baseURL: String, model: String, apiKey: String) {
        self.provider = provider
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
    }

    func urlRequest(for request: TranslationRequest) throws -> URLRequest {
        guard let url = HTTP.endpoint(baseURL, path: "/chat/completions") else {
            throw TranslationError(provider: provider, .invalidConfiguration)
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if !apiKey.isEmpty {
            urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        var body: [String: Any] = [
            "model": model,
            "stream": true,
            "temperature": 0.2,
            "messages": [
                ["role": "system", "content": request.systemPrompt],
                ["role": "user", "content": request.text]
            ]
        ]
        // GPT-5 models reason before answering; translation does not need it.
        if provider == .openai, model.hasPrefix("gpt-5") {
            body["reasoning_effort"] = "minimal"
        }
        urlRequest.httpBody = jsonBody(body)
        return urlRequest
    }

    public func translate(_ request: TranslationRequest) -> AsyncThrowingStream<String, Error> {
        streamingTranslation(
            provider: provider,
            makeRequest: { try urlRequest(for: request) },
            decode: { StreamLine.openAI($0) },
            filterThinking: true
        )
    }
}

public struct GeminiBackend: TranslationBackend {
    public let provider = ProviderID.google
    let baseURL: String
    let model: String
    let apiKey: String

    public init(baseURL: String, model: String, apiKey: String) {
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
    }

    func urlRequest(for request: TranslationRequest) throws -> URLRequest {
        guard let url = HTTP.endpoint(baseURL, path: "/models/\(model):streamGenerateContent?alt=sse") else {
            throw TranslationError(provider: provider, .invalidConfiguration)
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        urlRequest.httpBody = jsonBody([
            "systemInstruction": ["parts": [["text": request.systemPrompt]]],
            "contents": [["role": "user", "parts": [["text": request.text]]]],
            "generationConfig": ["temperature": 0.2]
        ])
        return urlRequest
    }

    public func translate(_ request: TranslationRequest) -> AsyncThrowingStream<String, Error> {
        streamingTranslation(
            provider: provider,
            makeRequest: { try urlRequest(for: request) },
            decode: { StreamLine.gemini($0) },
            filterThinking: false
        )
    }
}

public struct OllamaBackend: TranslationBackend {
    public let provider = ProviderID.ollama
    let baseURL: String
    let model: String

    public init(baseURL: String, model: String) {
        self.baseURL = baseURL
        self.model = model
    }

    func urlRequest(for request: TranslationRequest) throws -> URLRequest {
        guard let url = HTTP.endpoint(baseURL, path: "/api/chat") else {
            throw TranslationError(provider: provider, .invalidConfiguration)
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.timeoutInterval = 120
        urlRequest.httpBody = jsonBody([
            "model": model,
            "stream": true,
            "think": false,
            "messages": [
                ["role": "system", "content": request.systemPrompt],
                ["role": "user", "content": request.text]
            ]
        ])
        return urlRequest
    }

    public func translate(_ request: TranslationRequest) -> AsyncThrowingStream<String, Error> {
        streamingTranslation(
            provider: provider,
            makeRequest: { try urlRequest(for: request) },
            decode: { StreamLine.ollama($0) },
            filterThinking: true
        )
    }
}

public struct DeepLBackend: TranslationBackend {
    public let provider = ProviderID.deepl
    let apiKey: String

    public init(apiKey: String) { self.apiKey = apiKey }

    static func looksLikeGarbage(_ text: String) -> Bool {
        var last: Character?
        var run = 0
        for character in text where !character.isWhitespace {
            if character == last {
                run += 1
                if run >= 8 { return true }
            } else {
                last = character
                run = 1
            }
        }
        return false
    }

    public func translate(_ request: TranslationRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard Languages.deepLTargets.contains(request.targetLanguageCode) else {
                        throw TranslationError(
                            provider: provider, .unsupportedLanguage,
                            detail: Languages.name(for: request.targetLanguageCode)
                        )
                    }
                    // Free keys always end with ":fx".
                    let host = apiKey.hasSuffix(":fx") ? "api-free.deepl.com" : "api.deepl.com"
                    guard let url = URL(string: "https://\(host)/v2/translate") else {
                        throw TranslationError(provider: provider, .invalidConfiguration)
                    }
                    var urlRequest = URLRequest(url: url)
                    urlRequest.httpMethod = "POST"
                    urlRequest.timeoutInterval = 20
                    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    urlRequest.setValue("DeepL-Auth-Key \(apiKey)", forHTTPHeaderField: "Authorization")
                    urlRequest.httpBody = jsonBody(["text": [request.text], "target_lang": request.targetLanguageCode])

                    let data = try await HTTP.data(for: urlRequest, provider: provider)
                    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let translations = json["translations"] as? [[String: Any]],
                          let text = translations.first?["text"] as? String, !text.isEmpty else {
                        throw TranslationError(provider: provider, .emptyResponse)
                    }
                    // DeepL sometimes answers with one repeated character when it
                    // cannot recognise the source language.
                    guard !Self.looksLikeGarbage(text) else {
                        throw TranslationError(provider: provider, .garbled)
                    }
                    continuation.yield(text)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

public struct BackendFactory: Sendable {
    let settings: TranslationSettings
    let secrets: SecretStoring

    public init(settings: TranslationSettings, secrets: SecretStoring) {
        self.settings = settings
        self.secrets = secrets
    }

    public func backend(for id: ProviderID) -> TranslationBackend? {
        guard settings.hasRequiredConfiguration(id, secrets: secrets) else { return nil }
        let descriptor = ProviderCatalog.descriptor(for: id)
        let key = secrets.secret(for: id)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch descriptor.wire {
        case .openAICompatible:
            return OpenAICompatibleBackend(
                provider: id, baseURL: settings.baseURL(for: id), model: settings.model(for: id), apiKey: key
            )
        case .gemini:
            return GeminiBackend(baseURL: settings.baseURL(for: id), model: settings.model(for: id), apiKey: key)
        case .deepL:
            return DeepLBackend(apiKey: key)
        case .ollama:
            return OllamaBackend(baseURL: settings.baseURL(for: id), model: settings.model(for: id))
        }
    }
}
