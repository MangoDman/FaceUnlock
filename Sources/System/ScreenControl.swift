import AppKit
import CoreGraphics
import IOKit.pwr_mgt

enum Screen {
    static var isLocked: Bool {
        (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    /// False when another user has switched in front of this one.
    static var isOnConsole: Bool {
        (CGSessionCopyCurrentDictionary() as? [String: Any])?["kCGSSessionOnConsoleKey"] as? Bool ?? false
    }

    /// False with the lid closed (clamshell mode): the camera can't see anyone.
    static var builtInDisplayIsActive: Bool {
        var ids = [CGDirectDisplayID](repeating: 0, count: 8)
        var count: UInt32 = 0
        CGGetActiveDisplayList(8, &ids, &count)
        return ids.prefix(Int(count)).contains { CGDisplayIsBuiltin($0) != 0 && CGDisplayIsAsleep($0) == 0 }
    }

    private static func idle(_ type: CGEventType) -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: type)
    }

    /// Seconds since the user last touched the keyboard or trackpad.
    static var userIdleTime: TimeInterval {
        [CGEventType.keyDown, .mouseMoved, .leftMouseDown, .scrollWheel, .flagsChanged].map(idle).min() ?? 0
    }

    static var keyboardIdleTime: TimeInterval { idle(.keyDown) }

    static func lockNow() {
        typealias Lock = @convention(c) () -> Int32
        guard let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_LAZY),
              let symbol = dlsym(handle, "SACLockScreenImmediate") else { return }
        _ = unsafeBitCast(symbol, to: Lock.self)()
    }

    static func declareUserActivity() {
        var id: IOPMAssertionID = 0
        IOPMAssertionDeclareUserActivity("FaceUnlock: you're looking at the screen" as CFString,
                                         kIOPMUserActiveLocal, &id)
    }
}

/// Types the saved password into the lock screen. This is the one place the password leaves the
/// keychain; every event is preceded by a check that the screen is still locked, so it can't
/// land in an app.
enum PasswordTyper {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestTrust() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    private enum Key {
        static let `return`: CGKeyCode = 0x24, delete: CGKeyCode = 0x33
        static let command: CGKeyCode = 0x37, rightArrow: CGKeyCode = 0x7C
    }

    /// The lock screen's field drops events that arrive back to back. Command keys need longer.
    private static let gap: useconds_t = 12_000
    private static let characterGap: useconds_t = 4_000

    /// One key going down or up. Refuses as soon as the screen is no longer locked.
    private static func post(_ key: CGKeyCode, down: Bool, flags: CGEventFlags, characters: [UniChar],
                             from source: CGEventSource?) -> Bool {
        guard Screen.isLocked, Screen.isOnConsole,
              let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else { return false }
        event.flags = flags
        if !characters.isEmpty {
            event.keyboardSetUnicodeString(stringLength: characters.count, unicodeString: characters)
        }
        event.post(tap: .cghidEventTap)
        usleep(characters.isEmpty ? gap : characterGap)
        return true
    }

    private static func tap(_ key: CGKeyCode, flags: CGEventFlags = [], characters: [UniChar] = [],
                            from source: CGEventSource?) -> Bool {
        post(key, down: true, flags: flags, characters: characters, from: source)
            && post(key, down: false, flags: flags, characters: characters, from: source)
    }

    /// Empties the password field. Uses only keys that are the same on every keyboard layout,
    /// with Command really held down, because some fields ignore a flag on its own.
    private static func clearField(from source: CGEventSource?) -> Bool {
        let held = post(Key.command, down: true, flags: .maskCommand, characters: [], from: source)
        let cleared = held
            && tap(Key.rightArrow, flags: .maskCommand, from: source)
            && tap(Key.delete, flags: .maskCommand, from: source)
        // Always let go, so Command can't be left stuck down.
        return post(Key.command, down: false, flags: [], characters: [], from: source) && cleared
    }

    /// Clears the field, types the password one character at a time and presses Return.
    static func type(_ password: String) -> Bool {
        guard isTrusted, Screen.isLocked, Screen.isOnConsole else { return false }
        let source = CGEventSource(stateID: .hidSystemState)
        guard clearField(from: source) else { return false }
        for character in password {
            guard tap(0, characters: Array(String(character).utf16), from: source) else { return false }
        }
        return tap(Key.return, from: source)
    }
}
