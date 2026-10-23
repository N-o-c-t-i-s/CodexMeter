import Foundation

/// System events the auto-starter reacts to.
enum UsageWindowSystemNotification: String, CaseIterable, Sendable {
    /// The Mac woke from sleep. Posted by `NSWorkspace`.
    case wake
    /// The wall clock jumped. Posted by Foundation.
    case clockChange
    /// The time zone changed. Posted by Foundation.
    case timeZoneChange

    /// Which notification center actually delivers this event.
    ///
    /// `NSWorkspace` posts its notifications on its own center, so observing
    /// `NSWorkspace.didWakeNotification` on `NotificationCenter.default` never
    /// fires. Keeping the mapping here makes that mistake testable.
    var centerKind: UsageWindowNotificationCenterKind {
        switch self {
        case .wake:
            return .workspace
        case .clockChange, .timeZoneChange:
            return .application
        }
    }
}

enum UsageWindowNotificationCenterKind: Equatable, Sendable {
    case application
    case workspace
}
