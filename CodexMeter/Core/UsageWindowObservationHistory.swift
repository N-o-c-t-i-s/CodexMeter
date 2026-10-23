import Foundation

/// Keeps a spaced comparison even when foreground polling or notifications
/// arrive faster than the minimum interval needed to prove a sliding reset.
struct UsageWindowObservationHistory {
    private var observations: [UsageWindowObservation] = []
    private static let maximumAge: TimeInterval = 120
    private static let maximumCount = 64

    mutating func append(_ current: UsageWindowObservation) -> UsageWindowObservation? {
        if let last = observations.last,
           last.accountKey != current.accountKey
            || last.accountGeneration != current.accountGeneration
            || last.accountType != current.accountType
            || current.observedAt <= last.observedAt {
            observations.removeAll()
        }

        // An intervening active or invalid reading breaks the proof of idleness.
        // Never compare across it to an older hypothetical window.
        guard !current.hasConflictingWindows,
              let short = current.shortWindow,
              UsageWindowActivityClassifier.assess(
                current: short, previous: nil, at: current.observedAt
              ).isHypotheticalCandidate else {
            observations = [current]
            return nil
        }

        observations.removeAll {
            current.observedAt.timeIntervalSince($0.observedAt) > Self.maximumAge
        }
        let previous = observations.last {
            current.observedAt.timeIntervalSince($0.observedAt)
                >= UsageWindowActivityClassifier.minimumSlidingInterval
        }
        observations.append(current)
        if observations.count > Self.maximumCount {
            observations.removeFirst(observations.count - Self.maximumCount)
        }
        return previous
    }
}
