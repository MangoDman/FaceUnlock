/// Whether a lock really happened. macOS announces locking and unlocking with notices that any
/// program can imitate, so each is only believed when the screen itself agrees, and an unlock
/// only counts after a lock that was seen.
struct LockTracker: Equatable {
    private(set) var isLocked = false

    /// A lock notice. True if the screen really is locked. A repeat is accepted too, so one
    /// missed unlock can't leave every later lock ignored.
    mutating func lockNotice(screenIsLocked: Bool) -> Bool {
        guard screenIsLocked else { return false }
        isLocked = true
        return true
    }

    /// An unlock notice. True only if the screen was locked and no longer is.
    mutating func unlockNotice(screenIsLocked: Bool) -> Bool {
        guard !screenIsLocked, isLocked else { return false }
        isLocked = false
        return true
    }
}
