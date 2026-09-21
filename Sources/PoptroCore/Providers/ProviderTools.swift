import Foundation

public enum ModelDiscovery {
    /// Lists the models a service offers for the current credentials.
    public static func fetch(
        _ id: ProviderID, settings: TranslationSettings, secrets: SecretStoring
    ) async throws -> [String] {
        let descriptor = ProviderCatalog.descriptor(for: id)
        let key = secrets.secret(for: id)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if descriptor.requiresAPIKey, key.isEmpty {
            throw TranslationError(provider: id, .missingCredentials)
        }
        let base = settings.baseURL(for: id)
        switch descriptor.wire {
        case .deepL:
            return []
        case .ollama:
            guard let url = HTTP.endpoint(base, path: "/api/tags") else {
                throw TranslationError(provider: id, .invalidConfiguration)
            }
            let data = try await HTTP.data(for: URLRequest(url: url), provider: id)
            let models = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["models"] as? [[String: Any]]
            return sorted((models ?? []).compactMap { ($0["name"] as? String) ?? ($0["model"] as? String) })
        case .gemini:
            return try await fetchGemini(base: base, key: key)
        case .openAICompatible:
            guard let url = HTTP.endpoint(base, path: "/models") else {
                throw TranslationError(provider: id, .invalidConfiguration)
            }
            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
            let data = try await HTTP.data(for: request, provider: id)
            let json = try? JSONSerialization.jsonObject(with: data)
            let entries = ((json as? [String: Any])?["data"] as? [[String: Any]]) ?? (json as? [[String: Any]]) ?? []
            let models = entries.compactMap { $0["id"] as? String }.filter { isChatModel($0, provider: id) }
            guard !models.isEmpty else { throw TranslationError(provider: id, .emptyResponse) }
            return sorted(models)
        }
    }

    private static func fetchGemini(base: String, key: String) async throws -> [String] {
        var all: [String] = []
        var pageToken: String?
        repeat {
            var query = "?pageSize=1000"
            if let pageToken { query += "&pageToken=\(pageToken)" }
            guard let url = HTTP.endpoint(base, path: "/models" + query) else {
                throw TranslationError(provider: .google, .invalidConfiguration)
            }
            var request = URLRequest(url: url)
            request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
            let data = try await HTTP.data(for: request, provider: .google)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let models = json["models"] as? [[String: Any]] else {
                throw TranslationError(provider: .google, .emptyResponse)
            }
            for model in models {
                let methods = model["supportedGenerationMethods"] as? [String] ?? []
                guard methods.contains("generateContent") else { continue }
                if let id = model["baseModelId"] as? String, !id.isEmpty {
                    all.append(id)
                } else if let name = model["name"] as? String {
                    all.append(name.replacingOccurrences(of: "models/", with: ""))
                }
            }
            pageToken = json["nextPageToken"] as? String
        } while pageToken != nil
        guard !all.isEmpty else { throw TranslationError(provider: .google, .emptyResponse) }
        return sorted(Array(Set(all)))
    }

    private static func sorted(_ models: [String]) -> [String] {
        models.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    static func isChatModel(_ id: String, provider: ProviderID) -> Bool {
        let value = id.lowercased()
        let blocked = ["embed", "whisper", "tts", "audio", "guard", "moderation", "rerank", "ocr", "image", "vision", "realtime"]
        guard !blocked.contains(where: value.contains) else { return false }
        switch provider {
        case .zhipu: return value.hasPrefix("glm-")
        case .openai: return ["gpt-", "o1", "o3", "o4"].contains(where: value.hasPrefix)
        default: return true
        }
    }
}

public struct BenchmarkResult: Codable, Equatable, Sendable {
    public var provider: ProviderID
    public var model: String
    public var testedAt: Date
    public var firstTokenSeconds: Double?
    public var totalSeconds: Double?
    public var charactersPerSecond: Double?
    public var errorMessage: String?

    public var isSuccessful: Bool { errorMessage == nil && totalSeconds != nil }
}

public enum ProviderBenchmark {
    private static let sample = "Poptro turns selected text into a clear and natural translation with one keyboard shortcut."

    /// Sends a short real translation to one service (no failover) and times it.
    public static func run(
        _ id: ProviderID, settings: TranslationSettings, secrets: SecretStoring
    ) async -> BenchmarkResult {
        let model = id == .deepl ? "DeepL" : settings.model(for: id)
        let started = Date()
        var firstToken: Date?
        var characters = 0
        do {
            guard let backend = BackendFactory(settings: settings, secrets: secrets).backend(for: id) else {
                throw TranslationError(provider: id, .missingCredentials)
            }
            let request = TranslationRequest(
                text: sample, targetLanguageCode: "ZH",
                systemPrompt: PromptBuilder.systemPrompt(base: settings.systemPrompt, targetLanguageCode: "ZH")
            )
            let stream = TranslationRouter.withFirstTokenTimeout(
                backend.translate(request),
                seconds: max(ProviderCatalog.descriptor(for: id).firstTokenTimeout, 15),
                provider: id
            )
            for try await token in stream {
                if firstToken == nil { firstToken = Date() }
                characters += token.count
            }
            let total = max(Date().timeIntervalSince(started), 0.001)
            return BenchmarkResult(
                provider: id, model: model, testedAt: Date(),
                firstTokenSeconds: firstToken.map { $0.timeIntervalSince(started) },
                totalSeconds: total, charactersPerSecond: Double(characters) / total, errorMessage: nil
            )
        } catch {
            let wrapped = TranslationError.wrap(error, provider: id)
            return BenchmarkResult(
                provider: id, model: model, testedAt: Date(),
                firstTokenSeconds: nil, totalSeconds: nil, charactersPerSecond: nil,
                errorMessage: wrapped.reason + (wrapped.detail.map { " — " + $0 } ?? "")
            )
        }
    }
}
