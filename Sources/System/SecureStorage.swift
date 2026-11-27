import CryptoKit
import Foundation
import OpenDirectory
import Security

/// Generic-password items in the user's login keychain.
enum Keychain {
    private static let service = "com.faceunlock.mac"

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func read(_ account: String) -> Data? {
        var q = query(account)
        q[kSecReturnData as String] = true
        var item: CFTypeRef?
        return SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess ? item as? Data : nil
    }

    @discardableResult
    static func write(_ data: Data, account: String) -> Bool {
        delete(account)
        var q = query(account)
        q[kSecValueData as String] = data
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }

    static func contains(_ account: String) -> Bool {
        var q = query(account)
        q[kSecReturnAttributes as String] = true
        return SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess
    }

    static func delete(_ account: String) { SecItemDelete(query(account) as CFDictionary) }
}

/// The Mac login password, kept only if the user opts into automatic unlock.
enum PasswordVault {
    private static let account = "login-password"

    static var hasPassword: Bool { Keychain.contains(account) }

    /// Checked against the local account first, so a typo is never replayed at the lock screen.
    static func verify(_ password: String) -> Bool {
        guard let node = try? ODNode(session: ODSession.default(), type: ODNodeType(kODNodeTypeLocalNodes)),
              let record = try? node.record(withRecordType: kODRecordTypeUsers, name: NSUserName(), attributes: nil)
        else { return false }
        return (try? record.verifyPassword(password)) != nil
    }

    static func save(_ password: String) -> Bool { Keychain.write(Data(password.utf8), account: account) }
    static func load() -> String? { Keychain.read(account).flatMap { String(data: $0, encoding: .utf8) } }
    static func remove() { Keychain.delete(account) }
}

/// The ways of looking that can each have their own scan.
enum Appearance: String, CaseIterable, Identifiable {
    case primary, glasses, hat, alternate
    var id: String { rawValue }

    var title: String {
        switch self {
        case .primary: "Face"
        case .glasses: "With Glasses"
        case .hat: "With a Hat"
        case .alternate: "Alternate Appearance"
        }
    }

    /// Fits under a circle.
    var shortTitle: String {
        switch self {
        case .primary: "Face"
        case .glasses: "Glasses"
        case .hat: "Hat"
        case .alternate: "Alternate"
        }
    }

    var symbol: String {
        switch self {
        case .primary: "person.crop.circle"
        case .glasses: "eyeglasses"
        case .hat: "hat.cap"
        case .alternate: "person.crop.circle.badge.plus"
        }
    }

    /// What to do before the scan.
    var preparation: String? {
        switch self {
        case .primary: nil
        case .glasses: "Put on the glasses you usually wear. Dark lenses hide your eyes and won’t work."
        case .hat: "Put on your hat, with the brim high enough that your eyes are clearly visible."
        case .alternate: "Look the other way you often do: a new haircut, a beard, or different make-up."
        }
    }
}

/// Face templates: numbers only (no pictures), AES-GCM encrypted with a key held in the keychain.
struct TemplateStore {
    struct Enrollment: Codable, Equatable {
        var primary: [[Float]] = []
        var alternate: [[Float]] = []
        /// Added since setup (see `FaceAdaptation`). Optional so earlier files still open.
        var learned: [Update]?
        /// Scans with glasses, a hat and so on, by `Appearance`. Optional like `learned`.
        var extras: [String: [[Float]]]?
        /// The setup scans only.
        var all: [[Float]] {
            primary + alternate + (extras ?? [:]).sorted { $0.key < $1.key }.flatMap(\.value)
        }

        subscript(appearance: Appearance) -> [[Float]] {
            get {
                switch appearance {
                case .primary: primary
                case .alternate: alternate
                case .glasses, .hat: extras?[appearance.rawValue] ?? []
                }
            }
            set {
                switch appearance {
                case .primary: primary = newValue
                case .alternate: alternate = newValue
                case .glasses, .hat:
                    var changed = extras ?? [:]
                    changed[appearance.rawValue] = newValue.isEmpty ? nil : newValue
                    extras = changed.isEmpty ? nil : changed
                }
            }
        }
    }

    struct Update: Codable, Equatable {
        var vector: [Float]
        var added: Date
        var lastUsed: Date
        var uses = 0
    }

    private static let keyAccount = "template-key"

    private var url: URL {
        URL.applicationSupportDirectory.appending(path: "FaceUnlock/face.bin")
    }

    private func key() -> SymmetricKey? {
        if let data = Keychain.read(Self.keyAccount) { return SymmetricKey(data: data) }
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        return Keychain.write(data, account: Self.keyAccount) ? key : nil
    }

    func load() -> Enrollment {
        guard let data = try? Data(contentsOf: url), let key = key(),
              let box = try? AES.GCM.SealedBox(combined: data),
              let plain = try? AES.GCM.open(box, using: key),
              let value = try? JSONDecoder().decode(Enrollment.self, from: plain) else { return Enrollment() }
        return value
    }

    func save(_ enrollment: Enrollment) throws {
        guard let key = key() else { throw CocoaError(.fileWriteUnknown) }
        let sealed = try AES.GCM.seal(JSONEncoder().encode(enrollment), using: key)
        guard let data = sealed.combined else { throw CocoaError(.fileWriteUnknown) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    func erase() {
        try? FileManager.default.removeItem(at: url)
        Keychain.delete(Self.keyAccount)
    }
}
