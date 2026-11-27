import AppKit

/// The lock screen covers ordinary windows. A window can be shown over it by moving it into a
/// window-server "space" with a high level, which only private SkyLight calls can do. If Apple
/// changes them, nothing appears while locked and unlocking is unaffected.
///
/// A shown space at that level also hides the desktop's menu bar, so one exists only while the
/// screen is locked and is destroyed the moment it unlocks.
@MainActor
enum LockScreenSpace {
    /// The calls, all found or none used: a half-made space couldn't be taken down again.
    private struct SkyLight {
        let connection: @convention(c) () -> Int32
        let create: @convention(c) (Int32, Int32, Int32) -> Int32
        let setLevel: @convention(c) (Int32, Int32, Int32) -> Int32
        let show: @convention(c) (Int32, CFArray) -> Int32
        let hide: @convention(c) (Int32, CFArray) -> Int32
        let destroy: @convention(c) (Int32, Int32) -> Int32
        let moveWindows: @convention(c) (Int32, Int32, CFArray, Int32) -> Int32
        let removeWindows: @convention(c) (Int32, CFArray, CFArray) -> Int32

        init?() {
            guard let library = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)
            else { return nil }
            func find<Function>(_ name: String) -> Function? {
                dlsym(library, name).map { unsafeBitCast($0, to: Function.self) }
            }
            guard let connection: @convention(c) () -> Int32 = find("SLSMainConnectionID"),
                  let create: @convention(c) (Int32, Int32, Int32) -> Int32 = find("SLSSpaceCreate"),
                  let setLevel: @convention(c) (Int32, Int32, Int32) -> Int32 = find("SLSSpaceSetAbsoluteLevel"),
                  let show: @convention(c) (Int32, CFArray) -> Int32 = find("SLSShowSpaces"),
                  let hide: @convention(c) (Int32, CFArray) -> Int32 = find("SLSHideSpaces"),
                  let destroy: @convention(c) (Int32, Int32) -> Int32 = find("SLSSpaceDestroy"),
                  let moveWindows: @convention(c) (Int32, Int32, CFArray, Int32) -> Int32
                    = find("SLSSpaceAddWindowsAndRemoveFromSpaces"),
                  let removeWindows: @convention(c) (Int32, CFArray, CFArray) -> Int32
                    = find("SLSRemoveWindowsFromSpaces")
            else { return nil }
            self.connection = connection
            self.create = create
            self.setLevel = setLevel
            self.show = show
            self.hide = hide
            self.destroy = destroy
            self.moveWindows = moveWindows
            self.removeWindows = removeWindows
        }
    }

    private static let calls = SkyLight()
    /// The level that clears the lock screen.
    private static let level: Int32 = 400
    /// Remove the window from every kind of space it was in.
    private static let allSpaces: Int32 = 7

    private static var space: Int32?

    static var exists: Bool { space != nil }

    /// Does nothing unless the screen is locked.
    static func adopt(_ window: NSWindow) {
        guard Screen.isLocked, let calls else { return }
        let connection = calls.connection()
        let id: Int32
        if let space {
            id = space
        } else {
            id = calls.create(connection, 1, 0)
            _ = calls.setLevel(connection, id, level)
            _ = calls.show(connection, [id] as CFArray)
            space = id
        }
        _ = calls.moveWindows(connection, id, [window.windowNumber] as CFArray, allSpaces)
    }

    /// Takes the window out and tears the space down completely.
    static func destroy(_ window: NSWindow?) {
        guard let id = space, let calls else { return }
        let connection = calls.connection()
        if let window { _ = calls.removeWindows(connection, [window.windowNumber] as CFArray, [id] as CFArray) }
        _ = calls.hide(connection, [id] as CFArray)
        _ = calls.destroy(connection, id)
        space = nil
    }
}
