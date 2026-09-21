import XCTest
@testable import PoptroCore

private struct MockBackend: TranslationBackend {
    enum Behavior {
        case tokens([String])
        case fail(TranslationFailure)
        case hang
        case tokensThenFail([String], TranslationFailure)
    }

    let provider: ProviderID
    let behavior: Behavior

    func translate(_ request: TranslationRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                switch behavior {
                case .tokens(let tokens):
                    tokens.forEach { continuation.yield($0) }
                    continuation.finish()
                case .fail(let failure):
                    continuation.finish(throwing: TranslationError(provider: provider, failure))
                case .hang:
                    try? await Task.sleep(nanoseconds: 60_000_000_000)
                    continuation.finish()
                case .tokensThenFail(let tokens, let failure):
                    tokens.forEach { continuation.yield($0) }
                    continuation.finish(throwing: TranslationError(provider: provider, failure))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

final class RouterTests: XCTestCase {
    private let request = TranslationRequest(text: "hello", targetLanguageCode: "ZH", systemPrompt: "")

    private func run(
        _ backends: [ProviderID: MockBackend.Behavior], plan: [ProviderID],
        health: ProviderHealth = ProviderHealth(), timeout: TimeInterval = 5
    ) async -> (text: String, events: [String], error: TranslationError?) {
        let router = TranslationRouter(health: health) { id in
            backends[id].map { MockBackend(provider: id, behavior: $0) }
        }
        var text = ""
        var events: [String] = []
        do {
            for try await event in router.translate(request, plan: plan, firstTokenTimeout: { _ in timeout }) {
                switch event {
                case .attempting(let id): events.append("try:\(id.rawValue)")
                case .token(let token): text += token
                case .fellBack(let from, _, let next): events.append("fallback:\(from.rawValue)->\(next?.rawValue ?? "none")")
                case .completed(let id): events.append("done:\(id.rawValue)")
                }
            }
            return (text, events, nil)
        } catch {
            return (text, events, error as? TranslationError)
        }
    }

    func testFirstProviderSucceedsWithoutFallback() async {
        let result = await run([.groq: .tokens(["你", "好"]), .cerebras: .tokens(["x"])], plan: [.groq, .cerebras])
        XCTAssertEqual(result.text, "你好")
        XCTAssertEqual(result.events, ["try:groq", "done:groq"])
    }

    func testRateLimitFallsBackAndCoolsDownProvider() async {
        let health = ProviderHealth()
        let result = await run(
            [.groq: .fail(.rateLimited(retryAfter: 30)), .cerebras: .tokens(["ok"])],
            plan: [.groq, .cerebras], health: health
        )
        XCTAssertEqual(result.text, "ok")
        XCTAssertEqual(result.events, ["try:groq", "fallback:groq->cerebras", "try:cerebras", "done:cerebras"])
        XCTAssertTrue(health.isCoolingDown(.groq))
        XCTAssertFalse(health.isCoolingDown(.cerebras))
    }

    func testHangingProviderTimesOutAndFallsBack() async {
        let started = Date()
        let result = await run(
            [.groq: .hang, .together: .tokens(["fast"])], plan: [.groq, .together], timeout: 0.2
        )
        XCTAssertEqual(result.text, "fast")
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        XCTAssertTrue(result.events.contains("fallback:groq->together"))
    }

    func testMidStreamFailureDoesNotFailOver() async {
        let result = await run(
            [.groq: .tokensThenFail(["par"], .network), .cerebras: .tokens(["other"])], plan: [.groq, .cerebras]
        )
        XCTAssertEqual(result.text, "par")
        XCTAssertEqual(result.error?.failure, .network)
        XCTAssertFalse(result.events.contains("try:cerebras"))
    }

    func testAllFailedReportsEveryProvider() async {
        let result = await run(
            [.groq: .fail(.unauthorized), .cerebras: .fail(.timeout)], plan: [.groq, .cerebras]
        )
        XCTAssertEqual(result.error?.failure, .allFailed)
        XCTAssertTrue(result.error?.detail?.contains("Groq") ?? false)
        XCTAssertTrue(result.error?.detail?.contains("Cerebras") ?? false)
    }

    func testSingleProviderFailureSurfacesOriginalError() async {
        let result = await run([.groq: .fail(.unauthorized)], plan: [.groq])
        XCTAssertEqual(result.error?.failure, .unauthorized)
        XCTAssertEqual(result.error?.provider, .groq)
    }

    func testEmptyResponseCountsAsFailure() async {
        let result = await run([.groq: .tokens([]), .cerebras: .tokens(["ok"])], plan: [.groq, .cerebras])
        XCTAssertEqual(result.text, "ok")
    }

    func testMissingBackendIsSkipped() async {
        let result = await run([.cerebras: .tokens(["ok"])], plan: [.groq, .cerebras])
        XCTAssertEqual(result.text, "ok")
    }
}

final class PlannerTests: XCTestCase {
    private func settings(failover: Bool, order: [ProviderID]) -> TranslationSettings {
        var settings = TranslationSettings()
        settings.failover.isEnabled = failover
        settings.failover.order = order
        return settings
    }

    func testSelectedProviderFirstThenPriorityOrder() {
        let plan = RoutingPlanner.plan(
            settings: settings(failover: true, order: [.groq, .cerebras, .zhipu]),
            selected: .zhipu, available: [.groq, .cerebras, .zhipu], health: ProviderHealth()
        )
        XCTAssertEqual(plan, [.zhipu, .groq, .cerebras])
    }

    func testFailoverDisabledUsesOnlySelected() {
        let plan = RoutingPlanner.plan(
            settings: settings(failover: false, order: [.groq, .cerebras]),
            selected: .cerebras, available: [.groq, .cerebras], health: ProviderHealth()
        )
        XCTAssertEqual(plan, [.cerebras])
    }

    func testCoolingProviderIsDemotedNotDropped() {
        let health = ProviderHealth()
        health.recordFailure(.groq, TranslationError(provider: .groq, .rateLimited(retryAfter: 60)))
        let plan = RoutingPlanner.plan(
            settings: settings(failover: true, order: [.groq, .cerebras, .together]),
            selected: .groq, available: [.groq, .cerebras, .together], health: health
        )
        XCTAssertEqual(plan, [.cerebras, .together, .groq])
    }

    func testUnavailableSelectedFallsBackToOrder() {
        let plan = RoutingPlanner.plan(
            settings: settings(failover: true, order: [.groq, .cerebras]),
            selected: .zhipu, available: [.cerebras, .groq], health: ProviderHealth()
        )
        XCTAssertEqual(plan, [.groq, .cerebras])
    }

    func testCooldownExpires() {
        let health = ProviderHealth()
        let now = Date()
        health.recordFailure(.groq, TranslationError(provider: .groq, .timeout), at: now)
        XCTAssertTrue(health.isCoolingDown(.groq, at: now.addingTimeInterval(5)))
        XCTAssertFalse(health.isCoolingDown(.groq, at: now.addingTimeInterval(31)))
    }
}
