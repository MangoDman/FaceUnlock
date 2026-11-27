import AppKit
import AVFoundation

/// A moment worth hearing and feeling. The sounds are made by `Tools/make_sounds.py`; their
/// timing, and the haptic taps here, follow the animation that starts at the same instant.
enum SoundEffect: String, CaseIterable, Identifiable {
    case open, unlock, retract, lock, failure, password, notice, hover, tap
    case capture1, capture2, capture3, capture4, complete, on, off
    var id: String { rawValue }

    var title: String {
        switch self {
        case .open: "Looking"
        case .unlock: "Unlocked"
        case .retract: "Notch Closing"
        case .lock: "Locked"
        case .failure: "Not Recognized"
        case .password: "Password Required"
        case .notice: "Notice"
        case .hover: "Pointer on the Notch"
        case .tap: "Button"
        case .capture1: "Setup: First Side"
        case .capture2: "Setup: Second Side"
        case .capture3: "Setup: Third Side"
        case .capture4: "Setup: Fourth Side"
        case .complete: "Setup Complete"
        case .on: "Turned On"
        case .off: "Paused"
        }
    }

    var url: URL? { Bundle.main.url(forResource: rawValue, withExtension: "wav") }

    /// Trackpad taps, in seconds from the start.
    var taps: [(TimeInterval, NSHapticFeedbackManager.FeedbackPattern)] {
        switch self {
        // The ring meets itself, then the tick.
        case .unlock: [(0.255, .alignment), (0.405, .levelChange)]
        // With the notch's shake.
        case .failure: [(0.042, .generic), (0.208, .generic), (0.375, .generic)]
        case .complete: [(0.30, .alignment), (0.80, .levelChange)]
        case .lock: [(0.062, .levelChange)]
        case .password, .notice: [(0.17, .generic)]
        case .capture1, .capture2, .capture3, .capture4, .hover: [(0, .alignment)]
        case .tap: [(0, .generic)]
        case .on, .off: [(0.07, .alignment)]
        case .open, .retract: []
        }
    }
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
    static var hapticsOn: Bool { UserDefaults.standard.object(forKey: "haptic") as? Bool ?? true }

    private static var players: [SoundEffect: AVAudioPlayer] = [:]

    private static func player(_ effect: SoundEffect) -> AVAudioPlayer? {
        if players[effect] == nil {
            players[effect] = effect.url.flatMap { try? AVAudioPlayer(contentsOf: $0) }
            players[effect]?.prepareToPlay()
        }
        return players[effect]
    }

    /// Loads everything, so the first sound isn't late for its animation.
    static func prepare() { SoundEffect.allCases.forEach { _ = player($0) } }

    static func play(_ effect: SoundEffect) {
        // Unit tests host the app; keep them quiet.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        if isOn, let player = player(effect) {
            player.volume = Float(volume)
            player.currentTime = 0
            player.play()
        }
        // Felt only while a finger is on a Force Touch trackpad.
        guard hapticsOn else { return }
        for (delay, pattern) in effect.taps {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
            }
        }
    }
}
