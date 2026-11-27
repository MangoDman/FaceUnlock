/// The first-run guide shows one thing at a time: the first that is still missing.
enum GuideStep: String, CaseIterable, Identifiable {
    case keychain, camera, face, password, accessibility, turnOn, confirm, done
    var id: String { rawValue }

    /// Keychain comes first, as nothing saved can be read without it.
    static func current(keychainNeeded: Bool, camera: Bool, face: Bool, password: Bool, accessibility: Bool,
                        enabled: Bool, confirmationNeeded: Bool) -> GuideStep {
        if keychainNeeded { return .keychain }
        if !camera { return .camera }
        if !face { return .face }
        if !password { return .password }
        if !accessibility { return .accessibility }
        if !enabled { return .turnOn }
        if confirmationNeeded { return .confirm }
        return .done
    }

    /// The steps everyone goes through, for "Step 2 of 5". Keychain and Touch ID only come up
    /// sometimes.
    static let counted: [GuideStep] = [.camera, .face, .password, .accessibility, .turnOn]
}

/// The guide as a whole, in the manner of a new device's setup: a welcome, what's needed, then
/// a short tour of how to use it.
enum GuidePage: String, CaseIterable, Identifiable {
    case welcome, setup, duration, protection, menuBar, settings, howItWorks, tryIt, allSet
    var id: String { rawValue }

    /// The guide's four parts, named at the top of every screen after the welcome.
    enum Chapter: String, CaseIterable {
        case setUp = "Set Up", choices = "Your Choices", around = "Get to Know It", tryIt = "Try It"
        var number: Int { Self.allCases.firstIndex(of: self)! + 1 }
        var pages: [GuidePage] { GuidePage.allCases.filter { $0.chapter == self } }
    }

    var chapter: Chapter? {
        switch self {
        case .welcome: nil
        case .setup: .setUp
        case .duration, .protection: .choices
        case .menuBar, .settings: .around
        case .howItWorks, .tryIt, .allSet: .tryIt
        }
    }

    var next: GuidePage? { Self.step(from: self, by: 1) }
    var previous: GuidePage? { Self.step(from: self, by: -1) }

    private static func step(from page: GuidePage, by offset: Int) -> GuidePage? {
        let index = allCases.firstIndex(of: page)! + offset
        return allCases.indices.contains(index) ? allCases[index] : nil
    }
}
