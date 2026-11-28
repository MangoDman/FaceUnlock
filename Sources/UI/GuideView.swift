import SwiftUI

/// Setting up and learning FaceUnlock, one thing per screen: a welcome, what it needs (moving on
/// by itself as each is done), the choices worth making, and where everything is.
struct GuideView: View {
    var app: AppModel
    var setUp: (_ appearance: Appearance) -> Void
    var close: () -> Void
    /// The whole guide, or only what's missing (when something stops working later).
    var tour = true
    /// For screenshots only.
    var forced: (page: GuidePage, step: GuideStep)?

    @State private var page = GuidePage.welcome
    /// Something was asked for; macOS sometimes only tells a freshly opened app.
    @State private var asked: Set<GuideStep> = []
    @State private var minutes = 0.0
    @State private var protection = AppModel.Protection.high
    @State private var highlighted = 0
    /// When the "try it" page appeared: a face unlock after this moves on.
    @State private var tryingSince = Date.distantFuture

    static let completedKey = "guideCompleted"

    private var shown: GuidePage { forced?.page ?? (tour ? page : .setup) }

    private var step: GuideStep {
        forced?.step ?? GuideStep.current(
            keychainNeeded: app.needsKeychainAccess, camera: app.cameraAuthorized, face: app.isSetUp,
            password: app.hasPassword, accessibility: app.accessibilityTrusted, enabled: app.isEnabled,
            confirmationNeeded: app.needsAuthentication)
    }

    var body: some View {
        VStack(spacing: 0) {
            progress
            ScrollView {
                VStack(spacing: 14) {
                    content
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
            }
            .scrollBounceBehavior(.basedOnSize)
            .id(shown == .setup ? "setup-\(step.rawValue)" : shown.rawValue)
            .transition(.asymmetric(insertion: .opacity.combined(with: .offset(x: 30)), removal: .opacity))
            buttons.padding(.top, 12)
        }
        .padding(24)
        .frame(width: 460, height: 640)
        .animation(.smooth(duration: 0.4), value: shown)
        .animation(.smooth(duration: 0.4), value: step)
        .onChange(of: app.lastFaceUnlock) { _, unlocked in
            if shown == .tryIt, let unlocked, unlocked > tryingSince { page = .allSet }
        }
        .onChange(of: shown, initial: true) { _, now in
            if now == .tryIt { tryingSince = .now }
        }
        .onAppear {
            minutes = Double(UnlockPolicy.timeLimits.firstIndex { $0 >= app.timeLimit } ?? 0)
            protection = app.protection
        }
        .task {
            // Notices the tick the moment something is allowed in System Settings.
            while !Task.isCancelled, forced == nil {
                app.recheckKeychain()
                app.refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .task(id: shown) {
            // The menu tour points at one item after another.
            guard shown == .menuBar, forced == nil else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2.6))
                if Task.isCancelled { return }
                withAnimation { highlighted = (highlighted + 1) % Self.menu.count }
            }
        }
    }

    // MARK: Chrome

    /// Which part this is, how far through it, and a bar for each of the four parts.
    private var progress: some View {
        VStack(spacing: 7) {
            if tour || forced != nil, let chapter = shown.chapter {
                HStack(spacing: 5) {
                    ForEach(GuidePage.Chapter.allCases, id: \.self) { part in
                        GeometryReader { space in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.secondary.opacity(0.28))
                                Capsule().fill(Theme.accent).frame(width: space.size.width * filled(part))
                            }
                        }
                        .frame(height: 4)
                    }
                }
                Text("Part \(chapter.number) of \(GuidePage.Chapter.allCases.count) · \(chapter.rawValue)\(within)")
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
            }
        }
        .frame(height: 30)
        .accessibilityElement(children: .combine)
    }

    /// How much of a part is behind you.
    private func filled(_ part: GuidePage.Chapter) -> Double {
        guard let current = shown.chapter else { return 0 }
        if part.number != current.number { return part.number < current.number ? 1 : 0 }
        if shown == .setup {
            guard let index = GuideStep.counted.firstIndex(of: step) else { return step == .keychain ? 0.05 : 1 }
            return Double(index + 1) / Double(GuideStep.counted.count + 1)
        }
        return Double((current.pages.firstIndex(of: shown) ?? 0) + 1) / Double(current.pages.count)
    }

    private var within: String {
        guard shown == .setup, let index = GuideStep.counted.firstIndex(of: step) else { return "" }
        return " · step \(index + 1) of \(GuideStep.counted.count)"
    }

    private func heading(_ title: String, _ text: String) -> some View {
        VStack(spacing: 8) {
            Text(title).font(.title.bold()).multilineTextAlignment(.center)
            Text(text).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var content: some View {
        switch shown {
        case .welcome: welcome
        case .setup: setup
        case .duration: duration
        case .protection: protectionPage
        case .menuBar: menuBar
        case .settings: settingsTour
        case .howItWorks: howItWorks
        case .tryIt: tryIt
        case .allSet: allSet
        }
    }

    // MARK: Welcome

    @ViewBuilder private var welcome: some View {
        Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 110, height: 110)
            .accessibilityHidden(true)
        heading("Welcome to FaceUnlock", "Look at your Mac and it unlocks.")
        VStack(alignment: .leading, spacing: 16) {
            feature("viewfinder", "Set up in a few minutes", "A short scan of your face and a few permissions.")
            feature("lock.shield.fill", "Touch ID still decides", "Your password or Touch ID is still asked for when it matters.")
            feature("hand.raised.fill", "Stays on your Mac", "Nothing is sent anywhere, and no pictures are kept.")
        }
        .padding(.top, 12)
        Text("A camera is not Face ID. A good video or photo of you could unlock your Mac.")
            .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.top, 8)
    }

    private func feature(_ icon: String, _ title: String, _ text: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.title).foregroundStyle(Theme.accent).frame(width: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.semibold)
                Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
    }

    // MARK: What it needs

    @ViewBuilder private var setup: some View {
        picture.frame(minHeight: 200)
        heading(setupTitle, setupText)
        if !instructions.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(instructions.enumerated()), id: \.offset) { index, line in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("\(index + 1)").font(.caption.bold()).foregroundStyle(.white)
                            .frame(width: 18, height: 18).background(Theme.accent, in: Circle())
                        Text(line).font(.callout).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(.horizontal, 18).padding(.top, 4)
        }
        if step == .face {
            VStack(alignment: .leading, spacing: 8) {
                tip("sun.max.fill", "Sit where your face is evenly lit.")
                tip("laptopcomputer", "Look at the screen from your usual distance.")
                tip("arrow.left.and.right", "Turn slowly until each of the four arcs turns blue.")
                tip("eyeglasses", "You can add glasses or a hat afterwards.")
            }
            .padding(.top, 4)
        }
    }

    /// Exactly what to do, click by click, where macOS is involved.
    private var instructions: [String] {
        switch step {
        case .camera:
            ["Click Allow Camera below.", "macOS shows a small box. Click Allow.", "No box? System Settings opens: switch FaceUnlock on under Camera."]
        case .accessibility:
            ["Click Open Accessibility below.", "In System Settings, switch FaceUnlock on. Use Touch ID if asked.",
             "Not listed? Click +, choose Applications, then FaceUnlock.", "Come back to this window. It moves on by itself."]
        case .keychain:
            ["Click Allow Keychain Access below.", "Type your Mac password in the box.", "Click Always Allow. It may ask more than once."]
        default: []
        }
    }

    private func tip(_ icon: String, _ text: String) -> some View {
        Label {
            Text(text).font(.callout)
        } icon: {
            Image(systemName: icon).foregroundStyle(Theme.accent).frame(width: 22)
        }
    }

    private var setupTitle: String {
        switch step {
        case .keychain: "Let FaceUnlock use its keychain"
        case .camera: "Allow the camera"
        case .face: "Scan your face"
        case .password: "Enter your Mac password"
        case .accessibility: "Switch on Accessibility"
        case .turnOn: "Turn on face unlock"
        case .confirm: "Confirm it’s you"
        case .done: "Everything is set"
        }
    }

    private var setupText: String {
        switch step {
        case .keychain: "Click the button, type your Mac password when asked, then choose Always Allow. Not just Allow."
        case .camera: "Click the button below. When macOS asks, click Allow."
        case .face: "This is how your Mac learns you. It’s kept as numbers, not pictures."
        case .password: "FaceUnlock types it for you on the lock screen. It stays in your keychain."
        case .accessibility: "System Settings opens at the right list. Click the switch next to FaceUnlock, then come back here."
        case .turnOn: "One switch, and your Mac can unlock when it sees you."
        case .confirm: "Use Touch ID or your password once, and you’re ready."
        case .done: "Your face, password and permissions are all in place."
        }
    }

    // Pictures of what to click: our own drawings, not screenshots.
    @ViewBuilder private var picture: some View {
        switch step {
        case .camera:
            dialog("camera.fill", "“FaceUnlock” would like to use the camera.", other: "Don’t Allow", click: "Allow")
        case .keychain:
            dialog("key.fill", "FaceUnlock wants to use information in your keychain.", field: true,
                   other: "Allow", click: "Always Allow")
        case .accessibility:
            VStack(spacing: 8) {
                row("Another app", on: false, ours: false)
                row("FaceUnlock", on: true, ours: true)
                Text("Not in the list? Click + and choose FaceUnlock in Applications.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(14)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 16))
        case .face: InstructionGlyph().frame(width: 150, height: 150)
        case .password: symbol("key.fill", Theme.accent)
        case .turnOn: symbol("power.circle.fill", .green)
        case .confirm: symbol("touchid", .pink)
        case .done: symbol("checkmark.circle.fill", .green)
        }
    }

    private func symbol(_ name: String, _ colour: Color) -> some View {
        Image(systemName: name).font(.system(size: 76)).foregroundStyle(colour).glassy().accessibilityHidden(true)
    }

    private func dialog(_ icon: String, _ message: String, field: Bool = false, other: String, click: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.title).foregroundStyle(Theme.accent)
            Text(message).font(.callout.weight(.semibold)).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if field {
                Text("••••••••").frame(maxWidth: .infinity, alignment: .leading).padding(6)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            }
            HStack(spacing: 8) {
                mock(other)
                mock(click).foregroundStyle(.white)
                    .background(Theme.accent, in: Capsule())
                    .overlay { Pulse(shape: Capsule()) }
            }
        }
        .padding(16)
        .frame(width: 280)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 18))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Choose \(click)")
    }

    private func mock(_ label: String) -> some View {
        Text(label).font(.callout).frame(maxWidth: .infinity).frame(height: 28)
            .background(Color.secondary.opacity(0.18), in: Capsule())
    }

    private func row(_ name: String, on: Bool, ours: Bool) -> some View {
        HStack(spacing: 10) {
            if ours {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 26, height: 26)
            } else {
                RoundedRectangle(cornerRadius: 6).fill(.quaternary).frame(width: 26, height: 26)
            }
            Text(name).foregroundStyle(ours ? .primary : .secondary)
            Spacer()
            Capsule().fill(on ? Theme.accent : Color.secondary.opacity(0.35))
                .frame(width: 38, height: 22)
                .overlay(alignment: on ? .trailing : .leading) { Circle().fill(.white).padding(2) }
                .overlay { if ours { Pulse(shape: Capsule()) } }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: Choices

    @ViewBuilder private var duration: some View {
        symbol("clock.fill", Theme.accent).frame(height: 130)
        heading("How long should it last?",
                "After this long, FaceUnlock asks for your password or Touch ID again. Shorter is safer.")
        Text(SettingsView.duration(UnlockPolicy.timeLimits[Int(minutes.rounded())]))
            .font(.title2.weight(.semibold)).monospacedDigit().padding(.top, 10)
        Slider(value: $minutes, in: 0...Double(UnlockPolicy.timeLimits.count - 1), step: 1) {
            Text("Time limit")
        } minimumValueLabel: {
            Text("5 min")
        } maximumValueLabel: {
            Text("3 hr")
        }
        .labelsHidden()
        Text("45 minutes is the usual choice. A longer time asks for Touch ID to confirm.")
            .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
    }

    @ViewBuilder private var protectionPage: some View {
        symbol("lock.shield.fill", Theme.accent).frame(height: 130)
        heading("How careful should it be?", "Choose how much proof it asks for before unlocking.")
        Picker("Protection", selection: $protection) {
            Text("Standard").tag(AppModel.Protection.standard)
            Text("High").tag(AppModel.Protection.high)
            Text("Maximum").tag(AppModel.Protection.maximum)
        }
        .pickerStyle(.segmented).labelsHidden().padding(.top, 10)
        Text(protectionText).font(.callout).multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true).frame(height: 56, alignment: .top)
    }

    private var protectionText: String {
        switch protection {
        case .standard: "Quickest. Rejects screens and photos it can spot, and never asks you to do anything."
        case .high: "Recommended. Also waits for a blink or a natural movement of your head."
        case .maximum: "Also asks you to turn your head left or right, chosen at random."
        }
    }

    // MARK: The tour

    private static let menu: [(String, String, String)] = [
        ("Status", "circle.fill", "The top line says if it’s ready. If something is missing, a button to fix it sits right under it."),
        ("Lock Screen", "lock", "Locks your Mac straight away."),
        ("Pause Face Unlock", "pause", "Switches it off for 15 minutes, 1 hour or 8 hours."),
        ("Test Recognition", "viewfinder", "Tries your face without unlocking or typing anything."),
        ("Setup Guide…", "arrow.right.circle", "Opens this guide again."),
        ("Settings…", "gearshape", "Everything else: your face, security, alerts and privacy."),
        ("Quit FaceUnlock", "power", "Stops it until you open it again."),
    ]

    @ViewBuilder private var menuBar: some View {
        heading("It lives in the menu bar", "Click the face at the top right of your screen.")
        VStack(alignment: .trailing, spacing: 6) {
            HStack(spacing: 12) {
                Spacer()
                Image(nsImage: MenuBarGlyph.image).renderingMode(.template)
                    .padding(4).background(Theme.accent.opacity(0.35), in: RoundedRectangle(cornerRadius: 5))
                    .overlay { Pulse(shape: RoundedRectangle(cornerRadius: 5)) }
                Image(systemName: "wifi")
                Image(systemName: "battery.75percent")
                Text("9:41")
            }
            .font(.callout)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(.quaternary.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))

            VStack(spacing: 1) {
                ForEach(Self.menu.indices, id: \.self) { index in
                    Button {
                        highlighted = index
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: Self.menu[index].1).font(.caption)
                                .foregroundStyle(index == 0 ? Color.green : .primary).frame(width: 16)
                            Text(index == 0 ? "Ready" : Self.menu[index].0)
                            Spacer()
                        }
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(index == highlighted ? Theme.accent : .clear, in: RoundedRectangle(cornerRadius: 6))
                        .foregroundStyle(index == highlighted ? .white : .primary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(6)
            .frame(width: 250)
            .background(.quaternary.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
        }
        VStack(spacing: 4) {
            Text(Self.menu[highlighted].0).fontWeight(.semibold)
            Text(Self.menu[highlighted].2).font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }
        .frame(height: 62, alignment: .top)
    }

    private static let tourPanes: [SettingsPane] = [.main, .security, .unlocking, .appearance, .alerts, .privacy]

    @ViewBuilder private var settingsTour: some View {
        heading("Make it yours", "These are in Settings. Open any of them to look around.")
        VStack(spacing: 6) {
            ForEach(Self.tourPanes) { pane in
                HStack(spacing: 12) {
                    Image(systemName: pane.symbol).font(.title3).foregroundStyle(pane.tint).frame(width: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(pane.title).fontWeight(.medium)
                        Text(pane.summary).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 6)
                    Button("Open") { app.onSettings?(pane) }.controlSize(.small)
                }
                .padding(10)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    @ViewBuilder private var howItWorks: some View {
        heading("How unlocking works", "Watch once. Next, you try it for real.")
        UnlockDemo(frozen: forced != nil)
    }

    @ViewBuilder private var tryIt: some View {
        symbol("lock.fill", Theme.accent).frame(height: 96)
        heading("Now you try",
                "Click the face in the menu bar and choose Lock Screen, or use the button below. This guide waits for you.")
        VStack(alignment: .leading, spacing: 7) {
            tip("hand.point.up.left.fill", "Wait a moment, then move the pointer.")
            tip("eye.fill", "Look at the screen.")
            tip("arrow.left.and.right", "If it asks, turn your head, then look back.")
        }
        HStack(spacing: 8) {
            ForEach(["⌃", "⌘", "Q"], id: \.self) { label in
                Text(label).font(.title3.weight(.semibold)).frame(width: 40, height: 40)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 9))
            }
        }
        .padding(.top, 6)
        Text("Your password and Touch ID always work too.").font(.caption).foregroundStyle(.secondary)
    }

    @ViewBuilder private var allSet: some View {
        FinishTick(frozen: forced != nil).frame(width: 150, height: 150).padding(.top, 40)
        heading("You’re all set", "FaceUnlock is ready. It waits in the menu bar, and Settings has everything else.")
            .padding(.top, 12)
    }

    // MARK: Buttons

    private var buttons: some View {
        VStack(spacing: 10) {
            if forced == nil {
                Button(action: act) { Text(action).frame(maxWidth: .infinity) }
                    .buttonStyle(.glassProminent).controlSize(.extraLarge).keyboardShortcut(.defaultAction)
            } else {
                // A screenshot window is rarely the active one, which would grey the real button.
                Text(action).fontWeight(.medium).foregroundStyle(.white).frame(maxWidth: .infinity).frame(height: 36)
                    .background(Theme.accent, in: Capsule())
            }
            HStack {
                if tour || forced != nil, shown.previous != nil, shown != .allSet {
                    Button("Back") { page = shown.previous ?? .welcome }.buttonStyle(.link)
                }
                Spacer()
                if shown == .tryIt {
                    Button("Skip") { page = .allSet }.buttonStyle(.link)
                }
                if shown == .setup, step != .done {
                    if asked.contains(step), step == .camera || step == .accessibility {
                        Button("Nothing changed? Quit & Reopen") { app.relaunch() }.buttonStyle(.link)
                    }
                    Button("Set Up Later") { if tour { page = .duration } else { close() } }.buttonStyle(.link)
                }
            }
            .frame(height: 18)
        }
    }

    private var action: String {
        switch shown {
        case .welcome: "Get Started"
        case .setup:
            switch step {
            case .keychain: "Allow Keychain Access…"
            case .camera: "Allow Camera…"
            case .face: "Start Scan…"
            case .password: "Enter Password…"
            case .accessibility: "Open Accessibility…"
            case .turnOn: "Turn On"
            case .confirm: "Use Touch ID…"
            case .done: tour ? "Continue" : "Done"
            }
        case .duration, .protection, .menuBar, .settings, .howItWorks: "Continue"
        case .tryIt: "Lock My Mac Now"
        case .allSet: "Open Settings"
        }
    }

    private func act() {
        switch shown {
        case .welcome, .menuBar, .settings, .howItWorks: advance()
        case .setup:
            asked.insert(step)
            switch step {
            case .keychain: app.requestKeychainAccess()
            case .camera: app.allowCamera()
            case .face, .password: setUp(.primary)
            case .accessibility: app.allowAccessibility()
            case .turnOn: app.isEnabled = true
            case .confirm: app.confirmWithTouchID()
            case .done: if tour { advance() } else { close() }
            }
        case .duration:
            // Anything that makes the Mac easier to open asks for Touch ID, as in Settings.
            var proposed = app.security
            proposed.timeLimit = UnlockPolicy.timeLimits[Int(minutes.rounded())]
            app.propose(proposed)
            advance()
        case .protection:
            var proposed = app.security
            proposed.protection = protection
            app.propose(proposed)
            advance()
        case .tryIt: Screen.lockNow()
        case .allSet:
            UserDefaults.standard.set(true, forKey: Self.completedKey)
            app.onSettings?(.main)
            close()
        }
    }

    private func advance() { page = shown.next ?? shown }
}

/// A soft ring that breathes around the thing to click.
private struct Pulse<S: Shape>: View {
    var shape: S
    @State private var out = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        shape.stroke(Theme.accent, lineWidth: 2)
            .padding(out ? -7 : -2)
            .opacity(out ? 0 : 0.9)
            .allowsHitTesting(false)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeOut(duration: 1.2).repeatForever(autoreverses: false)) { out = true }
            }
    }
}

/// A small replay of an unlock, drawn with the same glyph the notch uses.
private struct UnlockDemo: View {
    var frozen = false
    @State private var moment = 0
    /// This Mac's own desktop picture, so it looks like your lock screen.
    @State private var wallpaper: NSImage?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let captions = ["Your Mac is locked.", "Move the pointer: it starts looking.",
                                   "It sees you. A tick draws.", "Unlocked."]

    var body: some View {
        VStack(spacing: 16) {
            ZStack(alignment: .top) {
                PreviewBackdrop(wallpaper: wallpaper)
                    // Keeps the clock readable on a bright picture.
                    .overlay(Color.black.opacity(0.12))
                    .frame(width: 340, height: 200)
                    // The picture is zoomed in, so it is cut to the screen's shape afterwards.
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                HStack {
                    Image(systemName: moment >= 2 ? "lock.open.fill" : "lock.fill").contentTransition(.symbolEffect(.replace))
                    Spacer()
                    if moment > 0 { UnlockGlyph(success: moment >= 2).frame(width: 24, height: 24) }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .frame(width: 230, height: 36)
                .background(.black, in: UnevenRoundedRectangle(bottomLeadingRadius: 16, bottomTrailingRadius: 16))
                Group {
                    if moment == 3 {
                        Image(systemName: "macwindow.on.rectangle").font(.system(size: 54))
                    } else {
                        Text("9:41").font(.system(size: 44, weight: .semibold))
                    }
                }
                .foregroundStyle(.white.opacity(0.92))
                .shadow(color: .black.opacity(0.45), radius: 6, y: 1)
                .frame(maxHeight: .infinity)
            }
            .frame(width: 340, height: 200)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            Text(Self.captions[moment]).font(.headline).contentTransition(.opacity)
            HStack(spacing: 6) {
                ForEach(0..<4, id: \.self) { Circle().fill($0 == moment ? Theme.accent : Color.secondary.opacity(0.35)).frame(width: 6, height: 6) }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Lock your Mac, move the pointer, look at the screen, and it unlocks.")
        .task { wallpaper = await DesktopWallpaper.load() }
        .task {
            if frozen || reduceMotion {
                moment = 2
                return
            }
            while !Task.isCancelled {
                for (next, wait) in [(0, 1.6), (1, 2.2), (2, 1.8), (3, 1.8)] {
                    withAnimation(.smooth) { moment = next }
                    try? await Task.sleep(for: .seconds(wait))
                    if Task.isCancelled { return }
                }
            }
        }
    }
}

/// A ring that closes and a tick that draws itself, to say it's finished.
private struct FinishTick: View {
    var frozen = false
    @State private var ring = 0.0
    @State private var tick = 0.0

    var body: some View {
        ZStack {
            Circle().trim(from: 0, to: ring)
                .stroke(Color.green, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Checkmark().trim(from: 0, to: tick)
                .stroke(Color.green, style: StrokeStyle(lineWidth: 11, lineCap: .round, lineJoin: .round))
        }
        .accessibilityLabel("Done")
        .onAppear {
            if frozen {
                (ring, tick) = (1, 1)
                return
            }
            withAnimation(.easeInOut(duration: 0.6)) { ring = 1 }
            withAnimation(.easeOut(duration: 0.35).delay(0.55)) { tick = 1 }
            Sounds.play(.complete)
        }
    }
}
