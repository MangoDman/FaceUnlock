import SwiftUI

@MainActor @Observable
final class SetupModel {
    enum Step: Equatable { case intro, howTo, capture, done, password, accessibility, finished }

    var step: Step
    var machine = EnrollmentMachine()
    var errorMessage: String?
    /// Extra help, shown only when a side is taking a while.
    var hint: String?
    let appearance: Appearance
    private let app: AppModel
    private var templates: [[Float]] = []
    private var task: Task<Void, Never>?

    init(app: AppModel, appearance: Appearance = .primary, step: Step? = nil) {
        self.app = app
        self.appearance = appearance
        self.step = step ?? (appearance == .primary ? .intro : .howTo)
    }

    var session: CameraService { app.camera }

    func beginCapture() {
        errorMessage = nil
        task?.cancel()
        task = Task {
            guard app.embedder != nil else {
                errorMessage = "The face model is missing from this build."
                return
            }
            guard await CameraService.requestAccess() else {
                errorMessage = "Allow camera access in System Settings › Privacy & Security › Camera."
                return
            }
            guard CameraService.builtInCamera != nil else {
                errorMessage = "The built-in camera isn’t available. Open the lid and try again."
                return
            }
            app.refresh()
            restartScan()
            step = .capture
            var completedAt: TimeInterval?
            var progressAt: TimeInterval?
            var loggedAt: TimeInterval = 0
            var smoothed: FaceSample?
            await app.watch { result, vector, time in
                if let completedAt {
                    // Keep the picture live behind the checkmark for a moment.
                    return time - completedAt < 2.2
                }
                // Smooth the jitter in landmark positions without adding noticeable lag.
                var sample = result.sample
                if let last = smoothed, sample.faceCount == 1, last.faceCount == 1 {
                    sample.yaw = last.yaw * 0.4 + sample.yaw * 0.6
                    sample.pitch = last.pitch * 0.4 + sample.pitch * 0.6
                }
                smoothed = sample

                var next = machine
                let wantsTemplate = next.process(sample, at: time)
                if wantsTemplate {
                    // Only ever store vectors that are the same person as the first, straight-on one.
                    let samePerson = vector.flatMap { v in
                        templates.first.map { FaceMath.similarity($0, v) > 0.2 } ?? true ? v : nil
                    }
                    // The first and last shots must be good. A side view that doesn't match well still
                    // lights its arc; it just isn't kept.
                    if samePerson == nil, next.phase != .turning && next.phase != .lookStraight || templates.isEmpty {
                        return true
                    }
                    if let samePerson { templates.append(samePerson) }
                    progressAt = time
                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                }
                machine = next

                // Numbers only, so a scan that won't progress can be tuned from the log.
                if time - loggedAt > 0.7 {
                    loggedAt = time
                    EventLog.write(String(format: "Setup %@: faces %d, nose %.2f/%.2f, angle %.2f/%.2f, captured %d",
                                          "\(machine.phase)", sample.faceCount, sample.yaw, sample.pitch,
                                          sample.headYaw ?? 0, sample.headPitch ?? 0, machine.captured.count))
                }
                if progressAt == nil { progressAt = time }
                if machine.phase == .turning, time - (progressAt ?? time) > 3, let needed = machine.nextNeeded {
                    hint = switch needed {
                    case .left: "Turn your head a little to the left."
                    case .right: "Turn your head a little to the right."
                    case .up: "Tip your chin up a little."
                    case .down: "Tip your chin down a little."
                    }
                } else {
                    hint = nil
                }
                guard machine.phase == .complete else { return true }
                do {
                    try app.saveEnrollment(templates, as: appearance)
                } catch {
                    errorMessage = "Your face data couldn’t be saved: \(error.localizedDescription)"
                    step = .howTo
                    return false
                }
                step = .done
                completedAt = time
                return true
            }
            if Task.isCancelled { return }
            if step == .done {
                advanceAfterScan()
            } else if step == .capture {
                errorMessage = "Setup was interrupted. Click Continue to try again."
                step = .howTo
            }
        }
    }

    func restartScan(headTurns: Bool? = nil) {
        let turns = headTurns ?? machine.requiresHeadTurns
        machine = EnrollmentMachine(requiresHeadTurns: turns)
        templates = []
        hint = nil
    }

    func advanceAfterScan() {
        app.refresh()
        step = !app.hasPassword ? .password : !app.accessibilityTrusted ? .accessibility : .finished
    }

    func submit(password: String) {
        if app.savePassword(password) {
            errorMessage = nil
            advanceAfterScan()
        } else {
            errorMessage = "That isn’t the password for this Mac account."
        }
    }

    func finish(enable: Bool) {
        app.refresh()
        if enable { app.isEnabled = true }
    }

    func cancel() { task?.cancel() }
}

struct SetupView: View {
    @Bindable var model: SetupModel
    var app: AppModel
    var close: () -> Void
    /// Replaces the live camera when rendering screenshots.
    var placeholderFeed = false

    @State private var password = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                if model.step != .done && model.step != .intro {
                    Button("Close", systemImage: "xmark") { close() }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.glass)
                        .buttonBorderShape(.circle)
                        .keyboardShortcut(.cancelAction)
                }
            }
            .frame(height: 32)

            switch model.step {
            case .intro: intro
            case .howTo: howTo
            case .capture, .done: capture
            case .password: passwordStep
            case .accessibility: accessibility
            case .finished: finished
            }
        }
        .padding(20)
        .frame(width: 400, height: 580)
        .animation(.smooth(duration: 0.35), value: model.step)
    }

    private func page<Extra: View, Buttons: View>(
        title: String, text: String, @ViewBuilder icon: () -> some View,
        @ViewBuilder extra: () -> Extra = { EmptyView() }, @ViewBuilder buttons: () -> Buttons
    ) -> some View {
        VStack(spacing: 14) {
            icon().frame(width: 112, height: 112).padding(.top, 8)
            Text(title).font(.title2.bold()).multilineTextAlignment(.center)
            Text(text).font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            extra()
            if let error = model.errorMessage {
                Text(error).font(.callout).foregroundStyle(.red).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            VStack(spacing: 10) { buttons() }
        }
        .padding(.horizontal, 16)
    }

    private func primary(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).frame(maxWidth: .infinity) }
            .buttonStyle(.glassProminent).controlSize(.extraLarge).keyboardShortcut(.defaultAction)
    }

    private func secondary(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).frame(maxWidth: .infinity) }
            .buttonStyle(.glass).controlSize(.extraLarge)
    }

    private var intro: some View {
        page(title: "Unlock with Front Camera",
             text: "Your Mac can use the front camera to unlock after recognizing your face.\n\nThis provides convenience when you’re actively using your Mac but isn’t as secure as Touch ID. A photo or video of you could unlock it.") {
            FaceGlyph(color: .primary)
        } buttons: {
            primary("Get Started") { model.step = .howTo }
            secondary("Cancel", action: close)
        }
    }

    private var howTo: some View {
        page(title: model.appearance == .primary ? "How to Set Up Face Recognition" : "Set Up “\(model.appearance.title)”",
             text: (model.appearance.preparation.map { $0 + "\n\n" } ?? "") + "First, position your face in the camera frame. Then slowly turn your head left, right, up, and down to show all the angles of your face.") {
            InstructionGlyph()
        } buttons: {
            primary("Continue") { model.beginCapture() }
        }
    }

    private var capture: some View {
        VStack(spacing: 18) {
            CaptureCard(captured: model.machine.captured,
                        lookingStraight: model.machine.phase == .lookStraight,
                        complete: model.step == .done,
                        turn: model.machine.turn,
                        // The glow is a blur, which `--snapshots` can't draw.
                        hint: model.machine.phase == .turning && !placeholderFeed ? model.machine.nextNeeded : nil,
                        style: app.captureStyle) {
                if placeholderFeed {
                    LinearGradient(colors: [.gray.opacity(0.7), .black], startPoint: .top, endPoint: .bottom)
                } else {
                    CameraPreview(session: model.session.session, blurred: model.step == .done)
                }
            }
            VStack(spacing: 4) {
                let guidance = model.step == .done ? .done : model.machine.guidance
                if let hint = model.hint, model.step == .capture, guidance.title == nil {
                    Text(guidance.message).font(.headline)
                    Text(hint).foregroundStyle(Theme.accent).transition(.opacity)
                } else if let title = guidance.title {
                    Text(title).font(.headline)
                    Text(guidance.message).foregroundStyle(.secondary)
                } else {
                    Text(guidance.message).font(.headline)
                }
            }
            .multilineTextAlignment(.center)
            .frame(height: 74)
            .animation(.easeInOut(duration: 0.25), value: model.hint)
            Spacer(minLength: 0)
            if model.step == .capture {
                Menu("Accessibility Options") {
                    if model.machine.requiresHeadTurns {
                        Button("Set Up Without Head Movement") { model.restartScan(headTurns: false) }
                    } else {
                        Button("Set Up With Head Movement") { model.restartScan(headTurns: true) }
                    }
                    Picker("Guide Style", selection: Binding(get: { app.captureStyle }, set: { app.captureStyle = $0 })) {
                        Text("Four Arcs").tag(CaptureStyle.arcs)
                        Text("Tick Ring").tag(CaptureStyle.ticks)
                    }
                    Button("Start Over") { model.restartScan() }
                }
                .menuStyle(.button).buttonStyle(.glass).controlSize(.large).fixedSize()
            }
        }
    }

    private var passwordStep: some View {
        page(title: "Enter Your Mac Password",
             text: "To unlock the screen, FaceUnlock types your password for you. It’s checked now, saved in your login keychain, and never sent anywhere.") {
            Image(systemName: "key.fill").font(.system(size: 54)).foregroundStyle(.tint)
        } extra: {
            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder).controlSize(.large)
                .onSubmit(submitPassword)
        } buttons: {
            primary("Continue", action: submitPassword)
            secondary("Not Now") { model.step = .finished }
        }
    }

    private func submitPassword() {
        guard !password.isEmpty else { return }
        let entered = password
        password = ""
        model.submit(password: entered)
    }

    private var accessibility: some View {
        page(title: "Allow Accessibility Access",
             text: "macOS requires this before an app can type on the lock screen. Turn on FaceUnlock in System Settings › Privacy & Security › Accessibility.") {
            Image(systemName: "accessibility").font(.system(size: 62)).foregroundStyle(.tint)
        } buttons: {
            primary("Open Accessibility Settings") {
                PasswordTyper.requestTrust()
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            }
            secondary(app.accessibilityTrusted ? "Continue" : "Not Now") { model.step = .finished }
        }
        .task {
            guard !placeholderFeed else { return }
            while !Task.isCancelled, !app.accessibilityTrusted {
                try? await Task.sleep(for: .seconds(1))
                app.refresh()
            }
            if app.accessibilityTrusted { model.step = .finished }
        }
    }

    private var finished: some View {
        let complete = app.hasPassword && app.accessibilityTrusted
        return page(title: complete ? "You’re All Set" : "Face Recognition Is Set Up",
                    text: complete
                        ? "Lock your Mac, then move the pointer or press a key and look at the screen. Your password is still needed after \(SettingsView.duration(app.timeLimit)), and for purchases and passwords."
                        : "Unlocking stays off until your password is saved and Accessibility access is allowed. You can finish in Settings.") {
            Image(systemName: complete ? "checkmark.circle.fill" : "exclamationmark.circle")
                .font(.system(size: 70)).foregroundStyle(complete ? Color.accentColor : .orange)
        } buttons: {
            primary("Done") {
                model.finish(enable: complete && model.appearance == .primary)
                close()
            }
        }
    }
}
