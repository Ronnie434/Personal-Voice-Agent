import Foundation

/// When to restart a crashed engine: after 1, 2, 4, 8, then 30 s, and not at
/// all once it has crashed 5 times in 10 minutes.
public struct RestartPolicy: Sendable {
    public static let delays: [TimeInterval] = [1, 2, 4, 8, 30]
    public static let maxCrashes = 5
    public static let window: TimeInterval = 600
    /// An engine that stayed up this long is healthy again: start over at 1 s.
    public static let healthyAfter: TimeInterval = 60

    private var crashes: [Date] = []
    private var streak = 0

    public init() {}

    public enum Decision: Equatable, Sendable { case restart(after: TimeInterval), giveUp }

    /// The engine died at `now`, having started at `startedAt`.
    public mutating func crashed(at now: Date, startedAt: Date) -> Decision {
        if now.timeIntervalSince(startedAt) >= Self.healthyAfter { streak = 0 }
        crashes = crashes.filter { now.timeIntervalSince($0) < Self.window } + [now]
        if crashes.count >= Self.maxCrashes { return .giveUp }
        let delay = Self.delays[min(streak, Self.delays.count - 1)]
        streak += 1
        return .restart(after: delay)
    }

    /// The user asked to start again: forget the past.
    public mutating func reset() { crashes = []; streak = 0 }
}
