import AVFoundation

/// FaceUnlock's own sound effects (made by `Tools/make_sounds.py`).
enum SoundEffect: String, CaseIterable, Identifiable {
    case scan, unlock, lock, failure, password, notice, capture, complete
    var id: String { rawValue }

    var title: String {
        switch self {
        case .scan: "Looking"
        case .unlock: "Unlocked"
        case .lock: "Locked"
        case .failure: "Not Recognized"
        case .password: "Password Required"
        case .notice: "Notice"
        case .capture: "Setup Step"
        case .complete: "Setup Complete"
        }
    }

    var url: URL? { Bundle.main.url(forResource: rawValue, withExtension: "wav") }
}

@MainActor
enum Sounds {
    static var isOn: Bool {
        get { UserDefaults.standard.object(forKey: "soundEffects") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "soundEffects") }
    }
    /// On top of the Mac's own volume.
    static var volume: Double {
        get { UserDefaults.standard.object(forKey: "soundVolume") as? Double ?? 0.7 }
        set { UserDefaults.standard.set(newValue, forKey: "soundVolume") }
    }

    private static var players: [SoundEffect: AVAudioPlayer] = [:]

    static func play(_ effect: SoundEffect) {
        // Unit tests host the app; keep them silent.
        guard isOn, ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        if players[effect] == nil { players[effect] = effect.url.flatMap { try? AVAudioPlayer(contentsOf: $0) } }
        guard let player = players[effect] else { return }
        player.volume = Float(volume)
        player.currentTime = 0
        player.play()
    }
}
