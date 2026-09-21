import Foundation

public enum RouterEvent: Sendable {
    case attempting(ProviderID)
    case token(String)
    case fellBack(from: ProviderID, error: TranslationError, next: ProviderID?)
    case completed(ProviderID)
}

public final class TranslationRouter: Sendable {
    public typealias BackendLookup = @Sendable (ProviderID) -> TranslationBackend?

    private let backend: BackendLookup
    private let health: ProviderHealth

    public init(health: ProviderHealth, backend: @escaping BackendLookup) {
        self.health = health
        self.backend = backend
    }

    /// Tries each service in `plan` until one produces a translation.
    /// A service is abandoned when it errors or produces no first token within
    /// its timeout. Once text has started streaming the router never switches,
    /// so a translation is never stitched together from two services.
    public func translate(
        _ request: TranslationRequest,
        plan: [ProviderID],
        firstTokenTimeout: @escaping @Sendable (ProviderID) -> TimeInterval
    ) -> AsyncThrowingStream<RouterEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [health, backend] in
                var failures: [TranslationError] = []
                for (index, id) in plan.enumerated() {
                    if Task.isCancelled { continuation.finish(throwing: CancellationError()); return }
                    guard let service = backend(id) else {
                        failures.append(TranslationError(provider: id, .invalidConfiguration))
                        continue
                    }
                    continuation.yield(.attempting(id))
                    var receivedToken = false
                    do {
                        let stream = Self.withFirstTokenTimeout(
                            service.translate(request), seconds: firstTokenTimeout(id), provider: id
                        )
                        for try await token in stream {
                            receivedToken = true
                            continuation.yield(.token(token))
                        }
                        guard receivedToken else { throw TranslationError(provider: id, .emptyResponse) }
                        health.recordSuccess(id)
                        continuation.yield(.completed(id))
                        continuation.finish()
                        return
                    } catch {
                        if Task.isCancelled || error is CancellationError {
                            continuation.finish(throwing: CancellationError())
                            return
                        }
                        let wrapped = TranslationError.wrap(error, provider: id)
                        health.recordFailure(id, wrapped)
                        if receivedToken {
                            continuation.finish(throwing: wrapped)
                            return
                        }
                        failures.append(wrapped)
                        let next = plan[(index + 1)...].first
                        continuation.yield(.fellBack(from: id, error: wrapped, next: next))
                    }
                }
                if failures.isEmpty {
                    continuation.finish(throwing: TranslationError(provider: nil, .missingCredentials))
                } else {
                    continuation.finish(throwing: TranslationError.exhausted(failures))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Fails with `.timeout` when the source yields nothing within `seconds`.
    static func withFirstTokenTimeout(
        _ source: AsyncThrowingStream<String, Error>, seconds: TimeInterval, provider: ProviderID
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let flag = FirstTokenFlag()
            let pump = Task {
                do {
                    for try await token in source {
                        flag.markReceived()
                        continuation.yield(token)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            let watchdog = Task {
                try? await Task.sleep(nanoseconds: UInt64(max(seconds, 0.01) * 1_000_000_000))
                guard !Task.isCancelled, !flag.received else { return }
                pump.cancel()
                continuation.finish(throwing: TranslationError(provider: provider, .timeout))
            }
            continuation.onTermination = { _ in
                pump.cancel()
                watchdog.cancel()
            }
        }
    }
}

private final class FirstTokenFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var received: Bool { lock.withLock { value } }
    func markReceived() { lock.withLock { value = true } }
}

/// Glue between settings, secrets and the router. One instance lives for the
/// whole app so cooldown state survives between translations.
public final class TranslationService: Sendable {
    public let health = ProviderHealth()
    private let secrets: SecretStoring

    public init(secrets: SecretStoring) { self.secrets = secrets }

    public func plan(settings: TranslationSettings, selected: ProviderID) -> [ProviderID] {
        RoutingPlanner.plan(
            settings: settings, selected: selected,
            available: settings.availableProviders(secrets: secrets), health: health
        )
    }

    public func translate(
        text: String, targetLanguageCode: String, settings: TranslationSettings, selected: ProviderID
    ) -> AsyncThrowingStream<RouterEvent, Error> {
        let request = TranslationRequest(
            text: text,
            targetLanguageCode: targetLanguageCode,
            systemPrompt: PromptBuilder.systemPrompt(base: settings.systemPrompt, targetLanguageCode: targetLanguageCode)
        )
        let factory = BackendFactory(settings: settings, secrets: secrets)
        let router = TranslationRouter(health: health) { factory.backend(for: $0) }
        let override = settings.failover.firstTokenTimeoutOverride
        return router.translate(request, plan: plan(settings: settings, selected: selected)) { id in
            let base = ProviderCatalog.descriptor(for: id).firstTokenTimeout
            // The override never shortens a local model's cold-start allowance.
            if let override, id != .ollama { return override }
            return base
        }
    }
}
