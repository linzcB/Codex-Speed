import Foundation

/// File-system notifications wake idle monitoring; polling remains a recovery
/// path if notifications are unavailable or coalesced by the system.
public enum RefreshPolicy {
    public static func interval(isActive: Bool, isVisible: Bool, isObserving: Bool) -> TimeInterval {
        isActive || isVisible || !isObserving ? 1 : 30
    }

    public static func discoveryInterval(isObserving: Bool) -> TimeInterval {
        isObserving ? 60 : 10
    }
}
