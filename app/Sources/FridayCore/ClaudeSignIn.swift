import Foundation

/// Whether Claude needs signing in, as the engine last said. Kept apart from
/// the warning the app shows: another warning (a voice problem) can replace
/// that one while Claude is still signed out.
public struct ClaudeSignIn: Equatable, Sendable {
    public static let code = "claude_auth"
    public private(set) var signedOut = false

    public init() {}

    /// A `warning` arrived. True when Claude has just become signed out.
    public mutating func warning(_ code: String) -> Bool {
        guard code == Self.code, !signedOut else { return false }
        signedOut = true
        return true
    }

    /// A `resolved` arrived. True when Claude has just been signed in again.
    public mutating func resolved(_ code: String) -> Bool {
        guard code == Self.code, signedOut else { return false }
        signedOut = false
        return true
    }
}
