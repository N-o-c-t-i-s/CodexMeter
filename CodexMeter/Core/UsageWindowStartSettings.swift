import Foundation

/// Where a window-start evaluation came from.
///
/// A manual request may ignore the automatic switch and the daily time range,
/// but it obeys every account, backend, window, cooldown, and mutual-exclusion
/// rule an automatic request obeys.
enum UsageWindowStartTrigger: String, Equatable, Sendable {
    case automatic
    case manual
}

/// A cooldown and time-range record scoped to one local account key.
struct UsageWindowStartSettings: Codable, Equatable, Sendable {
    /// Automatic sending is off for a new account and never inherited from the
    /// previous account or from the reference implementation's defaults.
    var autoStartEnabled: Bool
    var modelID: String?
    var reasoningEffort: String?
    var activeHours: UsageWindowActiveHours

    static let defaultValue = UsageWindowStartSettings(
        autoStartEnabled: false,
        modelID: nil,
        reasoningEffort: nil,
        activeHours: .always
    )
}

/// A daily window in which automatic sends may happen.
///
/// Equal start and end minutes mean "all day", and a start later than the end
/// describes a range that crosses midnight.
struct UsageWindowActiveHours: Codable, Equatable, Sendable {
    var isEnabled: Bool
    var startMinutes: Int
    var endMinutes: Int

    static let always = UsageWindowActiveHours(
        isEnabled: false,
        startMinutes: 0,
        endMinutes: 0
    )

    init(isEnabled: Bool, startMinutes: Int, endMinutes: Int) {
        self.isEnabled = isEnabled
        self.startMinutes = Self.clamp(startMinutes)
        self.endMinutes = Self.clamp(endMinutes)
    }

    /// True when the range covers the whole day, which the UI shows explicitly
    /// instead of presenting a range the user cannot tell apart from "off".
    var isAllDay: Bool {
        !isEnabled || startMinutes == endMinutes
    }

    func contains(_ date: Date, calendar: Calendar) -> Bool {
        guard !isAllDay else { return true }
        let current = Self.minutesOfDay(for: date, calendar: calendar)
        if startMinutes < endMinutes {
            return current >= startMinutes && current < endMinutes
        }
        return current >= startMinutes || current < endMinutes
    }

    /// The next instant at which containment flips, so the scheduler can wake
    /// exactly when the automatic window opens or closes.
    func nextBoundary(after date: Date, calendar: Calendar) -> Date? {
        guard !isAllDay else { return nil }

        var candidates: [Date] = []
        for dayOffset in -1...2 {
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: date) else {
                continue
            }
            for minutes in [startMinutes, endMinutes] {
                if let boundary = Self.date(onDayOf: day, minutes: minutes, calendar: calendar),
                   boundary > date {
                    candidates.append(boundary)
                }
            }
        }
        return candidates.min()
    }

    static func minutesOfDay(for date: Date, calendar: Calendar) -> Int {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        return (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }

    private static func date(onDayOf date: Date, minutes: Int, calendar: Calendar) -> Date? {
        let startOfDay = calendar.startOfDay(for: date)
        var components = calendar.dateComponents([.year, .month, .day], from: startOfDay)
        components.hour = minutes / 60
        components.minute = minutes % 60
        components.second = 0
        return calendar.date(from: components)
    }

    private static func clamp(_ minutes: Int) -> Int {
        min(24 * 60 - 1, max(0, minutes))
    }
}
