import Foundation

/// Which warning the app shows, and whether Claude needs signing in.
///
/// Claude being signed out is kept apart from the warning shown, and wins
/// over any other: Friday can't answer at all, which matters more than, say,
/// its voice. A warning that arrives meanwhile is held, and shown once Claude
/// is signed in again, since the engine sends each warning only once.
public struct ClaudeSignIn: Equatable, Sendable {
    public static let code = "claude_auth"
    public private(set) var signedOut = false
    /// The warning to show (a protocol `warning` code), if any.
    public private(set) var shown: String?
    private var held: String?

    public init() {}

    /// A `warning` arrived. True when Claude has just become signed out.
    public mutating func warning(_ code: String) -> Bool {
        if code == Self.code {
            if shown != Self.code, let other = shown { held = other }
            shown = code
            guard !signedOut else { return false }
            signedOut = true
            return true
        }
        if signedOut { held = code } else { shown = code }
        return false
    }

    /// A `resolved` arrived. True when Claude has just been signed in again.
    public mutating func resolved(_ code: String) -> Bool {
        if code != Self.code {
            if shown == code { shown = nil }
            if held == code { held = nil }
            return false
        }
        if shown == Self.code { shown = held }
        held = nil
        guard signedOut else { return false }
        signedOut = false
        return true
    }

    /// A fresh engine reports its own warnings again; whether Claude is signed
    /// out stands until it says otherwise.
    public mutating func engineRestarted() {
        held = nil
        shown = signedOut ? Self.code : nil
    }
}
