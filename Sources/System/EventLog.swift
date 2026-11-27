import Foundation

/// A short plain-text record of what happened on each lock, so a failed unlock can be explained.
/// Never contains the password, face data or images.
enum EventLog {
    static let url = URL.libraryDirectory.appending(path: "Logs/FaceUnlock.log")
    private static let queue = DispatchQueue(label: "faceunlock.log")

    static func write(_ message: String) {
        // Local time, so entries line up with what you saw happen.
        var style = Date.ISO8601FormatStyle(timeZone: .current)
        style = style.year().month().day().time(includingFractionalSeconds: false).dateTimeSeparator(.space)
        let stamp = Date.now.formatted(style)
        let line = "\(stamp)  \(message)\n"
        queue.async {
            var text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            text += line
            if text.count > 60_000 { text = String(text.suffix(40_000)) }
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
