import Foundation
import Observation

/// The events shown in Settings › Activity. No pictures, passwords or face data.
@MainActor @Observable
final class History {
    struct Event: Codable, Identifiable, Equatable {
        enum Kind: String, Codable {
            case faceUnlock, passwordUnlock, rejected, spoof, noLiveness, paused, walkAway, typingFailed
        }
        var id = UUID()
        var date = Date()
        var kind: Kind
        var detail = ""
    }

    private(set) var events: [Event]
    private let key = "history"

    init() {
        let data = UserDefaults.standard.data(forKey: key)
        events = data.flatMap { try? JSONDecoder().decode([Event].self, from: $0) } ?? []
    }

    func add(_ kind: Event.Kind, _ detail: String = "") {
        events.insert(Event(kind: kind, detail: detail), at: 0)
        events = Array(events.prefix(100))
        save()
    }

    func clear() {
        events = []
        save()
    }

    private func save() { UserDefaults.standard.set(try? JSONEncoder().encode(events), forKey: key) }
}
