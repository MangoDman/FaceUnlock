import OpenDirectory
import SwiftUI

/// Laid out like macOS System Settings: search, account header, grouped sidebar, back and forward.
enum SettingsPane: String, CaseIterable, Identifiable {
    case general, appearance, main, security, unlocking, alerts, activity, privacy
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .main: "Face Unlock & Password"
        case .security: "Security"
        case .unlocking: "Lock & Presence"
        case .alerts: "Alerts & Sounds"
        case .activity: "Activity"
        case .privacy: "Privacy"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .appearance: "paintbrush.fill"
        case .main: "viewfinder"
        case .security: "lock.shield.fill"
        case .unlocking: "lock.fill"
        case .alerts: "bell.badge.fill"
        case .activity: "clock.arrow.circlepath"
        case .privacy: "hand.raised.fill"
        }
    }

    var tint: Color {
        switch self {
        case .general: .gray
        case .appearance: .cyan
        case .main: .green
        case .security: .blue
        case .unlocking: .gray
        case .alerts: .red
        case .activity: .indigo
        case .privacy: .blue
        }
    }

    /// The System Settings extension whose icon macOS itself shows for this idea. Nil where Apple
    /// has no equivalent, and the tile is drawn here in the same style.
    var systemIcon: String? {
        switch self {
        case .main, .security: nil
        case .general: nil
        case .appearance: "Appearance"
        case .unlocking: "LockScreen"
        case .alerts: "NotificationsSettings"
        case .activity: "ScreenTimePreferencesExtension"
        case .privacy: "SecurityPrivacyExtension"
        }
    }

    var summary: String {
        switch self {
        case .general: "About FaceUnlock, startup and support."
        case .appearance: "How the notch animation and face setup look."
        case .main: "Use the front camera to unlock your Mac."
        case .security: "Choose how much proof FaceUnlock asks for before unlocking."
        case .unlocking: "Decide when your password is needed, and what happens when you step away."
        case .alerts: "Where FaceUnlock tells you things, and what you hear and feel."
        case .activity: "Recent unlocks and refused attempts on this Mac."
        case .privacy: "Your face data and password stay on this Mac."
        }
    }

    /// Extra words the sidebar search matches.
    var keywords: String {
        switch self {
        case .general: "about version login startup support website licences log"
        case .appearance: "notch island style animation display guide arcs ticks"
        case .main: "face scan appearance password touch id setup test permissions"
        case .security: "protection spoof photo attention alone matching blink"
        case .unlocking: "away walk pause password time limit minutes attempts awake"
        case .alerts: "notification sound haptic preview"
        case .activity: "history log attempts"
        case .privacy: "data reset delete"
        }
    }

    static let groups: [[SettingsPane]] = [[.general, .appearance], [.main, .security, .unlocking, .alerts], [.activity, .privacy]]
}

/// The signed-in Mac user's name and picture, read locally.
struct Profile {
    var name: String
    var picture: NSImage?

    static let current: Profile = {
        // Screenshots for the website must not show a real person.
        if LaunchOptions.has("--demo") { return Profile(name: "Your Name") }
        let node = try? ODNode(session: ODSession.default(), type: ODNodeType(kODNodeTypeLocalNodes))
        let record = try? node?.record(withRecordType: kODRecordTypeUsers, name: NSUserName(), attributes: nil)
        let data = (try? record?.values(forAttribute: kODAttributeTypeJPEGPhoto))?.first as? Data
        return Profile(name: NSFullUserName(), picture: data.flatMap(NSImage.init(data:)))
    }()
}

struct SettingsRoot: View {
    var app: AppModel
    var setUp: (_ appearance: Appearance) -> Void
    var titleChanged: (String) -> Void = { _ in }
    @AppStorage("settingsSection") private var selection = SettingsPane.main.rawValue
    @State private var back: [SettingsPane] = []
    @State private var forward: [SettingsPane] = []
    @State private var query = ""

    private var pane: SettingsPane { SettingsPane(rawValue: selection) ?? .main }

    private func go(_ next: SettingsPane) {
        guard next != pane else { return }
        back.append(pane)
        forward = []
        selection = next.rawValue
    }

    private func matches(_ item: SettingsPane) -> Bool {
        query.isEmpty || "\(item.title) \(item.keywords)".localizedCaseInsensitiveContains(query)
    }

    private var account: some View {
        HStack(spacing: 8) {
            Group {
                if let picture = Profile.current.picture {
                    Image(nsImage: picture).resizable().scaledToFill()
                } else {
                    Image(systemName: "person.crop.circle.fill").resizable().foregroundStyle(.secondary)
                }
            }
            .frame(width: 38, height: 38)
            .clipShape(Circle())
            VStack(alignment: .leading, spacing: 0) {
                Text(Profile.current.name).font(.system(size: 13, weight: .bold)).lineLimit(1)
                Text("Mac Account").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 6)
        .padding(.top, 3.5)
        .accessibilityElement(children: .combine)
    }

    private func row(_ item: SettingsPane) -> some View {
        let selected = item == pane
        return Button { go(item) } label: {
            HStack(spacing: 4.5) {
                SidebarIcon(pane: item)
                Text(item.title)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Color.white : Color.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.leading, 7)
            .frame(height: 32)
            .background(selected ? Color(red: 0, green: 0.478, blue: 1) : .clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func move(_ direction: MoveCommandDirection) {
        let items = SettingsPane.groups.joined().filter(matches)
        guard let index = items.firstIndex(of: pane) else { return }
        if direction == .up, index > 0 { go(items[index - 1]) }
        if direction == .down, index < items.count - 1 { go(items[index + 1]) }
    }

    var body: some View {
        NavigationSplitView {
            // Measured from System Settings: 32 pt rows, 20 pt icons 18 pt in, text at 45 pt,
            // a 9 pt inset selection and 13 pt between groups.
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    account
                    ForEach(SettingsPane.groups.indices, id: \.self) { index in
                        let items = SettingsPane.groups[index].filter(matches)
                        if !items.isEmpty {
                            VStack(spacing: 0) {
                                ForEach(items) { row($0) }
                            }
                            .padding(.top, index == 0 ? 16.5 : 13)
                        }
                    }
                }
                .padding(.horizontal, 9)
                .padding(.bottom, 12)
            }
            .focusable()
            .focusEffectDisabled()
            .onMoveCommand { move($0) }
            .searchable(text: $query, placement: .sidebar, prompt: "Search")
            .frame(minWidth: 231)
            .navigationSplitViewColumnWidth(min: 231, ideal: 231, max: 231)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            SettingsView(pane: pane, app: app, setUp: setUp, open: go)
                .navigationTitle(pane.title)
                .toolbar {
                    ToolbarItemGroup(placement: .navigation) {
                        Button("Back", systemImage: "chevron.left") {
                            if let previous = back.popLast() {
                                forward.append(pane)
                                selection = previous.rawValue
                            }
                        }
                        .disabled(back.isEmpty)
                        Button("Forward", systemImage: "chevron.right") {
                            if let next = forward.popLast() {
                                back.append(pane)
                                selection = next.rawValue
                            }
                        }
                        .disabled(forward.isEmpty)
                    }
                }
        }
        .frame(width: 740)
        .frame(minHeight: 560, idealHeight: 780, maxHeight: .infinity)
        .onChange(of: pane, initial: true) { _, pane in titleChanged(pane.title) }
    }
}

/// Apple's own icon, read from this Mac at run time (nothing of Apple's is bundled), or a matching
/// dark tile with a coloured glyph.
struct SidebarIcon: View {
    var pane: SettingsPane

    private var appleIcon: NSImage? {
        guard let name = pane.systemIcon else { return nil }
        let path = "/System/Library/ExtensionKit/Extensions/\(name).appex"
        return FileManager.default.fileExists(atPath: path) ? NSWorkspace.shared.icon(forFile: path) : nil
    }

    var body: some View {
        if let appleIcon {
            Image(nsImage: appleIcon).resizable().interpolation(.high).frame(width: 25, height: 25)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                    .fill(LinearGradient(colors: [Color(white: 0.16), Color(white: 0.06)], startPoint: .top, endPoint: .bottom))
                RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [.white.opacity(0.28), .white.opacity(0.06)],
                                                 startPoint: .top, endPoint: .bottom), lineWidth: 0.75)
                if pane == .main {
                    FaceGlyph(color: .green).frame(width: 17, height: 17)
                } else {
                    Image(systemName: pane == .security ? "checkmark.shield.fill" : pane.symbol)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(pane.tint.gradient)
                }
            }
            .frame(width: 20, height: 20)
            .frame(width: 25, height: 25)
        }
    }
}

/// A settings row's icon and title.
struct RowLabel: View {
    var title: String
    var symbol: String
    init(_ title: String, _ symbol: String) {
        self.title = title
        self.symbol = symbol
    }

    private var tint: Color {
        switch symbol {
        case "brain", "sparkles": .purple
        case "eye", "eye.circle", "hand.tap", "checkmark.circle": .green
        case "xmark.circle", "person.crop.circle.badge.exclamationmark": .red
        case "lock.fill", "slider.horizontal.3": .gray
        default: Color(nsColor: .systemBlue)
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                    .fill(LinearGradient(colors: [Color(white: 0.16), Color(white: 0.06)], startPoint: .top, endPoint: .bottom))
                RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                    .strokeBorder(.white.opacity(0.16), lineWidth: 0.75)
                Image(systemName: symbol).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(tint.gradient)
            }
            .frame(width: 20, height: 20)
            .accessibilityHidden(true)
            Text(title)
        }
    }
}

struct SymbolTile: View {
    var symbol: String
    var tint: Color
    var size: CGFloat = 22

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.54, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tint.gradient, in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
    }
}

struct SettingsView: View {
    var pane: SettingsPane
    @Bindable var app: AppModel
    var setUp: (_ appearance: Appearance) -> Void
    var open: (SettingsPane) -> Void = { _ in }
    @State private var confirmingReset = false
    /// Where the time slider is while it is being dragged.
    @State private var draggedStep: Double?
    @State private var dragging = false
    @State private var adding = false
    @State private var chosen: Appearance?

    var body: some View {
        Form {
            header
            switch pane {
            case .general: general
            case .appearance: appearancePane
            case .main: main
            case .security: security
            case .unlocking: unlocking
            case .alerts: alerts
            case .activity: activity
            case .privacy: privacy
            }
        }
        .formStyle(.grouped)
        .contentMargins(.top, -8.5, for: .scrollContent)
        .toggleStyle(.switch)
        .task {
            while !Task.isCancelled {
                app.refresh()
                await app.refreshNotificationStatus()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// The card at the top of each System Settings page.
    private var header: some View {
        Section {
            HStack(alignment: .top, spacing: 10) {
                SidebarIcon(pane: pane).scaleEffect(1.3).frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(pane.title)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(pane.summary).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        if pane != .privacy {
                            Button("Learn more…") { open(.privacy) }
                                .buttonStyle(.plain).foregroundStyle(Color(nsColor: .linkColor))
                        }
                    }
                    .font(.system(size: 11))
                }
            }
            .padding(.vertical, 3)
        }
    }

    /// A row that opens another page, like those in Accessibility.
    private func link(_ item: SettingsPane) -> some View {
        Button { open(item) } label: {
            HStack(spacing: 8) {
                SidebarIcon(pane: item)
                Text(item.title)
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 1)
        }
        .buttonStyle(.plain)
    }

    // MARK: General

    private var version: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "") (\(info?["CFBundleVersion"] as? String ?? ""))"
    }

    @ViewBuilder private var general: some View {
        Section {
            VStack(spacing: 6) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
                    .accessibilityHidden(true)
                Text("FaceUnlock").font(.system(size: 22, weight: .bold))
                Text("Version \(version)").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
        Section {
            LabeledContent("Status", value: app.statusText)
            Toggle("Open FaceUnlock at login", isOn: $app.launchAtLogin)
        }
        Section("About") {
            LabeledContent("Face recognition model", value: "SFace (OpenCV Zoo)")
            if AppModel.hasSpoofModel {
                LabeledContent("Anti-spoofing model", value: "MiniFASNet (facenox)")
            }
            LabeledContent("Open-source licences") {
                Button("Show…") {
                    if let url = Bundle.main.url(forResource: "NOTICES", withExtension: "md") {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
            }
        }
        Section {
            LabeledContent("Website") { Link("faceunlock.app", destination: URL(string: "https://faceunlock.app")!) }
            LabeledContent("Support") {
                Link("support@faceunlock.app", destination: URL(string: "mailto:support@faceunlock.app")!)
            }
            LabeledContent("Detailed log") { Button("Open") { NSWorkspace.shared.open(EventLog.url) } }
        } footer: {
            footer("Not made by or affiliated with Apple.")
        }
    }

    // MARK: Face Unlock & Password

    @ViewBuilder private var main: some View {
        if let reason = app.passwordRequiredReason, app.isEnabled, app.isSetUp {
            Section {
                LabeledContent {
                    Button("Use Touch ID…") { app.confirmWithTouchID() }
                } label: {
                    Label(reason.message, systemImage: "lock.fill")
                }
            }
        }

        Section("Password") {
            LabeledContent(app.hasPassword ? "Your login password is saved for unlocking this Mac."
                                           : "No login password is saved yet.") {
                if app.hasPassword {
                    Button("Remove…") { app.removePassword() }
                } else {
                    Button("Add…") { setUp(.primary) }
                }
            }
        }

        Section {
            HStack(alignment: .top, spacing: 30) {
                Spacer(minLength: 0)
                if app.isSetUp {
                    ForEach(Appearance.allCases.filter { !app.enrollment[$0].isEmpty }) { appearanceButton($0) }
                }
                if !app.isSetUp || !missingAppearances.isEmpty { addButton }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 8)
        } header: {
            Text("Appearances")
        } footer: {
            footer(app.isSetUp
                   ? "Add how you look with glasses or a hat. Changing these needs Touch ID or your password. Masks aren’t supported."
                   : "Set up your face first. Then you can add how you look with glasses or a hat.")
        }

        Section {
            Toggle("Unlock with Front Camera", isOn: Binding(
                get: { app.isEnabled && app.isSetUp },
                set: { on in
                    if on && (!app.isSetUp || !app.hasPassword || !app.accessibilityTrusted) {
                        setUp(.primary)
                    } else {
                        app.isEnabled = on
                    }
                }))
            Toggle("Require attention to unlock", isOn: guarded(\.requiresAttention))
        } footer: {
            footer("Use the front camera, along with a recent Touch ID or password authentication, to quickly unlock your Mac. Face recognition data never leaves your Mac. To make purchases or to access your passwords, Touch ID or your password is still required.")
        }

        if app.isSetUp {
            Section {
                LabeledContent("Test Recognition") { Button("Test") { app.testRecognition() } }
                if let result = app.testResult {
                    Text(result).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
        }

        Section("More") {
            link(.security)
            link(.unlocking)
            link(.alerts)
            link(.appearance)
        }

        if !(app.cameraAuthorized && app.accessibilityTrusted && app.notificationsAllowed) {
            Section("Permissions Needed") {
                if !app.cameraAuthorized {
                    permission("Camera", "com.apple.preference.security?Privacy_Camera")
                }
                if !app.accessibilityTrusted {
                    permission("Accessibility", "com.apple.preference.security?Privacy_Accessibility")
                }
                if !app.notificationsAllowed {
                    permission("Notifications", "com.apple.Notifications-Settings.extension")
                }
            }
        }

        Section {
        } footer: {
            HStack {
                Spacer()
                Button { open(.privacy) } label: { Image(systemName: "questionmark") }
                    .buttonStyle(.bordered).buttonBorderShape(.circle).controlSize(.large)
                    .help("About FaceUnlock and privacy")
            }
        }
    }

    private var missingAppearances: [Appearance] {
        Appearance.allCases.filter { app.enrollment[$0].isEmpty }
    }

    private func circleLabel(_ name: String, @ViewBuilder icon: () -> some View) -> some View {
        VStack(spacing: 6) {
            icon().frame(width: 46, height: 46).background(.quaternary, in: Circle())
            Text(name).multilineTextAlignment(.center)
        }
        .frame(minWidth: 72)
        .contentShape(Rectangle())
    }

    /// Face scans again on a click; the others offer to scan again or be removed.
    private func appearanceButton(_ item: Appearance) -> some View {
        Button {
            if item == .primary { setUp(item) } else { chosen = item }
        } label: {
            circleLabel(item.shortTitle) {
                if item == .primary {
                    FaceGlyph(pose: .init(arcs: [0.5, 0.5, 0.5, 0.5]), color: .primary).padding(7)
                } else {
                    Image(systemName: item.symbol).font(.system(size: 20))
                }
            }
        }
        .buttonStyle(.plain)
        .help(item == .primary ? "Scan again" : "Scan again or remove")
        .popover(isPresented: Binding(get: { chosen == item }, set: { if !$0 { chosen = nil } }), arrowEdge: .bottom) {
            choices {
                choice("Scan Again…", "arrow.clockwise") { setUp(item) }
                choice("Remove…", "trash") { app.remove(item) }
            }
        }
    }

    private var addButton: some View {
        Button {
            if app.isSetUp { adding = true } else { setUp(.primary) }
        } label: {
            circleLabel(app.isSetUp ? "Add Appearance" : "Add Face") {
                Image(systemName: "plus").font(.title2).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .popover(isPresented: $adding, arrowEdge: .bottom) {
            choices {
                ForEach(missingAppearances) { item in
                    choice(item.title, item.symbol) { setUp(item) }
                }
            }
        }
    }

    private func choices(@ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 2, content: content)
            .padding(8)
            .frame(minWidth: 210, alignment: .leading)
    }

    private func choice(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button {
            chosen = nil
            adding = false
            action()
        } label: {
            Label(title, systemImage: symbol)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 5).padding(.horizontal, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func permission(_ name: String, _ link: String) -> some View {
        LabeledContent(name) {
            Button("Open Settings…") {
                if name == "Accessibility" { PasswordTyper.requestTrust() }
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:\(link)")!)
            }
        }
    }

    // MARK: Unlocking

    @ViewBuilder private var unlocking: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("Require password after") {
                    Text(Self.duration(draggedStep.map { UnlockPolicy.timeLimits[Int($0.rounded())] } ?? app.timeLimit))
                        .monospacedDigit()
                }
                Slider(value: timeLimitStep, in: 0...Double(UnlockPolicy.timeLimits.count - 1), step: 1) {
                    Text("Time limit")
                } minimumValueLabel: {
                    Text("5 min")
                } maximumValueLabel: {
                    Text("3 hr")
                } onEditingChanged: { editing in
                    // Applied on release, so a longer time asks for Touch ID once.
                    dragging = editing
                    if !editing, let step = draggedStep {
                        draggedStep = nil
                        setTimeLimit(step)
                    }
                }
                .labelsHidden()
                if app.timeLimit != UnlockPolicy.defaultTimeLimit {
                    Button("Use 45 Minutes") {
                        var proposed = app.security
                        proposed.timeLimit = UnlockPolicy.defaultTimeLimit
                        app.propose(proposed)
                    }
                        .buttonStyle(.link)
                }
            }
            Picker("Count the time", selection: guarded(\.window)) {
                Text("While sitting locked").tag(UnlockPolicy.Window.inactivity)
                Text("Since last password").tag(UnlockPolicy.Window.strict)
            }
            Picker("Unrecognized attempts allowed", selection: guarded(\.failureLimit)) {
                ForEach([3, 4, 5], id: \.self) { Text("\($0)").tag($0) }
            }
            LabeledContent("Mac password") {
                if app.hasPassword {
                    Button("Remove") { app.removePassword() }
                } else {
                    Button("Add…") { setUp(.primary) }
                }
            }
        } header: {
            Text("Require Password")
        } footer: {
            footer("A shorter time is safer. A longer one asks for your password less often.")
        }

        Section {
            Picker(selection: $app.walkAwayDelay) {
                Text("Never").tag(0)
                Text("After 30 seconds").tag(30)
                Text("After 1 minute").tag(60)
                Text("After 2 minutes").tag(120)
            } label: {
                RowLabel("Lock When You Leave", "figure.walk.departure")
            }
            toggle("Keep Display Awake While You’re Looking", "eye", $app.keepAwake)
        } header: {
            Text("Presence")
        } footer: {
            footer("Both briefly turn on the camera when you’ve stopped typing. Before locking, you get a 5-second warning.")
        }

        Section("Pause") {
            if app.isPaused {
                Button { app.resume() } label: { Label("Resume Face Unlock", systemImage: "play.fill") }
            } else {
                Button { app.pause(for: 3600) } label: { Label("Pause for 1 Hour", systemImage: "pause.fill") }
            }
        }
    }

    // MARK: Security

    @ViewBuilder private var security: some View {
        Section {
            Picker("Protection", selection: guarded(\.protection)) {
                Text("Standard").tag(AppModel.Protection.standard)
                Text("High").tag(AppModel.Protection.high)
                Text("Maximum").tag(AppModel.Protection.maximum)
            }
            .pickerStyle(.segmented)
            Text(protectionDetail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } header: {
            Text("Protection")
        }

        Section {
            if AppModel.hasSpoofModel {
                toggle("Anti-Spoofing Model (Experimental)", "brain", guarded(\.usesSpoofModel))
            }
            toggle("Require Attention", "eye.circle", guarded(\.requiresAttention))
            toggle("Only When You’re Alone", "person.fill.checkmark", guarded(\.requiresSolitude))
            Picker(selection: guarded(\.strictness)) {
                Text("Balanced").tag(AppModel.Strictness.balanced)
                Text("Strict").tag(AppModel.Strictness.strict)
            } label: {
                RowLabel("Face Matching", "slider.horizontal.3")
            }
        } header: {
            Text("Checks")
        } footer: {
            footer(AppModel.hasSpoofModel
                   ? "The experimental model can mistake your real face for a fake and stop you unlocking. Leave it off until Test Recognition shows a positive anti-spoof score for you. A good video or mask may still get through with or without it."
                   : "A camera can’t measure depth. A good video, photo or mask may still get through.")
        }
    }

    private var protectionDetail: String {
        switch app.protection {
        case .standard: "Rejects screens and photos it can spot. Never asks you to do anything."
        case .high: "Also waits for a blink or a natural head movement."
        case .maximum: "Also asks you to turn your head left or right, chosen at random, so a recording can’t prepare."
        }
    }

    // MARK: Alerts

    @ViewBuilder private var appearancePane: some View {
        Section("Notch Style") {
            NotchStylePicker(app: app)
        }

        Section {
            toggle("Show Animation While Unlocking", "sparkles", $app.showsNotch)
            Picker(selection: $app.notchFollowsPointer) {
                Text("Built-in Display").tag(false)
                Text("Display with Pointer").tag(true)
            } label: {
                RowLabel("Show On", "display.2")
            }
            Picker(selection: $app.captureStyle) {
                Text("Four Arcs").tag(CaptureStyle.arcs)
                Text("Tick Ring").tag(CaptureStyle.ticks)
            } label: {
                RowLabel("Face Setup Guide", "viewfinder")
            }
        }
    }

    @ViewBuilder private var alerts: some View {
        Section("Sounds & Haptics") {
            toggle("Sound Effects", "speaker.wave.2.fill", $app.soundEffects)
            if app.soundEffects {
                Slider(value: $app.soundVolume, in: 0.1...1) {
                    Text("Volume")
                } minimumValueLabel: {
                    Image(systemName: "speaker.fill").accessibilityLabel("Quieter")
                } maximumValueLabel: {
                    Image(systemName: "speaker.wave.3.fill").accessibilityLabel("Louder")
                }
                LabeledContent("Hear them") {
                    Menu("Play") {
                        ForEach(SoundEffect.allCases) { effect in
                            Button(effect.title) { Sounds.play(effect) }
                        }
                    }
                    .fixedSize()
                }
            }
            toggle("Haptic Feedback", "hand.tap", $app.hapticOnUnlock)
        }
        Section {
            Picker("Alerts appear in", selection: $app.alertStyle) {
                Text("The Notch").tag(AppModel.AlertStyle.notch)
                Text("Notification Center").tag(AppModel.AlertStyle.notificationCenter)
                Text("Both").tag(AppModel.AlertStyle.both)
            }
            toggle("Report Unrecognized Attempts", "person.crop.circle.badge.exclamationmark", $app.reportsAttempts)
        } footer: {
            footer("The notch can’t appear while your Mac is asleep. Choose Both to also get a record in Notification Center.")
        }
        Section("See Them Now") {
            preview("Face Unlock Paused", "lock.fill", .paused)
            preview("Unrecognized Attempts", "person.crop.circle.badge.exclamationmark", .attempts)
            preview("Stepped Away", "figure.walk.departure", .walkAway)
            preview("Unlock Animation", "lock.open", .unlock)
            preview("Not Recognized", "xmark.circle", .failure)
        }
    }

    // MARK: Activity

    @ViewBuilder private var activity: some View {
        if app.history.events.isEmpty {
            Section {
                ContentUnavailableView("No Activity Yet", systemImage: "clock",
                                       description: Text("Unlocks and refused attempts appear here."))
            }
        } else {
            Section {
                ForEach(app.history.events.prefix(40)) { event in
                    let look = Self.look(event.kind)
                    HStack(spacing: 10) {
                        SymbolTile(symbol: look.symbol, tint: look.tint)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(look.title)
                            if !event.detail.isEmpty {
                                Text(event.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                        Spacer()
                        Text(event.date, format: .dateTime.weekday().hour().minute()).foregroundStyle(.secondary)
                    }
                }
            }
            Section { Button("Clear Activity", role: .destructive) { app.history.clear() } }
        }
        Section {
            Button { NSWorkspace.shared.open(EventLog.url) } label: {
                Label("Show Detailed Log", systemImage: "doc.text.magnifyingglass")
            }
        }
    }

    static func look(_ kind: History.Event.Kind) -> (title: String, symbol: String, tint: Color) {
        switch kind {
        case .faceUnlock: ("Unlocked with Your Face", "checkmark", .green)
        case .passwordUnlock: ("Unlocked with Password or Touch ID", "key.fill", .gray)
        case .rejected: ("Face Not Recognized", "xmark", .red)
        case .spoof: ("Photo or Screen Refused", "exclamationmark.shield.fill", .red)
        case .noLiveness: ("No Proof of a Live Face", "eye.slash.fill", .orange)
        case .paused: ("Paused", "pause.fill", .gray)
        case .walkAway: ("Locked When You Left", "figure.walk.departure", .blue)
        case .typingFailed: ("Automatic Unlock Failed", "keyboard.badge.exclamationmark", .red)
        }
    }

    // MARK: Privacy

    @ViewBuilder private var privacy: some View {
        Section {
            point("desktopcomputer", "Stays on this Mac", "Recognition runs on device. FaceUnlock makes no network requests.")
            point("photo.badge.checkmark", "No pictures kept", "Your face is stored as encrypted numbers, not images.")
            point("key.horizontal", "Password in your keychain", "It’s used only to unlock this Mac’s screen.")
        }
        Section {
            toggle("Update Face Data Automatically", "arrow.triangle.2.circlepath", guarded(\.adaptsToFace))
            if !app.enrollment.updates.isEmpty {
                LabeledContent("\(app.enrollment.updates.count) of \(FaceAdaptation.capacity) updates stored") {
                    Button("Forget") { app.forgetUpdates() }
                }
            }
        } footer: {
            footer("Learns from unlocks, so recognition keeps up as your appearance changes. Your original setup is never altered.")
        }
        Section {
            Button(role: .destructive) { confirmingReset = true } label: {
                Label("Reset FaceUnlock…", systemImage: "trash")
            }
        }
        .confirmationDialog("Reset FaceUnlock?", isPresented: $confirmingReset) {
            Button("Reset", role: .destructive) { app.reset() }
        } message: {
            Text("This deletes your face data and the saved password from this Mac.")
        }
    }

    // MARK: Pieces

    /// A control for one protective choice.
    private func guarded<Value>(_ choice: WritableKeyPath<SecuritySettings, Value>) -> Binding<Value> {
        Binding {
            app.security[keyPath: choice]
        } set: {
            var proposed = app.security
            proposed[keyPath: choice] = $0
            app.propose(proposed)
        }
    }

    /// The slider moves along the list of choices, so short times aren't crowded together.
    private var timeLimitStep: Binding<Double> {
        Binding {
            draggedStep ?? Double(UnlockPolicy.timeLimits.firstIndex { $0 >= app.timeLimit } ?? UnlockPolicy.timeLimits.count - 1)
        } set: {
            // Keyboard and accessibility changes arrive without a drag.
            if dragging { draggedStep = $0 } else { setTimeLimit($0) }
        }
    }

    private func setTimeLimit(_ step: Double) {
        var proposed = app.security
        proposed.timeLimit = UnlockPolicy.timeLimits[Int(step.rounded())]
        app.propose(proposed)
    }

    static func duration(_ minutes: Int) -> String {
        Duration.seconds(minutes * 60).formatted(.units(allowed: [.hours, .minutes], width: .wide))
    }

    private func toggle(_ title: String, _ symbol: String, _ value: Binding<Bool>) -> some View {
        Toggle(isOn: value) { RowLabel(title, symbol) }
    }

    private func preview(_ title: String, _ symbol: String, _ kind: AppModel.Preview) -> some View {
        LabeledContent {
            Button("Preview") { app.preview(kind) }
        } label: {
            RowLabel(title, symbol)
        }
    }

    private func point(_ symbol: String, _ title: String, _ text: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(text).font(.callout).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: symbol).foregroundStyle(Theme.accent)
        }
    }

    private func footer(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
    }
}
