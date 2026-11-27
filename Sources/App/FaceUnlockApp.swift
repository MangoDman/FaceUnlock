import SwiftUI

@main
struct FaceUnlockApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(app: delegate.model, delegate: delegate)
        } label: {
            // A lock replaces the face while Touch ID or the password is needed.
            if delegate.model.needsAuthentication {
                Image(systemName: "lock.fill").accessibilityLabel("FaceUnlock, paused")
            } else {
                Image(nsImage: MenuBarGlyph.image).accessibilityLabel("FaceUnlock")
            }
        }
    }
}

/// Our own mark as a template image. SF Symbols' face symbol is reserved for Apple's Face ID.
@MainActor
enum MenuBarGlyph {
    static let image: NSImage = {
        let renderer = ImageRenderer(content: FaceGlyph(color: .black)
            .frame(width: 18, height: 18))
        renderer.scale = 2
        let image = renderer.nsImage ?? NSImage()
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        return image
    }()
}

private struct MenuContent: View {
    var app: AppModel
    var delegate: AppDelegate

    var body: some View {
        Text(app.statusText)
        if app.needsAuthentication {
            Button { app.confirmWithTouchID() } label: { Label("Confirm with Touch ID…", systemImage: "touchid") }
        }
        Divider()
        Button { Screen.lockNow() } label: { Label("Lock Screen", systemImage: "lock") }
        if app.isPaused {
            Button { app.resume() } label: { Label("Resume Face Unlock", systemImage: "play") }
        } else {
            Menu {
                Button("For 15 Minutes") { app.pause(for: 15 * 60) }
                Button("For 1 Hour") { app.pause(for: 3600) }
                Button("For 8 Hours") { app.pause(for: 8 * 3600) }
            } label: { Label("Pause Face Unlock", systemImage: "pause") }
        }
        Button { app.testRecognition() } label: { Label("Test Recognition", systemImage: "viewfinder") }
            .disabled(!app.isSetUp)
        Divider()
        Button { delegate.showSettings() } label: { Label("Settings…", systemImage: "gearshape") }
            .keyboardShortcut(",")
        Button { delegate.showAbout() } label: { Label("About FaceUnlock", systemImage: "info.circle") }
        Divider()
        Button("Quit FaceUnlock") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = AppModel()
    private var settingsWindow: NSWindow?
    private var setupWindow: NSWindow?
    private var setupModel: SetupModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Unit tests host the app; leave the system alone there.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        #if DEBUG
        if let index = CommandLine.arguments.firstIndex(of: "--snapshots"), CommandLine.arguments.count > index + 1 {
            Snapshots.render(to: URL(filePath: CommandLine.arguments[index + 1]), app: model)
            NSApp.terminate(nil)
            return
        }
        // `--notch-test <style>` plays one opening and closing in slow motion, and does nothing else.
        if let index = CommandLine.arguments.firstIndex(of: "--notch-test"), CommandLine.arguments.count > index + 1 {
            model.notch.forcedStyle = NotchState.Preference(rawValue: CommandLine.arguments[index + 1])
            if CommandLine.arguments.count > index + 2 {
                model.notch.forcedKind = ScreenKind(rawValue: CommandLine.arguments[index + 2])
            }
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                // Every kind of change: open, resize, resize again, close.
                for (phase, seconds) in [(NotchState.Phase.scanning, 3.0), (.success(nil), 3.0),
                                         (.failure("Face Not Recognized"), 3.0),
                                         (.prompt(title: "Face Unlock Paused", message: "Touch ID is required."), 3.0)] {
                    model.notch.show(phase)
                    try? await Task.sleep(for: .seconds(seconds))
                }
                model.notch.collapse()
                try? await Task.sleep(for: .seconds(4))
                NSApp.terminate(nil)
            }
            return
        }
        // `--settings-test` opens Settings after a moment, to check it comes to the front.
        if CommandLine.arguments.contains("--settings-test") {
            Task {
                try? await Task.sleep(for: .seconds(2))
                showSettings()
            }
            return
        }
        // `--unlock-test <style> <kind>` plays a successful unlock with the real timing.
        if let index = CommandLine.arguments.firstIndex(of: "--unlock-test"), CommandLine.arguments.count > index + 2 {
            model.notch.forcedStyle = NotchState.Preference(rawValue: CommandLine.arguments[index + 1])
            model.notch.forcedKind = ScreenKind(rawValue: CommandLine.arguments[index + 2])
            Task {
                try? await Task.sleep(for: .seconds(1))
                model.notch.show(.scanning)
                try? await Task.sleep(for: .seconds(1.2))
                // As at the higher protection levels: a request to turn, then recognition.
                model.notch.show(.hint("Turn Your Head Left"))
                try? await Task.sleep(for: .seconds(1.4))
                print("success"); fflush(stdout)
                try? await Task.sleep(for: .seconds(0.4))
                await model.notch.showSuccess()
                model.notch.collapse()
                try? await Task.sleep(for: .seconds(1.5))
                NSApp.terminate(nil)
            }
            return
        }
        #endif
        model.start()
        // Open quietly at login once everything works; otherwise show what's left to do.
        if !model.isReady { showSettings() }
        #if DEBUG
        if CommandLine.arguments.contains("--setup") { requestSetup(.primary) }
        #endif
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showSettings()
        return false
    }

    func showSettings() {
        if settingsWindow == nil {
            let root = SettingsRoot(app: model, setUp: { [weak self] appearance in
                self?.requestSetup(appearance)
            }, titleChanged: { [weak self] title in
                DispatchQueue.main.async { self?.settingsWindow?.title = title }
            })
            let host = NSHostingController(rootView: root)
            host.sceneBridgingOptions = [.toolbars]
            let window = NSWindow(contentViewController: host)
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.toolbarStyle = .unified
            window.titlebarSeparatorStyle = .none
            window.isReleasedWhenClosed = false
            window.delegate = self
            // Like System Settings: fixed width, free height.
            window.setContentSize(NSSize(width: 740, height: 780))
            window.contentMinSize = NSSize(width: 740, height: 560)
            window.contentMaxSize = NSSize(width: 740, height: 4000)
            window.center()
            let saved = UserDefaults.standard.string(forKey: "settingsSection") ?? ""
            window.title = (SettingsPane(rawValue: saved) ?? .main).title
            settingsWindow = window
        }
        present(settingsWindow)
    }

    /// About lives in Settings › General.
    func showAbout() {
        UserDefaults.standard.set(SettingsPane.general.rawValue, forKey: "settingsSection")
        showSettings()
    }

    /// Asks for Touch ID or the password before a scan that would change existing face data.
    private func requestSetup(_ appearance: Appearance) {
        model.refresh()
        // Finishing an earlier setup (no new scan) needs nothing.
        let finishing = appearance == .primary && model.isSetUp && (!model.hasPassword || !model.accessibilityTrusted)
        // With a password saved, a new face could open the Mac, even if the face data has gone.
        guard model.isSetUp || model.hasPassword, !finishing else { return showSetup(appearance) }
        Task {
            if await model.authorizeFaceChange("change your face data") { showSetup(appearance) }
        }
    }

    private func showSetup(_ appearance: Appearance) {
        setupWindow?.close()
        model.refresh()
        // Already scanned but unlocking isn't finished: go straight to what's missing.
        let setup = SetupModel(app: model, appearance: appearance)
        if appearance == .primary, model.isSetUp, !model.hasPassword || !model.accessibilityTrusted { setup.advanceAfterScan() }
        setupModel = setup
        let view = SetupView(model: setup, app: model) { [weak self] in self?.setupWindow?.close() }
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "Set Up FaceUnlock"
        window.titleVisibility = .hidden
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        setupWindow = window
        present(window)
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === setupWindow else { return }
        setupModel?.cancel()
        setupModel = nil
        setupWindow?.contentViewController = nil
        setupWindow = nil
    }

    /// Brings a window in front of whatever is being used, on the current desktop. A menu bar
    /// app isn't made active just by choosing from its menu, and the polite request to activate
    /// can be ignored, which left windows opening behind other apps.
    private func present(_ window: NSWindow?) {
        guard let window else { return }
        // After the menu has closed, or it takes the focus back.
        DispatchQueue.main.async {
            window.collectionBehavior.insert(.moveToActiveSpace)
            if window.isMiniaturized { window.deminiaturize(nil) }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
    }
}

/// Options used while developing (screenshots, animation tests). A released build ignores them.
enum LaunchOptions {
    static func has(_ option: String) -> Bool {
        #if DEBUG
        CommandLine.arguments.contains(option)
        #else
        false
        #endif
    }
}
