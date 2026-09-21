import Foundation

enum HTTP {
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    /// Sends the request and returns the response body as lines. Non-2xx
    /// responses are converted into a `TranslationError` with the server's message.
    static func lines(
        for request: URLRequest, provider: ProviderID
    ) async throws -> AsyncLineSequence<URLSession.AsyncBytes> {
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw TranslationError(provider: provider, .other)
            }
            guard (200...299).contains(http.statusCode) else {
                var body = Data()
                for try await byte in bytes {
                    body.append(byte)
                    if body.count >= 8192 { break }
                }
                throw error(status: http.statusCode, body: body, response: http, provider: provider)
            }
            return bytes.lines
        } catch let error as TranslationError {
            throw error
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw TranslationError.wrap(error, provider: provider)
        }
    }

    static func data(for request: URLRequest, provider: ProviderID) async throws -> Data {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw TranslationError(provider: provider, .other)
            }
            guard (200...299).contains(http.statusCode) else {
                throw error(status: http.statusCode, body: data, response: http, provider: provider)
            }
            return data
        } catch let error as TranslationError {
            throw error
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw TranslationError.wrap(error, provider: provider)
        }
    }

    static func error(
        status: Int, body: Data, response: HTTPURLResponse?, provider: ProviderID
    ) -> TranslationError {
        let detail = errorMessage(from: body)
        let failure: TranslationFailure
        switch status {
        case 401, 403: failure = .unauthorized
        case 402, 456: failure = .quotaExceeded
        case 429, 529:
            let retry = response?.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            failure = .rateLimited(retryAfter: retry)
        case 408: failure = .timeout
        case 500...599: failure = .server(status)
        case 400, 404, 422: failure = .badRequest
        default: failure = .other
        }
        return TranslationError(provider: provider, failure, detail: detail ?? "HTTP \(status)")
    }

    static func errorMessage(from data: Data) -> String? {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = json["error"] as? [String: Any], let message = error["message"] as? String {
                return message
            }
            if let error = json["error"] as? String { return error }
            if let message = json["message"] as? String { return message }
        }
        if let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty, text.count < 300 {
            return text
        }
        return nil
    }

    static func endpoint(_ base: String, path: String) -> URL? {
        var trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        return URL(string: trimmed + path)
    }
}

/// Pure line decoders, kept separate from networking so they can be tested.
enum StreamLine {
    enum Event: Equatable {
        case content(String)
        case done
        case failure(String)
        case ignore
    }

    static func payload(ofSSE line: String) -> String? {
        guard line.hasPrefix("data:") else { return nil }
        return String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
    }

    static func openAI(_ line: String) -> Event {
        guard let payload = payload(ofSSE: line) else { return .ignore }
        if payload == "[DONE]" { return .done }
        guard let json = object(payload) else { return .ignore }
        if let error = json["error"] as? [String: Any] {
            return .failure(error["message"] as? String ?? "error")
        }
        guard let choices = json["choices"] as? [[String: Any]],
              let delta = choices.first?["delta"] as? [String: Any],
              let content = delta["content"] as? String, !content.isEmpty else { return .ignore }
        return .content(content)
    }

    static func gemini(_ line: String) -> Event {
        guard let payload = payload(ofSSE: line), let json = object(payload) else { return .ignore }
        if let error = json["error"] as? [String: Any] {
            return .failure(error["message"] as? String ?? "error")
        }
        if let feedback = json["promptFeedback"] as? [String: Any], let reason = feedback["blockReason"] as? String {
            return .failure("blocked: \(reason)")
        }
        guard let candidates = json["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else { return .ignore }
        let text = parts.compactMap { $0["text"] as? String }.joined()
        return text.isEmpty ? .ignore : .content(text)
    }

    static func ollama(_ line: String) -> Event {
        guard let json = object(line) else { return .ignore }
        if let error = json["error"] as? String { return .failure(error) }
        if let message = json["message"] as? [String: Any],
           let content = message["content"] as? String, !content.isEmpty {
            return .content(content)
        }
        return (json["done"] as? Bool) == true ? .done : .ignore
    }

    private static func object(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
