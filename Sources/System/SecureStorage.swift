import CryptoKit
import Foundation
import OpenDirectory
import Security

/// Generic-password items in the user's login keychain.
enum Keychain {
    private static let service = "com.faceunlock.mac"

    /// Unit tests run inside the app. They must never read, change or ask for the real items.
    // Screenshot runs (`--demo`, development builds only) leave them alone too.
    private static let underTest = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        || LaunchOptions.has("--demo")

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    enum Item: Equatable {
        case value(Data), missing
        /// It is there, but macOS won't hand it over without asking, or the request was turned down.
        case refused
    }

    /// With `silently`, macOS is told not to ask. A keychain prompt on the lock screen is hidden
    /// behind it and stops the app while it waits, so nothing is ever asked while locked.
    static func lookup(_ account: String, silently: Bool = Screen.isLocked) -> Item {
        if underTest { return .refused }
        var q = query(account)
        q[kSecReturnData as String] = true
        var wasAllowed: DarwinBoolean = true
        if silently {
            // The only switch the login keychain's permission prompts obey.
            SecKeychainGetUserInteractionAllowed(&wasAllowed)
            SecKeychainSetUserInteractionAllowed(false)
        }
        defer { if silently { SecKeychainSetUserInteractionAllowed(wasAllowed.boolValue) } }
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data { return .value(data) }
        return status == errSecItemNotFound ? .missing : .refused
    }

    static func read(_ account: String) -> Data? {
        if case .value(let data) = lookup(account) { data } else { nil }
    }

    /// True if reading it now would need your say-so. Never shows anything.
    static func needsPermission(_ account: String) -> Bool { lookup(account, silently: true) == .refused }

    @discardableResult
    static func write(_ data: Data, account: String) -> Bool {
        if underTest { return false }
        delete(account)
        var q = query(account)
        q[kSecValueData as String] = data
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }

    static func contains(_ account: String) -> Bool {
        if underTest { return false }
        var q = query(account)
        q[kSecReturnAttributes as String] = true
        return SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess
    }

    static func delete(_ account: String) {
        if !underTest { SecItemDelete(query(account) as CFDictionary) }
    }
}

/// The Mac login password, kept only if the user opts into automatic unlock.
enum PasswordVault {
    private static let account = "login-password"

    static var hasPassword: Bool { Keychain.contains(account) }
    static var needsPermission: Bool { Keychain.needsPermission(account) }

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

    /// Read once, so the keychain isn't asked again every time something is learned.
    private final class Cache { var key: SymmetricKey? }
    private let cache = Cache()

    var needsPermission: Bool { Keychain.needsPermission(Self.keyAccount) }

    /// Asks macOS for the key, showing its prompt if it wants one.
    func requestAccess() { _ = Keychain.lookup(Self.keyAccount, silently: false) }

    private var url: URL {
        URL.applicationSupportDirectory.appending(path: "FaceUnlock/face.bin")
    }

    private func key() -> SymmetricKey? {
        if let key = cache.key { return key }
        switch Keychain.lookup(Self.keyAccount) {
        case .value(let data):
            cache.key = SymmetricKey(data: data)
        case .missing:
            let new = SymmetricKey(size: .bits256)
            if Keychain.write(new.withUnsafeBytes { Data($0) }, account: Self.keyAccount) { cache.key = new }
        case .refused:
            // The key exists. Replacing it would make the saved face data unreadable.
            break
        }
        return cache.key
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
        cache.key = nil
    }
}
