import SwiftUI

/// Everything FaceUnlock needs, in one place: a tick when it has it, one button when it doesn't.
struct PermissionsPane: View {
    var app: AppModel
    var setUp: (_ appearance: Appearance) -> Void
    /// A permission was asked for; macOS sometimes only tells a freshly opened app.
    @State private var asked = false

    var body: some View {
        @Bindable var app = app
        Group {
            Section {
                Label {
                    Text(app.stepsLeft == 0 && app.needsAuthentication ? "Last step: confirm with Touch ID."
                         : app.stepsLeft == 0 ? "All set. Press Control-Command-Q to lock, then look at your Mac."
                         : app.stepsLeft == 1 ? "One step left." : "\(app.stepsLeft) steps left. Work down the list.")
                } icon: {
                    Image(systemName: app.stepsLeft == 0 ? "checkmark.seal.fill" : "list.bullet.circle.fill")
                        .foregroundStyle(app.stepsLeft == 0 ? .green : .orange)
                }
            }

            Section("Needed") {
                step("Your face", "A short scan, kept as encrypted numbers.", done: app.isSetUp, button: "Set Up…") {
                    setUp(.primary)
                }
                step("Mac password", "Typed for you on the lock screen. Kept in your keychain.",
                     done: app.hasPassword, button: "Add…", available: app.isSetUp) {
                    setUp(.primary)
                }
                step("Camera", "To see you. Click Allow when macOS asks.", done: app.cameraAuthorized, button: "Allow…") {
                    asked = true
                    app.allowCamera()
                }
                step("Accessibility", "Lets the password be typed on the lock screen. Switch FaceUnlock on in the list that opens.",
                     done: app.accessibilityTrusted, button: "Allow…") {
                    asked = true
                    app.allowAccessibility()
                }
                step("Keychain", "Enter your password and choose Always Allow, not just Allow.",
                     done: !app.needsKeychainAccess, button: "Allow…") {
                    app.requestKeychainAccess()
                }
                step("Unlock with Front Camera", "The main switch.", done: app.isEnabled && app.isSetUp,
                     button: "Turn On", available: app.isSetUp && app.hasPassword && app.accessibilityTrusted) {
                    app.isEnabled = true
                }
                // Only there when it's the thing to do, so the count always matches the list.
                if app.needsAuthentication {
                    step("Confirm it’s you", "Needed after FaceUnlock starts, and when your time limit passes.",
                         done: false, button: "Use Touch ID…") {
                        app.confirmWithTouchID()
                    }
                }
            }

            Section("Optional") {
                step("Notifications", "Tells you when your password is needed.", done: app.notificationsAllowed,
                     button: "Allow…") {
                    app.allowNotifications()
                }
                Toggle("Open FaceUnlock at login", isOn: $app.launchAtLogin)
            }

            Section {
                if asked, !(app.cameraAuthorized && app.accessibilityTrusted) {
                    LabeledContent("Allowed it, but no tick yet?") {
                        Button("Quit & Reopen") { app.relaunch() }
                    }
                }
            } footer: {
                Text("After an update macOS may ask again. Allow clears the old entry for you. There’s no separate lock screen permission: Accessibility covers it.")
                    .font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        // Ticks appear as soon as something is switched on in System Settings.
        .task {
            while !Task.isCancelled {
                app.refresh()
                await app.refreshNotificationStatus()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func step(_ title: String, _ detail: String, done: Bool, button: String, available: Bool = true,
                      action: @escaping () -> Void) -> some View {
        LabeledContent {
            if !done { Button(button, action: action).disabled(!available) }
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(detail).font(.callout).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(done ? Color.green : Color.secondary)
                    .accessibilityLabel(done ? "Done" : "Not done")
            }
        }
    }
}
