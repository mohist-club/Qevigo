import Foundation

/// Remembers which services recently failed so the router can skip a service
/// that is known to be throttled instead of waiting for it to fail again.
public final class ProviderHealth: @unchecked Sendable {
    public struct Entry: Equatable, Sendable {
        public let until: Date
        public let error: TranslationError
    }

    private var entries: [ProviderID: Entry] = [:]
    private let lock = NSLock()

    public init() {}

    public func recordFailure(_ id: ProviderID, _ error: TranslationError, at date: Date = Date()) {
        let cooldown = error.cooldown
        guard cooldown > 0 else { return }
        lock.withLock { entries[id] = Entry(until: date.addingTimeInterval(cooldown), error: error) }
    }

    public func recordSuccess(_ id: ProviderID) {
        lock.withLock { _ = entries.removeValue(forKey: id) }
    }

    public func reset(_ id: ProviderID) { recordSuccess(id) }

    public func resetAll() { lock.withLock { entries.removeAll() } }

    public func entry(for id: ProviderID, at date: Date = Date()) -> Entry? {
        lock.withLock {
            guard let entry = entries[id], entry.until > date else { return nil }
            return entry
        }
    }

    public func isCoolingDown(_ id: ProviderID, at date: Date = Date()) -> Bool {
        entry(for: id, at: date) != nil
    }
}

public enum RoutingPlanner {
    /// Ordered list of services to try for one translation.
    /// - The service the user chose goes first, unless it is cooling down and
    ///   failover is on (then it is tried last).
    /// - Others follow the configured priority order; cooling-down ones sink to
    ///   the end but stay as a last resort.
    public static func plan(
        settings: TranslationSettings,
        selected: ProviderID,
        available: [ProviderID],
        health: ProviderHealth,
        at date: Date = Date()
    ) -> [ProviderID] {
        guard !available.isEmpty else { return [] }
        let primary = available.contains(selected) ? selected : nil

        guard settings.failover.isEnabled else {
            return primary.map { [$0] } ?? [available[0]]
        }

        var ordered: [ProviderID] = []
        if let primary { ordered.append(primary) }
        ordered.append(contentsOf: settings.failover.order.filter { available.contains($0) && $0 != primary })

        let healthy = ordered.filter { !health.isCoolingDown($0, at: date) }
        let cooling = ordered.filter { health.isCoolingDown($0, at: date) }
        return healthy + cooling
    }
}
