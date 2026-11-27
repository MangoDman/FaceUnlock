import SwiftUI

/// `FaceUnlock --snapshots <folder>` draws each screen to PNG, for design review without a
/// camera or permissions. Uses real AppKit windows so system controls render properly.
@MainActor
enum Snapshots {
    static func render(to folder: URL, app: AppModel) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        func save(_ name: String, size: CGSize, scheme: ColorScheme = .dark, _ view: some View) {
            let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height)
                .background(Color(nsColor: .windowBackgroundColor)))
            let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            window.contentView = hosting
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 1.2))
            guard let image = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
            hosting.cacheDisplay(in: hosting.bounds, to: image)
            try? image.representation(using: .png, properties: [:])?.write(to: folder.appending(path: "\(name).png"))
        }

        let page = CGSize(width: 400, height: 580)
        func setup(_ step: SetupModel.Step, scheme: ColorScheme = .dark, name: String, machine: EnrollmentMachine? = nil) {
            let model = SetupModel(app: app, step: step)
            if let machine { model.machine = machine }
            save(name, size: page, scheme: scheme, SetupView(model: model, app: app, close: {}, placeholderFeed: true))
        }

        // Drive the real state machine part-way for the capture screens.
        var turning = EnrollmentMachine()
        var time = 0.0
        func feed(_ sample: FaceSample, seconds: Double) {
            for _ in 0..<Int(seconds * 10) {
                _ = turning.process(sample, at: time)
                time += 0.1
            }
        }
        feed(FaceSample(), seconds: 1.2)
        feed(FaceSample(yaw: 0.35), seconds: 0.6)
        feed(FaceSample(pitch: 0.43), seconds: 0.6)

        // `--demo` has no face data; pretend, so the appearance rows are drawn.
        if CommandLine.arguments.contains("--demo") { app.showSampleAppearances() }
        setup(.intro, name: "01-intro")
        setup(.howTo, name: "02-how-to")
        setup(.capture, name: "03-capture", machine: turning)
        setup(.done, name: "04-done")
        app.captureStyle = .ticks
        setup(.capture, name: "14-capture-ticks", machine: turning)
        app.captureStyle = .arcs
        setup(.password, scheme: .light, name: "05-password")
        setup(.accessibility, scheme: .light, name: "06-accessibility")

        for pane in SettingsPane.allCases {
            save("07-settings-\(pane.rawValue)", size: CGSize(width: 540, height: 640), scheme: .dark,
                 SettingsView(pane: pane, app: app) { _ in })
        }

        let phases: [(String, NotchState.Phase)] = [
            ("scanning", .scanning), ("success", .success(nil)), ("failure", .failure("Face Not Recognized")),
            ("password", .passwordRequired),
            ("notice", .notice(symbol: "person.crop.circle.badge.exclamationmark", title: "2 Unrecognized Attempts",
                               message: "While your Mac was locked.")),
            ("prompt", .prompt(title: "Face Unlock Paused", message: UnlockPolicy.Reason.timedOut.message)),
        ]
        // The three kinds of display, as chosen automatically, plus the styles picked by hand.
        for (variant, preference, kind) in [("expanded", NotchState.Preference.automatic, ScreenKind.notch),
                                            ("island", .automatic, .island), ("pill", .automatic, .plain),
                                            ("drop", .drop, .notch), ("compact", .compact, .notch)] {
            for (name, phase) in phases {
                let state = NotchState()
                state.preference = preference
                state.screen = kind
                state.notch = kind == .notch ? CGSize(width: 185, height: 38)
                    : kind == .island ? CGSize(width: 62, height: 22) : CGSize(width: 90, height: 0)
                state.topInset = kind == .island ? 7 : 0
                state.phase = phase
                save("notch-\(variant)-\(name)", size: CGSize(width: 460, height: 300),
                     NotchView(state: state, frozenAt: 0.4))
            }
        }
        save("11-instruction-frames", size: CGSize(width: 700, height: 150),
             HStack {
                 ForEach([0.0, 1.5, 3.4, 5.2, 6.8, 8.1], id: \.self) { InstructionGlyph(frozenAt: $0) }
             }.padding())
    }
}
