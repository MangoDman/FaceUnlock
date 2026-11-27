import AppKit
import AVFoundation
import CoreImage
import LocalAuthentication
import Observation
import ServiceManagement

/// Settings, enrollment and the lock-screen loop.
@MainActor @Observable
final class AppModel {
    /// How much proof of a live face is needed.
    enum Protection: String, CaseIterable, Identifiable, Codable {
        /// Rejects screens and photos it can spot. Never asks you to do anything.
        case standard
        /// Also needs proof of a live face: a blink or a natural head movement.
        case high
        /// Also asks for a head turn in a random direction.
        case maximum
        var id: String { rawValue }
    }

    private(set) var enrollment = TemplateStore.Enrollment()
    private(set) var hasPassword = false
    private(set) var cameraAuthorized = false
    private(set) var accessibilityTrusted = false
    private(set) var notificationsAllowed = false
    private(set) var passwordRequiredReason: UnlockPolicy.Reason? = .afterLaunch
    private(set) var testResult: String?
    private(set) var pausedUntil: Date?

    enum Strictness: String, CaseIterable, Identifiable, Codable {
        case balanced, strict
        var id: String { rawValue }
        var threshold: Float { self == .balanced ? 0.55 : 0.65 }
    }
    /// Kept in the keychain (see `SecuritySettings`).
    private(set) var security = SecurityStore.load() {
        didSet {
            guard security != oldValue else { return }
            SecurityStore.save(security)
            applyLimits()
        }
    }

    /// Applies a change. Anything that makes the Mac easier to open needs Touch ID or the
    /// password first, once there is something to protect.
    func propose(_ new: SecuritySettings) {
        guard new.isWeaker(than: security), isSetUp || hasPassword else {
            security = new
            return
        }
        Task {
            if await authorizeFaceChange("lower FaceUnlock’s protection") { security = new }
        }
    }

    var protection: Protection { security.protection }
    var strictness: Strictness { security.strictness }
    var requiresAttention: Bool { security.requiresAttention }
    var requiresSolitude: Bool { security.requiresSolitude }
    var usesSpoofModel: Bool { security.usesSpoofModel }
    var timeLimit: Int { security.timeLimit }
    var failureLimit: Int { security.failureLimit }
    var window: UnlockPolicy.Window { security.window }
    var adaptsToFace: Bool { security.adaptsToFace }
    /// Off by default: on a real MacBook camera it refused the owner's own face (scores -1.2 to
    /// -3.6). While off it only records its score, so it can be judged before it's trusted.
    /// The public build leaves the anti-spoofing model out, and its controls with it.
    /// `--demo` shows the app as the public build does, for the website’s screenshots.
    static let hasSpoofModel = !LaunchOptions.has("--demo")
        && Bundle.main.url(forResource: "AntiSpoof", withExtension: "mlmodelc") != nil
    enum AlertStyle: String, CaseIterable, Identifiable {
        case notch, notificationCenter, both
        var id: String { rawValue }
    }
    var alertStyle = AlertStyle(rawValue: UserDefaults.standard.string(forKey: "alertStyle") ?? "") ?? .notch {
        didSet { UserDefaults.standard.set(alertStyle.rawValue, forKey: "alertStyle") }
    }
    private var alertsInNotch: Bool { alertStyle != .notificationCenter }
    private var alertsInCenter: Bool { alertStyle != .notch }

    enum Preview: CaseIterable { case unlock, paused, attempts, walkAway, success, failure }

    /// Shows what an alert looks like, without changing anything.
    func preview(_ kind: Preview) {
        notch.forcedKind = previewKind
        // Back to the real screen once the preview has gone.
        Task {
            try? await Task.sleep(for: .seconds(9))
            notch.forcedKind = nil
        }
        switch kind {
        case .unlock:
            // The whole unlock, as it looks at the lock screen.
            notch.show(.scanning)
            Task {
                try? await Task.sleep(for: .seconds(1.8))
                notch.show(.success(nil), for: 1.4)
            }
        case .paused:
            notch.show(.prompt(title: "Face Unlock Paused", message: UnlockPolicy.Reason.timedOut.message), for: 8)
        case .attempts: showAttempts(2)
        case .walkAway:
            notch.show(.notice(symbol: "figure.walk.departure", title: "Locking in 5 Seconds",
                               message: "You’ve stepped away. Move the pointer to stay."), for: 4)
        case .success:
            notch.show(.success(nil), for: 2)
        case .failure:
            notch.show(.failure("Face Not Recognized"), for: 3)
        }
    }

    private func showAttempts(_ count: Int) {
        notch.show(.notice(symbol: "person.crop.circle.badge.exclamationmark",
                           title: count == 1 ? "1 Unrecognized Attempt" : "\(count) Unrecognized Attempts",
                           message: "While your Mac was locked."), for: 8)
    }

    var notchStyle = NotchState.Preference(rawValue: UserDefaults.standard.string(forKey: "notchStyle") ?? "") ?? .automatic {
        didSet { UserDefaults.standard.set(notchStyle.rawValue, forKey: "notchStyle") }
    }
    var notchFollowsPointer = UserDefaults.standard.bool(forKey: "notchFollowsPointer") {
        didSet { UserDefaults.standard.set(notchFollowsPointer, forKey: "notchFollowsPointer") }
    }
    /// Settings previews can pretend to be another kind of Mac. Nil is this one.
    var previewKind: ScreenKind?
    var showsNotch = UserDefaults.standard.object(forKey: "showsNotch") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showsNotch, forKey: "showsNotch") }
    }
    var reportsAttempts = UserDefaults.standard.object(forKey: "reportsAttempts") as? Bool ?? true {
        didSet { UserDefaults.standard.set(reportsAttempts, forKey: "reportsAttempts") }
    }
    /// Seconds without input before checking whether you've left. 0 is off.
    var walkAwayDelay = UserDefaults.standard.integer(forKey: "walkAway") {
        didSet { UserDefaults.standard.set(walkAwayDelay, forKey: "walkAway") }
    }
    let history = History()
    var isPaused: Bool { pausedUntil.map { $0 > .now } ?? false }

    var isEnabled = UserDefaults.standard.bool(forKey: "enabled") {
        didSet {
            if isEnabled != oldValue { Sounds.play(isEnabled ? .on : .off) }
            UserDefaults.standard.set(isEnabled, forKey: "enabled")
            if isEnabled, !oldValue {
                Task {
                    notificationsAllowed = await notifier.requestPermission()
                    refresh()
                }
            }
            syncNotifications()
        }
    }
    var captureStyle = CaptureStyle(rawValue: UserDefaults.standard.string(forKey: "captureStyle") ?? "") ?? .arcs {
        didSet { UserDefaults.standard.set(captureStyle.rawValue, forKey: "captureStyle") }
    }
    var hapticOnUnlock = UserDefaults.standard.object(forKey: "haptic") as? Bool ?? true {
        didSet { UserDefaults.standard.set(hapticOnUnlock, forKey: "haptic") }
    }
    var keepAwake = UserDefaults.standard.bool(forKey: "keepAwake") {
        didSet { UserDefaults.standard.set(keepAwake, forKey: "keepAwake") }
    }
    /// The latest clear capture from the lock screen, waiting for an unlock to vouch for it.
    private var candidate: (vector: [Float], date: Date)?
    var soundEffects = Sounds.isOn {
        didSet {
            Sounds.isOn = soundEffects
            if soundEffects, !oldValue { Sounds.play(.on) }
        }
    }
    var soundVolume = Sounds.volume {
        didSet { Sounds.volume = soundVolume }
    }

    private func applyLimits() {
        policy.window = window
        policy.timeout = TimeInterval(min(max(timeLimit, 5), 180) * 60)
        policy.maximumFailures = min(max(failureLimit, 1), 5)
        refresh()
        syncNotifications()
    }

    var launchAtLogin = SMAppService.mainApp.status == .enabled {
        didSet {
            guard launchAtLogin != (SMAppService.mainApp.status == .enabled) else { return }
            do {
                if launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                launchAtLogin = SMAppService.mainApp.status == .enabled
            }
        }
    }

    var isSetUp: Bool { !enrollment.primary.isEmpty }
    var isReady: Bool {
        isEnabled && isSetUp && hasPassword && cameraAuthorized && accessibilityTrusted && !isPaused
    }
    var needsAuthentication: Bool { isReady && passwordRequiredReason != nil }

    /// macOS would ask before handing over something saved, which can't happen at the lock screen.
    private(set) var needsKeychainAccess = false
    private var askedForKeychain = false
    /// Opens the step-by-step guide. Set by the app delegate, which owns the windows.
    @ObservationIgnored var onGuide: (() -> Void)?
    @ObservationIgnored var onSettings: ((SettingsPane) -> Void)?
    /// Called after an unlock, so the guide can come back to the front.
    @ObservationIgnored var onUnlocked: (() -> Void)?
    /// When your face last unlocked the Mac. The guide waits for this when you try it.
    private(set) var lastFaceUnlock: Date?
    private var clearedPermissions: Set<String> = []

    /// What stands between you and a face unlock, most pressing first. The status line says it,
    /// and the button beside it fixes it.
    enum Need {
        case keychain, face, switchedOff, paused, camera, password, accessibility, authentication

        var button: String {
            switch self {
            case .keychain: "Allow Keychain Access…"
            case .face: "Set Up Face…"
            case .switchedOff: "Turn On"
            case .paused: "Resume"
            case .camera: "Allow Camera…"
            case .password: "Add Password…"
            case .accessibility: "Allow Accessibility…"
            case .authentication: "Use Touch ID…"
            }
        }

        var symbol: String {
            switch self {
            case .keychain: "key"
            case .face: "viewfinder"
            case .switchedOff: "power"
            case .paused: "play"
            case .camera: "camera"
            case .password: "lock"
            case .accessibility: "accessibility"
            case .authentication: "touchid"
            }
        }
    }

    var need: Need? {
        if needsKeychainAccess { return .keychain }
        if !isSetUp { return .face }
        if !isEnabled { return .switchedOff }
        if isPaused { return .paused }
        if !cameraAuthorized { return .camera }
        if !hasPassword { return .password }
        if !accessibilityTrusted { return .accessibility }
        if passwordRequiredReason != nil { return .authentication }
        return nil
    }

    var statusText: String {
        switch need {
        case .keychain: "Keychain access needed"
        case .face: "Not set up"
        case .switchedOff: "Off"
        case .paused: "Paused until \(pausedUntil?.formatted(date: .omitted, time: .shortened) ?? "")"
        case .camera: "Camera access needed"
        case .password: "Password needed"
        case .accessibility: "Accessibility access needed"
        case .authentication: "Paused. Touch ID or password needed"
        case nil: "Ready"
        }
    }

    /// Does whatever the button beside the status says. `setUp` opens the setup window.
    func resolve(_ need: Need, setUp: (Appearance) -> Void) {
        switch need {
        case .keychain: requestKeychainAccess()
        case .face, .password: setUp(.primary)
        case .switchedOff:
            // The switch needs these first; setup collects whatever is missing.
            if hasPassword, accessibilityTrusted { isEnabled = true } else { setUp(.primary) }
        case .paused: resume()
        case .camera: allowCamera()
        case .accessibility: allowAccessibility()
        case .authentication: confirmWithTouchID()
        }
    }

    let camera = CameraService()
    let notch = NotchPresenter()
    let embedder = try? FaceEmbedder()
    private let notifier = Notifier()
    private let analyzer = FaceAnalyzer()
    private let store = TemplateStore()
    private var policy = UnlockPolicy()
    private var screen = LockTracker()
    private let display = DisplayHold()

    private var scanTask: Task<Void, Never>?
    private var cameraOwner: UUID?
    private var cameraFeed: AsyncStream<Frame>.Continuation?
    private var lockLoop: Task<Void, Never>?
    private var monitorLoop: Task<Void, Never>?
    private var attempt: Task<Void, Never>?
    private var wakePending = false
    private var asleep = false
    private var typedAt: Date?
    private var promptedFor: UnlockPolicy.Reason?
    private var authenticating = false
    private var strangerAttempts = 0

    func pause(for duration: TimeInterval) {
        Sounds.play(.off)
        pausedUntil = .now.addingTimeInterval(duration)
        history.add(.paused, "Paused until \(pausedUntil!.formatted(date: .omitted, time: .shortened))")
        refresh()
    }

    func resume() {
        Sounds.play(.on)
        pausedUntil = nil
        refresh()
    }

    func start() {
        Sounds.prepare()
        policy.window = window
        policy.timeout = TimeInterval(min(max(timeLimit, 5), 180) * 60)
        policy.maximumFailures = min(max(failureLimit, 1), 5)
        // Never write over choices that couldn't be read.
        if !SecurityStore.needsPermission { SecurityStore.save(security) }
        screen = LockTracker()
        if Screen.isLocked { _ = screen.lockNotice(screenIsLocked: true) }
        enrollment = store.load()
        // Anything macOS wants to ask about is asked now, at the desktop, not at the lock screen.
        if !Screen.isLocked, ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            _ = PasswordVault.load()
        }
        checkKeychain()
        refresh()
        EventLog.write("App started. Enabled \(isEnabled), set up \(isSetUp), password \(hasPassword), camera \(cameraAuthorized), accessibility \(accessibilityTrusted)")

        notifier.activate()
        notifier.onConfirm = { [weak self] in self?.confirmWithTouchID() }
        notifier.showsBanner = { [weak self] in
            // The scheduled reminder arrived: show it in the notch if that's the choice.
            self?.promptIfNeeded()
            return self?.alertsInCenter ?? true
        }
        notch.state.onConfirm = { [weak self] in self?.confirmWithTouchID() }
        notch.state.onDismiss = { [weak self] in self?.notch.collapse() }

        // Coming back from System Settings: look again straight away.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.recheckKeychain()
                self?.refresh()
            }
        }

        let center = DistributedNotificationCenter.default()
        func observe(_ name: String, _ action: @escaping @MainActor (AppModel) -> Void) {
            center.addObserver(forName: .init(name), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if let self { action(self) } }
            }
        }
        // Any program can post these, so each is checked against the screen itself.
        observe("com.apple.screenIsLocked") { $0.verify(locked: true) }
        observe("com.apple.screenIsUnlocked") { $0.verify(locked: false) }
        observe("com.apple.screensaver.didstop") { $0.woke("screen saver stopped") }

        let workspace = NSWorkspace.shared.notificationCenter
        func observeWorkspace(_ name: NSNotification.Name, _ action: @escaping @MainActor (AppModel) -> Void) {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if let self { action(self) } }
            }
        }
        observeWorkspace(NSWorkspace.screensDidWakeNotification) { $0.woke("display woke") }
        observeWorkspace(NSWorkspace.didWakeNotification) { $0.woke("Mac woke") }
        observeWorkspace(NSWorkspace.willSleepNotification) {
            $0.asleep = true
            $0.attempt?.cancel()
        }

        monitorLoop = Task { [weak self] in
            self?.notificationsAllowed = await self?.notifier.isAllowed() ?? false
            try? await Task.sleep(for: .seconds(1.5))
            while !Task.isCancelled {
                self?.promptIfNeeded()
                await self?.checkPresence()
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    func refresh() {
        let camera = CameraService.isAuthorized, accessibility = PasswordTyper.isTrusted
        // Written down, so "no tick" can be checked against what macOS actually said.
        if camera != cameraAuthorized { EventLog.write("Camera allowed: \(camera)") }
        if accessibility != accessibilityTrusted { EventLog.write("Accessibility allowed: \(accessibility)") }
        cameraAuthorized = camera
        accessibilityTrusted = accessibility
        hasPassword = PasswordVault.hasPassword
        passwordRequiredReason = policy.passwordRequired(at: .now)
    }

    func refreshNotificationStatus() async { notificationsAllowed = await notifier.isAllowed() }

    // MARK: Needing the password again

    private func syncNotifications() {
        notifier.cancelScheduled()
        if isEnabled, isSetUp, let expiry = policy.expiry { notifier.schedule(at: expiry) }
    }

    /// While unlocked, offer Touch ID as soon as face unlock stops working.
    private func promptIfNeeded() {
        refresh()
        guard needsAuthentication, let reason = passwordRequiredReason, !Screen.isLocked, !authenticating,
              promptedFor != reason else { return }
        promptedFor = reason
        EventLog.write("Asking for authentication: \(reason)")
        if alertsInCenter { notifier.post(reason) }
        if alertsInNotch {
            notch.show(.prompt(title: "Face Unlock Paused", message: reason.message), for: 20)
        }
    }

    /// Touch ID (or the password, in Apple's own dialog) counts as a recent authentication.
    func confirmWithTouchID() {
        guard !authenticating, !Screen.isLocked else { return }
        authenticating = true
        notch.collapse()
        Task {
            defer { authenticating = false }
            let context = LAContext()
            let ok = (try? await context.evaluatePolicy(.deviceOwnerAuthentication,
                                                        localizedReason: "turn Face Unlock back on")) ?? false
            EventLog.write("Touch ID confirmation \(ok ? "succeeded" : "cancelled or failed")")
            guard ok else { return }
            policy.authenticated(at: .now)
            promptedFor = nil
            notifier.clear()
            syncNotifications()
            refresh()
            notch.show(.success("Face Unlock Is On"), for: 1.8)
        }
    }

    // MARK: Camera

    private typealias Frame = (result: FaceAnalyzer.Result, vector: [Float]?, time: TimeInterval)

    /// Runs the camera until `handle` returns false, the task is cancelled or `timeout` passes,
    /// then switches it off. One consumer at a time: starting a new one ends the previous one.
    func watch(liveness: Bool = false, spoofScore: Bool = false, timeout: TimeInterval? = nil,
               _ handle: (FaceAnalyzer.Result, [Float]?, TimeInterval) -> Bool) async {
        cameraFeed?.finish()
        let (stream, feed) = AsyncStream.makeStream(of: Frame.self, bufferingPolicy: .bufferingNewest(1))
        let owner = UUID()
        cameraOwner = owner
        cameraFeed = feed
        let analyzer = analyzer, embedder = embedder
        camera.start { pixels, time in
            let result = analyzer.analyze(pixels, liveness: liveness, spoofScore: spoofScore)
            let vector = result.points.flatMap { embedder?.embedding(for: pixels, points: $0) }
            feed.yield((result, vector, time))
        }
        // A camera that delivers nothing must not leave a scan hanging.
        let watchdog = timeout.map { limit in
            Task {
                try? await Task.sleep(for: .seconds(limit))
                if !Task.isCancelled { feed.finish() }
            }
        }
        defer {
            watchdog?.cancel()
            feed.finish()
            // Only the current owner may switch the camera off.
            if cameraOwner == owner { camera.stop() }
        }
        for await frame in stream {
            if Task.isCancelled || !handle(frame.result, frame.vector, frame.time) { break }
        }
    }

    // MARK: Permissions

    /// How many of the things it needs are still missing.
    var stepsLeft: Int {
        [isSetUp, hasPassword, cameraAuthorized, accessibilityTrusted, !needsKeychainAccess,
         isEnabled && isSetUp].filter { !$0 }.count
    }

    /// Worth showing the checklist unasked: a new install, or switched on but unable to work.
    var needsPermissionsAttention: Bool {
        (!isSetUp && !hasPassword) || needsKeychainAccess || (isEnabled && !(cameraAuthorized && accessibilityTrusted))
    }

    func allowCamera() {
        Task {
            let before = AVCaptureDevice.authorizationStatus(for: .video)
            if before == .notDetermined { _ = await CameraService.requestAccess() }
            if !CameraService.isAuthorized {
                // Never answered, or answered for an earlier version: clear that and ask afresh.
                let stale = before != .notDetermined || AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined
                if stale, await forgetPermission("Camera") { _ = await CameraService.requestAccess() }
                if !CameraService.isAuthorized { openPrivacySettings("Privacy_Camera") }
            }
            refresh()
        }
    }

    func allowAccessibility() {
        Task {
            if !PasswordTyper.isTrusted {
                _ = await forgetPermission("Accessibility")
                // Puts FaceUnlock in the list, ready to be switched on.
                PasswordTyper.requestTrust()
                openPrivacySettings("Privacy_Accessibility")
            }
            refresh()
        }
    }

    func allowNotifications() {
        Task {
            notificationsAllowed = await notifier.requestPermission()
            if !notificationsAllowed {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
            }
        }
    }

    /// After an update macOS can hold a permission for the previous copy: it looks switched on
    /// but isn't. Clearing FaceUnlock's own entry lets macOS ask properly. This only takes access
    /// away; giving it is still up to you.
    /// Once per run only. A second click must never take away what was just switched on.
    private func forgetPermission(_ service: String) async -> Bool {
        guard let identifier = Bundle.main.bundleIdentifier, clearedPermissions.insert(service).inserted else { return false }
        await Task.detached {
            let reset = Process()
            reset.executableURL = URL(filePath: "/usr/bin/tccutil")
            reset.arguments = ["reset", service, identifier]
            try? reset.run()
            reset.waitUntilExit()
        }.value
        EventLog.write("Cleared the old \(service) permission before asking again")
        return true
    }

    /// macOS only remembers permissions properly for a copy in Applications.
    var isInApplications: Bool {
        let path = Bundle.main.bundlePath
        return path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/")
    }

    private func openPrivacySettings(_ section: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(section)")!)
    }

    func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            guard error == nil else { return }
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }

    // MARK: Keychain access

    /// Looks, without asking anything, whether everything saved can be read.
    private func checkKeychain() {
        let needed = store.needsPermission || PasswordVault.needsPermission || SecurityStore.needsPermission
        if needed != needsKeychainAccess {
            EventLog.write(needed ? "Keychain access needed: choose Always Allow when macOS asks" : "Keychain access allowed")
        }
        needsKeychainAccess = needed
    }

    /// For the Permissions page: notices when access was given since the last look.
    func recheckKeychain() {
        guard needsKeychainAccess, !Screen.isLocked else { return }
        checkKeychain()
        if !needsKeychainAccess, enrollment.primary.isEmpty { enrollment = store.load() }
        refresh()
    }

    /// Lets macOS show its prompts. Only ever at the desktop, where they can be seen.
    func requestKeychainAccess() {
        guard !Screen.isLocked else { return }
        let securityWasHidden = SecurityStore.needsPermission
        NSApp.activate()
        store.requestAccess()
        _ = PasswordVault.load()
        if securityWasHidden { security = SecurityStore.load() }
        if enrollment.primary.isEmpty { enrollment = store.load() }
        checkKeychain()
        refresh()
        syncNotifications()
    }

    private func showKeychainNotice() {
        needsKeychainAccess = true
        EventLog.write("Not scanning: keychain access needed")
        notch.show(.notice(symbol: "key.fill", title: "Keychain Access Needed",
                           message: "Sign in, then choose Always Allow."), for: 5)
    }

    // MARK: Enrollment and password

    /// Scanning the main face again starts over; the others are added beside it.
    func saveEnrollment(_ templates: [[Float]], as appearance: Appearance) throws {
        var updated = appearance == .primary ? .init() : enrollment
        updated[appearance] = templates
        // A new setup scan starts the updates again.
        updated.learned = nil
        try store.save(updated)
        enrollment = updated
        EventLog.write("Saved \(templates.count) face templates (\(appearance.rawValue))")
    }

    /// Verifies and stores the login password. Typing it correctly counts as a recent authentication.
    func savePassword(_ password: String) -> Bool {
        guard PasswordVault.verify(password), PasswordVault.save(password) else { return false }
        policy.authenticated(at: .now)
        promptedFor = nil
        refresh()
        syncNotifications()
        return true
    }

    /// Anyone who can add a face can unlock the Mac, so changing face data needs the owner.
    func authorizeFaceChange(_ reason: String) async -> Bool {
        guard !authenticating, !Screen.isLocked else { return false }
        authenticating = true
        defer { authenticating = false }
        let ok = (try? await LAContext().evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
        EventLog.write("Face data change \(ok ? "allowed" : "cancelled or refused")")
        return ok
    }

    func remove(_ appearance: Appearance) {
        guard appearance != .primary else { return }
        Task {
            guard await authorizeFaceChange("remove an appearance") else { return }
            var updated = enrollment
            updated[appearance] = []
            // Updates may have been learned from the appearance that is going.
            updated.learned = nil
            save(updated)
        }
    }

    func removePassword() {
        PasswordVault.remove()
        isEnabled = false
        refresh()
    }

    func reset() {
        scanTask?.cancel()
        attempt?.cancel()
        store.erase()
        PasswordVault.remove()
        enrollment = .init()
        candidate = nil
        isEnabled = false
        refresh()
    }

    // MARK: Keeping face data current

    func forgetUpdates() {
        var updated = enrollment
        updated.learned = nil
        save(updated)
    }

    private func save(_ updated: TemplateStore.Enrollment) {
        do {
            try store.save(updated)
            enrollment = updated
        } catch {
            EventLog.write("Face data could not be saved")
        }
    }

    /// Called on every unlock: the unlock is what says the capture was really you.
    private func learnFromUnlock(byFace: Bool) {
        defer { candidate = nil }
        guard adaptsToFace, isSetUp, let candidate,
              Date.now.timeIntervalSince(candidate.date) < FaceAdaptation.confirmationWindow else { return }
        var updated = enrollment
        if byFace { updated.recordMatch(candidate.vector, at: .now) }
        let proof: FaceAdaptation.Proof = byFace ? .faceMatch(threshold: strictness.threshold) : .password
        let added = updated.learn(candidate.vector, proof: proof, at: .now)
        guard updated != enrollment else { return }
        save(updated)
        if added {
            EventLog.write("Face data updated after \(byFace ? "a face unlock" : "password or Touch ID") "
                + "(\(updated.updates.count) updates kept)")
        }
    }

    /// For `--snapshots --demo` only: nothing is saved.
    func showSampleAppearances() {
        guard LaunchOptions.has("--snapshots"), LaunchOptions.has("--demo") else { return }
        enrollment = .init(primary: [[1]])
        enrollment[.glasses] = [[1]]
    }

    // MARK: Lock screen

    private func woke(_ why: String) {
        asleep = false
        if Screen.isLocked {
            EventLog.write("Wake: \(why)")
            wakePending = true
        }
    }

    private func verify(locked expected: Bool) {
        Task {
            // The session's own flag can lag the notice by a moment.
            for _ in 0..<30 where Screen.isLocked != expected {
                try? await Task.sleep(for: .milliseconds(100))
            }
            let actual = Screen.isLocked
            if expected {
                if screen.lockNotice(screenIsLocked: actual) { screenLocked() }
            } else if screen.unlockNotice(screenIsLocked: actual) {
                screenUnlocked()
            } else {
                EventLog.write("Ignored an unlock notice: the screen was not locked and then unlocked")
            }
        }
    }

    private func screenLocked() {
        candidate = nil
        policy.locked(at: .now)
        scanTask?.cancel()
        refresh()
        syncNotifications()
        wakePending = false
        EventLog.write("Screen locked. \(statusText)")
        guard isReady else { return }
        Sounds.play(.lock)

        // Get the camera and the model ready now, so the first scan doesn't wait for them.
        camera.prepare()
        let embedder = embedder
        Task.detached(priority: .utility) {
            _ = embedder?.embedding(forAligned: CIImage(color: .gray)
                .cropped(to: CGRect(x: 0, y: 0, width: 112, height: 112)))
        }
        // Hovering the notch is a retry.
        notch.arm { [weak self] in self?.beginAttempt("notch hover") }
        let lockedAt = Date.now
        lockLoop?.cancel()
        lockLoop = Task { [weak self] in
            var armedForInput = true
            while !Task.isCancelled, Screen.isLocked {
                try? await Task.sleep(for: .milliseconds(150))
                guard let self else { return }
                let sinceLock = Date.now.timeIntervalSince(lockedAt)
                guard sinceLock > 1, !asleep, Screen.builtInDisplayIsActive else {
                    armedForInput = true
                    continue
                }
                if Screen.userIdleTime > 2 { armedForInput = true }
                // Never unlock just because the screen was locked: wait for a wake or fresh input.
                if wakePending {
                    wakePending = false
                    armedForInput = false
                    beginAttempt("wake")
                } else if armedForInput, Screen.userIdleTime < min(0.8, sinceLock - 1) {
                    armedForInput = false
                    beginAttempt("input")
                }
            }
        }
    }

    private func screenUnlocked() {
        lockLoop?.cancel()
        scanTask?.cancel()
        display.release()
        let byFace = typedAt.map { Date.now.timeIntervalSince($0) < 8 } ?? false
        notch.leaveLockScreen()
        EventLog.write("Screen unlocked by \(byFace ? "face" : "password or Touch ID")")
        learnFromUnlock(byFace: byFace)
        defer { onUnlocked?() }
        if byFace {
            lastFaceUnlock = .now
            history.add(.faceUnlock)
            policy.faceUnlocked()
            // Nothing more to show: the success animation has already played at the lock screen.
        } else {
            attempt?.cancel()
            history.add(.passwordUnlock)
            policy.authenticated(at: .now)
            promptedFor = nil
            notifier.clear()
            notch.disarm()
        }
        if strangerAttempts > 0, reportsAttempts, !byFace {
            let count = strangerAttempts
            if alertsInCenter { notifier.reportAttempts(count) }
            if alertsInNotch {
                Task {
                    try? await Task.sleep(for: .seconds(1))
                    showAttempts(count)
                }
            }
        }
        strangerAttempts = 0
        typedAt = nil
        refresh()
        syncNotifications()
        // A typing failure found at the lock screen is explained once you're back.
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            // Once. After that it waits for the Allow button rather than asking at every unlock.
            if needsKeychainAccess, !askedForKeychain {
                askedForKeychain = true
                requestKeychainAccess()
            }
            promptIfNeeded()
        }
    }

    private func beginAttempt(_ trigger: String) {
        guard attempt == nil, Screen.isLocked, Screen.isOnConsole else { return }
        refresh()
        // Found out before looking, not after, so nothing starts that can't finish.
        if isEnabled, PasswordVault.needsPermission { return showKeychainNotice() }
        // Allowed since the last look.
        if needsKeychainAccess { checkKeychain() }
        guard isReady else {
            EventLog.write("Not scanning: \(statusText)")
            return
        }
        if let reason = passwordRequiredReason {
            EventLog.write("Not scanning: \(reason)")
            notch.show(.passwordRequired, for: 3)
            // When the time limit has passed, look without unlocking, so the password that
            // follows can bring the face data up to date.
            if reason == .timedOut, adaptsToFace {
                attempt = Task { [weak self] in
                    _ = await self?.recognize(learns: true, silent: true)
                    self?.attempt = nil
                }
            }
            return
        }
        EventLog.write("Scanning (\(trigger))")
        attempt = Task { [weak self] in
            await self?.runAttempt()
            self?.attempt = nil
        }
    }

    private func runAttempt() async {
        notch.forcedKind = nil
        if showsNotch { notch.show(.scanning) }
        display.hold(for: 30)
        let scan = await recognize(learns: true)
        EventLog.write("Scan finished: \(scan.summary)")
        refresh()
        guard Screen.isLocked, !Task.isCancelled else { return display.release() }
        // Someone is there and didn't get in: time to read why and try again. Nobody: let it sleep.
        if scan.outcome == .noFace { display.release() } else { display.hold(for: 20) }
        defer {
            // The last attempt allowed has just been used.
            if scan.charged, scan.outcome != .recognized, let reason = passwordRequiredReason {
                syncNotifications()
                notifier.post(reason)
                notch.show(.passwordRequired, for: 4)
            }
        }
        switch scan.outcome {
        case .recognized:
            // Don't type over someone who is typing their own password.
            guard Screen.keyboardIdleTime > 0.6, let password = PasswordVault.load() else {
                EventLog.write("Not typing: keyboard in use or password unavailable")
                notch.collapse()
                return
            }
            // The tick is drawn and seen at the lock screen before anything unlocks.
            if showsNotch {
                await notch.showSuccess()
            } else {
                Sounds.play(.unlock)
                try? await Task.sleep(for: .milliseconds(100))
            }
            // Unlocked some other way in the meantime: that isn't a typing failure.
            guard Screen.isLocked, !Task.isCancelled else { return }
            // Someone may have started typing while the tick was showing.
            guard Screen.keyboardIdleTime > NotchPresenter.successHold else {
                EventLog.write("Not typing: keyboard in use")
                notch.collapse()
                return
            }
            typedAt = .now
            let typed = await Task.detached(priority: .userInitiated) { PasswordTyper.type(password) }.value
            EventLog.write(typed ? "Password typed" : "Typing could not be completed")
            // Success has been shown: put the notch away as the lock screen leaves.
            notch.disarm()
            try? await Task.sleep(for: .seconds(3.5))
            guard Screen.isLocked, !Task.isCancelled else { return }
            // Never retry a password that didn't work; repeated failures can lock the account.
            EventLog.write("Still locked after typing: pausing until a manual unlock")
            typedAt = nil
            policy.typingDidFail()
            history.add(.typingFailed)
            notifier.post(.typingFailed)
            notch.show(.passwordRequired, for: 4)
            refresh()
        case .notRecognized:
            history.add(.rejected, scan.summary)
            strangerAttempts += 1
            reject("Face Not Recognized", counted: scan.charged)
        case .spoof:
            history.add(.spoof, scan.summary)
            strangerAttempts += 1
            reject("Couldn’t Confirm a Live Face", counted: scan.charged)
        case .noLiveness:
            history.add(.noLiveness, scan.summary)
            notch.show(.failure("Blink or Turn Your Head"), for: 6)
        case .notAlone:
            history.add(.rejected, "Someone else was in view")
            notch.show(.failure("Someone Else Is in View"), for: 5)
        case .notAttentive:
            history.add(.noLiveness, "Not looking at the screen")
            notch.show(.failure("Look at the Screen"), for: 6)
        case .noFace, .scanning:
            notch.collapse()
        }
    }

    private func reject(_ message: String, counted: Bool) {
        if !counted { policy.faceRejected() }
        refresh()
        syncNotifications()
        if let reason = passwordRequiredReason {
            notifier.post(reason)
            notch.show(.passwordRequired, for: 4)
        } else {
            notch.show(.failure(message), for: 6)
        }
    }

    private struct Scan {
        var outcome = UnlockScanner.Outcome.noFace
        var best: Float = -1
        var frames = 0
        var threshold: Float = 0
        var cue: String?
        var modelScore: Float?
        var seconds: Double = 0
        var heldBack: FaceSample?
        /// An attempt has already been counted against the limit.
        var charged = false

        var summary: String {
            let score = best < 0 ? "no face" : String(format: "best match %.2f of %.2f needed", best, threshold)
            let pose = outcome == .notAttentive ? heldBack.map {
                String(format: ", turned %.2f, tilt %.2f, eyes %.2f", $0.yaw, $0.pitch, $0.eyeOpenness)
            } : nil
            return "\(outcome), \(score), \(frames) frames in \(String(format: "%.1f", seconds)) s" + (pose ?? "")
                + (cue.map { ", \($0)" } ?? "")
                + (modelScore.map { String(format: ", anti-spoof %+.1f", $0) } ?? "")
        }
    }

    /// Shared by real unlocking and Test Recognition. `learns` keeps a capture for
    /// `learnFromUnlock`; `silent` shows no prompts.
    private func recognize(learns: Bool = false, silent: Bool = false) async -> Scan {
        var scanner = UnlockScanner(rules: .init(
            threshold: strictness.threshold, requiresAttention: requiresAttention,
            requiresSolitude: requiresSolitude, usesSpoofModel: usesSpoofModel && analyzer.hasSpoofModel,
            challenge: protection == .maximum ? (Bool.random() ? .left : .right) : nil))
        var liveness = LivenessMonitor(requiresProof: protection != .standard)
        var state = UnlockScanner.Liveness.pending
        var scan = Scan(threshold: scanner.rules.threshold)
        if adaptsToFace { enrollment.expireUpdates(at: .now) }
        let setup = enrollment.all
        let templates = setup + (adaptsToFace ? enrollment.updates.map(\.vector) : [])
        var hint: String?
        let started = Date.now
        // The experimental model costs time on every frame: run it only when it is used, or in
        // Test Recognition, which reports its score.
        let scoresModel = usesSpoofModel || !learns

        await watch(liveness: true, spoofScore: scoresModel, timeout: scanner.rules.timeout + 9) { result, vector, time in
            scan.frames += 1
            if let frame = result.liveness {
                switch liveness.observe(frame, at: time) {
                case .undecided: state = .pending
                case .live(let proof):
                    state = .confirmed
                    if let proof { scan.cue = "live via \(proof.rawValue)" }
                case .spoof(let sign):
                    state = .denied
                    scan.cue = "rejected by \(sign.rawValue)"
                }
            }
            let similarity = vector.map { FaceMath.bestSimilarity($0, in: templates) }
            scan.best = max(scan.best, similarity ?? -1)
            scan.outcome = scanner.process(result.sample, box: result.box, similarity: similarity,
                                           liveness: state, modelScore: result.modelScore, at: time)
            scan.modelScore = scanner.spoofScore ?? scan.modelScore
            if scanner.faceChanged {
                liveness.reset()
                state = .pending
                if learns { self.candidate = nil }
            }
            if learns {
                let sample = result.sample
                if scan.outcome == .spoof || scan.outcome == .notAlone {
                    self.candidate = nil
                } else if let vector, sample.faceCount == 1, !sample.isTooDark, sample.size >= 0.2,
                          sample.isFacingScreen, sample.eyeOpenness > 0.12,
                          FaceMath.bestSimilarity(vector, in: setup) >= FaceAdaptation.floor {
                    self.candidate = (vector, .now)
                }
            }
            // Counted the moment the owner's face is recognised, and given back by a real
            // unlock. So trying again and again with a recording, or giving up part way, can't
            // dodge the limit.
            if learns, !silent, scanner.reachedIdentity, !scan.charged {
                scan.charged = true
                self.policy.faceRejected()
            }
            guard scan.outcome == .scanning else { return false }
            // The challenge must be visible even with the animation turned off.
            let next = scanner.challengePrompt?.instruction
                ?? (scanner.needsLiveness ? "Blink or Turn Your Head" : nil)
            if !silent, let next, next != hint {
                hint = next
                notch.show(.hint(next))
            }
            return true
        }
        // The watchdog ended it before the scanner could decide.
        if scan.outcome == .scanning { scan.outcome = .noFace }
        if scan.frames == 0 { scan.cue = "the camera delivered no frames" }
        scan.seconds = Date.now.timeIntervalSince(started)
        scan.heldBack = scanner.heldBack
        return scan
    }

    /// Runs a real scan while unlocked. Shows the notch animation and the score; types nothing.
    func testRecognition() {
        guard isSetUp else { return }
        scanTask?.cancel()
        testResult = "Looking…"
        scanTask = Task {
            guard await CameraService.requestAccess() else {
                testResult = "Camera access is off."
                return
            }
            notch.show(.scanning)
            let scan = await recognize()
            if Task.isCancelled { return }
            EventLog.write("Test: \(scan.summary)")
            switch scan.outcome {
            case .recognized:
                notch.show(.success(nil), for: 1.8)
                testResult = "Recognized: \(scan.summary). Nothing was typed."
            case .noLiveness:
                notch.show(.failure("Blink or Turn Your Head"), for: 2.5)
                testResult = "Your face matched, but nothing proved it was live: \(scan.summary)."
            case .notAttentive:
                notch.show(.failure("Look at the Screen"), for: 2.5)
                testResult = "Your face matched, but you weren’t looking at the screen: \(scan.summary)."
            default:
                notch.show(.failure(scan.outcome == .spoof ? "Couldn’t Confirm a Live Face" : "Face Not Recognized"), for: 2.5)
                testResult = "Not recognized: \(scan.summary)."
            }
            refresh()
        }
    }

    // MARK: While unlocked

    /// When you've been still for a while, takes a brief look: keeps the display awake if you're
    /// still there, or locks the Mac if you've gone.
    private func checkPresence() async {
        let idle = Screen.userIdleTime
        let wantsLock = walkAwayDelay > 0 && idle > Double(walkAwayDelay)
        let wantsAwake = keepAwake && idle > 60
        guard wantsLock || wantsAwake, cameraAuthorized, !Screen.isLocked, Screen.builtInDisplayIsActive,
              !camera.session.isRunning, isSetUp else { return }
        guard let present = await someoneIsThere() else { return }
        if present {
            if wantsAwake { Screen.declareUserActivity() }
            return
        }
        guard wantsLock else { return }
        // Warn first, and look again: any input cancels.
        notch.show(.notice(symbol: "figure.walk.departure", title: "Locking in 5 Seconds",
                           message: "You’ve stepped away. Move the pointer to stay."))
        try? await Task.sleep(for: .seconds(5))
        guard Screen.userIdleTime > 5, await someoneIsThere() == false, Screen.userIdleTime > 5 else {
            notch.collapse()
            return
        }
        notch.collapse()
        history.add(.walkAway)
        EventLog.write("Locked because nobody was in view")
        Screen.lockNow()
    }

    /// Nil if the camera gave nothing usable (covered, busy or too dark), so nothing is assumed.
    private func someoneIsThere() async -> Bool? {
        var frames = 0
        var found = false
        var lit = 0
        await watch(timeout: 5) { result, _, _ in
            frames += 1
            if result.sample.brightness >= 0.16 { lit += 1 }
            if result.sample.faceCount > 0 { found = true }
            return !found && frames < 45
        }
        if found { return true }
        return lit >= 20 ? false : nil
    }
}
