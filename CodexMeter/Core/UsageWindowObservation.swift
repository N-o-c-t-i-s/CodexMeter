import Foundation

/// Whether a single quota window is currently running, provably idle, or
/// cannot be decided from the data the backend returned.
enum UsageWindowActivity: String, Equatable, Sendable {
    case active
    case idle
    case unknown
}

/// The backend's own permission for ordinary included usage.
///
/// A `null` or missing `ordinaryUsageAllowed` is genuinely unknown. Codex App
/// Server documents that clients must not infer recovery from percentages or
/// reset times, so this type never degrades into a guess.
enum UsageWindowAuthorization: Equatable, Sendable {
    case allowed
    case denied
    case unknown
}

/// One raw quota window from `account/rateLimits/read`.
///
/// This mirrors the backend response without the display normalization used by
/// the popover and the history store: positional `primary`/`secondary` slots are
/// flattened, names are not localized, and no reset-jitter repair is applied.
struct UsageWindowReading: Equatable, Sendable {
    /// When the response that carried this reading was received.
    let observedAt: Date
    let limitID: String
    let limitName: String?
    /// The App Server slot this reading came from. Used only for diagnostics.
    let slot: String
    let usedPercent: Int
    let windowDurationMins: Int?
    let resetsAt: Date?
    let rateLimitReachedType: String?
    let spendControlReached: Bool?

    var durationMins: Int? {
        guard let windowDurationMins, windowDurationMins > 0 else { return nil }
        return windowDurationMins
    }

    /// The identity the auto-starter targets. Duration scoping keeps a slot swap
    /// from silently retargeting a different quota window.
    var windowIdentity: String? {
        guard let durationMins else { return nil }
        return "\(limitID):\(durationMins)"
    }
}

/// The result of one successful `account/rateLimits/read` for the account that
/// the current App Server generation has authenticated.
///
/// Observations are immutable and carry the account generation that produced
/// them; a late response from a previous account can therefore never be used to
/// justify a send.
struct UsageWindowObservation: Equatable, Sendable {
    /// The standard metered bucket Codex bills ordinary ChatGPT usage against.
    static let standardLimitID = "codex"
    /// Five hours, as returned by the backend for the short window.
    static let shortWindowDurationMins = 300
    /// One week, as returned by the backend for the long window.
    static let weeklyWindowDurationMins = 10_080

    let observedAt: Date
    let accountGeneration: Int
    let accountKey: String
    let accountType: String
    let authorization: UsageWindowAuthorization
    let readings: [UsageWindowReading]

    /// Reads from the standard `codex` bucket only.
    ///
    /// Reserve buckets, aliases, and any bucket that is not the standard Codex
    /// limit are deliberately excluded: the auto-starter must not guess which
    /// quota a send would consume.
    var standardBucketReadings: [UsageWindowReading] {
        readings.filter { $0.limitID == Self.standardLimitID }
    }

    var shortWindow: UsageWindowReading? {
        uniqueReading(durationMins: Self.shortWindowDurationMins)
    }

    var weeklyWindow: UsageWindowReading? {
        uniqueReading(durationMins: Self.weeklyWindowDurationMins)
    }

    /// True when the standard bucket returned more than one window of the same
    /// duration, so no candidate can be trusted.
    var hasConflictingWindows: Bool {
        !conflictingReadings(durationMins: Self.shortWindowDurationMins).isEmpty
            || !conflictingReadings(durationMins: Self.weeklyWindowDurationMins).isEmpty
    }

    func isOlderThan(_ interval: TimeInterval, now: Date) -> Bool {
        now.timeIntervalSince(observedAt) > interval
    }

    private func uniqueReading(durationMins: Int) -> UsageWindowReading? {
        let matches = standardBucketReadings.filter { $0.durationMins == durationMins }
        return matches.count == 1 ? matches[0] : nil
    }

    private func conflictingReadings(durationMins: Int) -> [UsageWindowReading] {
        let matches = standardBucketReadings.filter { $0.durationMins == durationMins }
        return matches.count > 1 ? matches : []
    }
}

enum UsageWindowObservationParser {
    /// Decodes the `account/rateLimits/read` result into raw readings.
    ///
    /// Both the multi-bucket view and the legacy single snapshot are accepted.
    /// When a limit id appears in both, the multi-bucket entry wins because it
    /// carries `limitId` and is the view the backend keeps current.
    static func readings(
        fromRateLimitsResult result: [String: Any],
        observedAt: Date
    ) -> [UsageWindowReading] {
        var readings: [UsageWindowReading] = []
        var seenLimitIDs: Set<String> = []

        if let buckets = result["rateLimitsByLimitId"] as? [String: Any] {
            for (bucketID, value) in buckets {
                guard let snapshot = value as? [String: Any] else { continue }
                let limitID = snapshot["limitId"] as? String ?? bucketID
                seenLimitIDs.insert(limitID)
                readings.append(contentsOf: snapshotReadings(
                    snapshot,
                    limitID: limitID,
                    observedAt: observedAt
                ))
            }
        }

        if let legacy = result["rateLimits"] as? [String: Any] {
            let limitID = legacy["limitId"] as? String ?? UsageWindowObservation.standardLimitID
            if !seenLimitIDs.contains(limitID) {
                readings.append(contentsOf: snapshotReadings(
                    legacy,
                    limitID: limitID,
                    observedAt: observedAt
                ))
            }
        }

        // Deterministic order keeps policy and tests independent of dictionary order.
        return readings.sorted {
            if $0.limitID != $1.limitID { return $0.limitID < $1.limitID }
            return ($0.durationMins ?? Int.max) < ($1.durationMins ?? Int.max)
        }
    }

    static func authorization(fromRateLimitsResult result: [String: Any]) -> UsageWindowAuthorization {
        guard let value = result["ordinaryUsageAllowed"] as? Bool else { return .unknown }
        return value ? .allowed : .denied
    }

    private static func snapshotReadings(
        _ snapshot: [String: Any],
        limitID: String,
        observedAt: Date
    ) -> [UsageWindowReading] {
        let limitName = snapshot["limitName"] as? String
        let reached = snapshot["rateLimitReachedType"] as? String
        let spendControl = snapshot["spendControlReached"] as? Bool

        return ["primary", "secondary"].compactMap { slot in
            guard let window = snapshot[slot] as? [String: Any] else { return nil }
            guard let usedPercent = intValue(window["usedPercent"]) else { return nil }
            return UsageWindowReading(
                observedAt: observedAt,
                limitID: limitID,
                limitName: limitName,
                slot: slot,
                usedPercent: usedPercent,
                windowDurationMins: intValue(window["windowDurationMins"]),
                resetsAt: dateValue(window["resetsAt"]),
                rateLimitReachedType: reached,
                spendControlReached: spendControl
            )
        }
    }

    private static func intValue(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber else { return value as? Int }
        return number.intValue
    }

    private static func dateValue(_ value: Any?) -> Date? {
        guard let number = value as? NSNumber else { return nil }
        let seconds = number.doubleValue
        guard seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}

/// Decides whether the backend is reporting a running window, no window, or
/// something that cannot be decided safely.
///
/// Codex reports a *hypothetical* window when nothing is running: `0%` used and
/// a reset exactly one window length from "now", moving forward on every read.
/// A real window's reset is fixed, so once a real window has been running for
/// more than the tolerance, its reset falls behind `now + duration`.
///
/// The 45-second tolerance is an empirical rule derived from the reference
/// implementation and its tests; it is not a backend guarantee. Everything the
/// rules cannot settle returns `.unknown`, which never authorizes a send.
enum UsageWindowActivityClassifier {
    /// How far behind `now + duration` a reset must fall to prove a running
    /// window. Also the edge at which a lone reading is only a candidate.
    static let hypotheticalTolerance: TimeInterval = 45

    /// How closely two consecutive readings must track each other to prove the
    /// reset is sliding with the clock.
    static let slidingTolerance: TimeInterval = 15

    /// Minimum spacing that can demonstrate sliding. Two reads milliseconds
    /// apart cannot distinguish a moving reset from float noise.
    static let minimumSlidingInterval: TimeInterval = 20

    struct Assessment: Equatable, Sendable {
        let activity: UsageWindowActivity
        /// True when the reading has the backend's "no window running" shape.
        /// A single such reading is never enough to act on.
        let isHypotheticalCandidate: Bool
    }

    static func assess(
        current: UsageWindowReading,
        previous: UsageWindowReading?,
        at now: Date
    ) -> Assessment {
        let unknown = Assessment(activity: .unknown, isHypotheticalCandidate: false)

        guard (0...100).contains(current.usedPercent),
              let durationMins = current.durationMins,
              let resetsAt = current.resetsAt else {
            return unknown
        }

        let duration = TimeInterval(durationMins) * 60
        let remaining = resetsAt.timeIntervalSince(now)

        // A reset far beyond one window length cannot be reconciled with the
        // advertised duration, so the payload is anomalous rather than idle.
        guard remaining <= duration + hypotheticalTolerance else { return unknown }

        // An expired reset describes a cycle that already ended. Re-read before
        // deciding; never treat stale data as the next cycle.
        guard remaining > 0 else { return unknown }

        if current.usedPercent > 0 {
            return Assessment(activity: .active, isHypotheticalCandidate: false)
        }

        let hypotheticalFloor = duration - hypotheticalTolerance
        if remaining < hypotheticalFloor {
            // A fixed reset that has fallen behind the hypothetical threshold is
            // a running window, even while it still reports 0% used.
            return Assessment(activity: .active, isHypotheticalCandidate: false)
        }

        // 0% with a reset at (or just behind) one full window from now: the
        // backend may simply be describing the window that would start.
        guard let previous,
              previous.usedPercent == 0,
              let previousDuration = previous.durationMins,
              previousDuration == durationMins,
              let previousResetsAt = previous.resetsAt,
              let previousRemaining = Optional(previousResetsAt.timeIntervalSince(previous.observedAt)),
              previousRemaining > 0
        else {
            return Assessment(activity: .unknown, isHypotheticalCandidate: true)
        }

        let elapsed = current.observedAt.timeIntervalSince(previous.observedAt)
        guard elapsed >= minimumSlidingInterval else {
            return Assessment(activity: .unknown, isHypotheticalCandidate: true)
        }

        // Idle means the reset kept moving with the clock; both reads must still
        // look like one full window ahead.
        let drifted = abs(remaining - previousRemaining)
        let previousAlsoHypothetical = previousRemaining >= hypotheticalFloor
        if previousAlsoHypothetical && drifted <= slidingTolerance {
            return Assessment(activity: .idle, isHypotheticalCandidate: true)
        }

        return Assessment(activity: .unknown, isHypotheticalCandidate: false)
    }
}
