import Foundation

/// The choices that decide how hard the Mac is to open. They are kept in the keychain rather
/// than the preferences file, so another program (or a launch option) can't quietly turn them
/// down, and lowering any of them asks for Touch ID or the password.
struct SecuritySettings: Codable, Equatable {
    var protection = AppModel.Protection.high
    var strictness = AppModel.Strictness.balanced
    var requiresAttention = true
    var requiresSolitude = false
    var usesSpoofModel = false
    /// Minutes before the password is needed again.
    var timeLimit = UnlockPolicy.defaultTimeLimit
    var failureLimit = 5
    var window = UnlockPolicy.Window.inactivity
    var adaptsToFace = true

    private static func rank(_ protection: AppModel.Protection) -> Int {
        AppModel.Protection.allCases.firstIndex(of: protection) ?? 0
    }

    /// True if any one choice here makes the Mac easier to open than in `other`.
    func isWeaker(than other: SecuritySettings) -> Bool {
        Self.rank(protection) < Self.rank(other.protection)
            || (strictness == .balanced && other.strictness == .strict)
            || (!requiresAttention && other.requiresAttention)
            || (!requiresSolitude && other.requiresSolitude)
            || (!usesSpoofModel && other.usesSpoofModel)
            || timeLimit > other.timeLimit
            || failureLimit > other.failureLimit
            || (window == .inactivity && other.window == .strict)
            // Learning adds ways of looking that will be accepted.
            || (adaptsToFace && !other.adaptsToFace)
    }

    /// Each choice from whichever of the two is harder to get past.
    func tightened(with other: SecuritySettings) -> SecuritySettings {
        var result = self
        if Self.rank(other.protection) > Self.rank(protection) { result.protection = other.protection }
        if other.strictness == .strict { result.strictness = .strict }
        result.requiresAttention = requiresAttention || other.requiresAttention
        result.requiresSolitude = requiresSolitude || other.requiresSolitude
        result.usesSpoofModel = usesSpoofModel || other.usesSpoofModel
        result.timeLimit = min(timeLimit, other.timeLimit)
        result.failureLimit = min(failureLimit, other.failureLimit)
        if other.window == .strict { result.window = .strict }
        result.adaptsToFace = adaptsToFace && other.adaptsToFace
        return result
    }
}

enum SecurityStore {
    private static let account = "security-settings"

    static func load() -> SecuritySettings {
        if let data = Keychain.read(account), let saved = try? JSONDecoder().decode(SecuritySettings.self, from: data) {
            return saved
        }
        // First run of this version, or the item is gone. Earlier choices in the preferences
        // file are honoured only where they are no weaker than the standard ones, since anything
        // can write that file. The domain is read directly so launch options are ignored.
        let old = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "") ?? [:]
        var earlier = SecuritySettings()
        if let value = (old["protection"] as? String).flatMap(AppModel.Protection.init) { earlier.protection = value }
        if let value = (old["strictness"] as? String).flatMap(AppModel.Strictness.init) { earlier.strictness = value }
        if let value = old["attention"] as? Bool { earlier.requiresAttention = value }
        if let value = old["solitude"] as? Bool { earlier.requiresSolitude = value }
        if let value = old["spoofModel"] as? Bool { earlier.usesSpoofModel = value }
        if let value = old["timeLimit"] as? Int { earlier.timeLimit = max(value, 5) }
        if let value = old["failureLimit"] as? Int { earlier.failureLimit = max(value, 1) }
        if let value = (old["window"] as? String).flatMap(UnlockPolicy.Window.init) { earlier.window = value }
        if let value = old["adapts"] as? Bool { earlier.adaptsToFace = value }
        return SecuritySettings().tightened(with: earlier)
    }

    static func save(_ settings: SecuritySettings) {
        // Unit tests run inside the app; they must not change the user's own choices.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
              let data = try? JSONEncoder().encode(settings) else { return }
        Keychain.write(data, account: account)
    }
}
