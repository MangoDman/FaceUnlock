import Foundation

/// Keeps face data current as a face changes, the way Face ID does: new captures are added
/// beside the setup scan, used for a limited time, then dropped. The setup scan itself is never
/// altered, and nothing is added that doesn't still resemble it, so the data can't drift into
/// someone else's face.
enum FaceAdaptation {
    /// Why a capture is believed to be the owner.
    enum Proof {
        /// It unlocked the Mac. It must also match the setup scan on its own.
        case faceMatch(threshold: Float)
        /// The password or Touch ID followed it. A weaker resemblance is enough.
        case password
    }

    static let capacity = 8
    static let lifetime: TimeInterval = 30 * 24 * 60 * 60
    static let maximumUses = 60
    /// Closer than this to something already stored adds nothing.
    static let novelty: Float = 0.92
    /// The least a capture may resemble the setup scan, even with the password behind it. Close
    /// to the 0.55 needed to unlock, so a relative who tried first isn't learned from.
    static let floor: Float = 0.52
    /// How soon the password must follow a capture for the two to be the same person.
    static let confirmationWindow: TimeInterval = 30
}

extension TemplateStore.Enrollment {
    var updates: [TemplateStore.Update] { learned ?? [] }

    /// Drops updates that are worn out or haven't matched for a long time.
    mutating func expireUpdates(at date: Date) {
        learned = updates.filter {
            $0.uses < FaceAdaptation.maximumUses && date.timeIntervalSince($0.lastUsed) < FaceAdaptation.lifetime
        }
    }

    /// Counts a match against whichever update was closest, if one was closer than the setup scan.
    mutating func recordMatch(_ vector: [Float], at date: Date) {
        let setup = FaceMath.bestSimilarity(vector, in: all)
        let scores = updates.map { FaceMath.similarity(vector, $0.vector) }
        guard let best = scores.max(), best > setup, let index = scores.firstIndex(of: best) else { return }
        learned?[index].uses += 1
        learned?[index].lastUsed = date
    }

    /// Adds a capture if it is trustworthy and shows something new. Returns true if it was added.
    mutating func learn(_ vector: [Float], proof: FaceAdaptation.Proof, at date: Date) -> Bool {
        expireUpdates(at: date)
        let required: Float = switch proof {
        case .faceMatch(let threshold): max(threshold, FaceAdaptation.floor)
        case .password: FaceAdaptation.floor
        }
        guard FaceMath.bestSimilarity(vector, in: all) >= required,
              FaceMath.bestSimilarity(vector, in: all + updates.map(\.vector)) < FaceAdaptation.novelty
        else { return false }
        var list = updates + [.init(vector: vector, added: date, lastUsed: date)]
        if list.count > FaceAdaptation.capacity,
           let stalest = list.indices.min(by: { list[$0].lastUsed < list[$1].lastUsed }) {
            list.remove(at: stalest)
        }
        learned = list
        return true
    }
}
