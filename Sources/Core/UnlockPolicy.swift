import Foundation

/// When is a face allowed to unlock the Mac? Mirrors the iPhone Duo rules:
/// a recent password / Touch ID unlock, a time limit (45 minutes unless changed), and a failure limit.
struct UnlockPolicy: Equatable {
    enum Window: String, CaseIterable, Identifiable, Codable {
        /// Expires after the Mac has sat locked for the time limit (matches reports for iPhone Duo).
        case inactivity
        /// Expires the time limit after the last password or Touch ID unlock.
        case strict
        var id: String { rawValue }
    }

    enum Reason: Equatable {
        case afterLaunch, timedOut, tooManyAttempts, typingFailed

        var message: String {
            switch self {
            case .afterLaunch: "FaceUnlock restarted. Use Touch ID or your password."
            case .timedOut: "Time limit passed. Use Touch ID or your password."
            case .tooManyAttempts: "Too many attempts. Use Touch ID or your password."
            case .typingFailed: "Automatic unlock failed. Check your saved password."
            }
        }
    }

    /// The choices for the time limit, in minutes. 45, the default, sits in the middle.
    static let timeLimits = [5, 10, 15, 30, 45, 60, 90, 120, 180]
    static let defaultTimeLimit = 45

    /// How long face unlock stays available. See `Window` for when the clock starts.
    var timeout = TimeInterval(defaultTimeLimit * 60)
    /// Never more than five, as with Face ID.
    var maximumFailures = 5

    var window: Window = .inactivity
    private(set) var lastAuthentication: Date?
    private(set) var lockedSince: Date?
    private(set) var failures = 0
    private(set) var typingFailed = false

    /// Password or Touch ID was just used.
    mutating func authenticated(at date: Date) {
        lastAuthentication = date
        lockedSince = nil
        failures = 0
        typingFailed = false
    }

    mutating func locked(at date: Date) {
        if lockedSince == nil { lockedSince = date }
    }

    /// A face unlock succeeded. It does not count as a password authentication.
    mutating func faceUnlocked() {
        lockedSince = nil
        failures = 0
    }

    mutating func faceRejected() { failures += 1 }

    /// When the time limit will run out, if a countdown is running.
    var expiry: Date? {
        guard !typingFailed, let lastAuthentication, failures < maximumFailures else { return nil }
        let start: Date? = window == .strict ? lastAuthentication : lockedSince
        return start?.addingTimeInterval(timeout)
    }
    mutating func typingDidFail() { typingFailed = true }

    /// `nil` means face unlock is allowed.
    func passwordRequired(at now: Date) -> Reason? {
        if typingFailed { return .typingFailed }
        guard let lastAuthentication else { return .afterLaunch }
        if failures >= maximumFailures { return .tooManyAttempts }
        let start: Date? = window == .strict ? lastAuthentication : lockedSince
        if let start, now.timeIntervalSince(start) >= timeout { return .timedOut }
        return nil
    }
}
