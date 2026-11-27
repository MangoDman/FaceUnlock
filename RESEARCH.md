# iPhone Duo “Unlock with Front Camera”: research and Mac design

Researched 26 November 2026. The feature is in **iOS 27.3 beta 2**, so anything here can change before release (expected December).

Confidence labels: **Seen** = read off video frames. **Reported** = press coverage. **Unknown** = no source found.

## 1. What it is

A 2D face check using the Duo’s ordinary 12 MP outer selfie camera. It is **not Face ID**: there is no infrared projector and no depth map. Coverage notes the setup closely resembles face recognition on Apple’s HomeView. Apple has not published how matching or anti-spoofing works for it (**Unknown**).

## 2. Behaviour

| Rule | Confidence |
|---|---|
| Settings → Touch ID & Passcode → **Unlock with Front Camera**, off by default | Seen |
| Works only on the outer display with the phone closed | Reported |
| Unlocks the Lock Screen only. You still swipe up to reach the Home Screen | Seen |
| Apple Pay, passwords and logins still require Touch ID | Seen (Settings footer) |
| Needs a recent Touch ID or passcode unlock | Seen / Reported |
| Asks for Touch ID again after about 45 minutes. Sources disagree on whether that is 45 minutes of *inactivity* (MacRumors) or since the last Touch ID/passcode unlock | Reported |
| Works in decent light, weak in dim light, fails in darkness | Reported |
| A tester’s printed photo did not unlock it. One test, not proof of spoof resistance | Reported |
| Camera indicator (green dot) is lit during capture | Seen |
| Attention Aware features now also run on the Duo’s outer display, separately from this feature | Reported |
| Retry count, lockout, failure animation, haptics for this feature | **Unknown** |

For comparison, Face ID falls back to the passcode after restart, after 5 failed attempts, after 48 hours without an unlock, and after Emergency SOS. Nothing says the Duo feature follows the same list.

## 3. Setup flow, with on-screen text (Seen)

**Settings row**: “Unlock with Front Camera” + switch. Footer:
> Use the front camera, along with a recent Touch ID or passcode authentication, to quickly unlock iPhone Duo when it’s closed. Face recognition data never leaves your device. To use Apple Pay or to access your passwords, Touch ID is still required.

**Screen 1**: face glyph, title “Unlock with Front Camera”, two short paragraphs (the camera can unlock after recognising your face; this is convenient but not as secure as Touch ID or Face ID). Buttons **Get Started** (blue capsule) and **Cancel** (grey capsule).

**Screen 2**: animated face glyph, title “How to Set Up Face Recognition”, instruction to position your face in the frame, then slowly turn your head left, right, up and down. Button **Continue**, close button top right.

**Screen 3, capture**: live camera in a large rounded rectangle, with a circular guide made of **four arcs** (top, right, bottom, left) and the area outside the circle dimmed. One line of text underneath, plus an **Accessibility Options** capsule.

1. “Position your face within the frame.”
2. “Slowly turn your head left, right, up, and down.” Each arc turns **blue** and thicker as that direction is captured.
3. Over-rotation: bold “Head Turned Too Far”, grey “Slowly turn your head back toward the camera.”
4. All four blue: “Look straight ahead.”

**Screen 4, success**: “Face Recognition is now set up.” Then it returns to Settings with the switch on.

Both light and dark appearances exist. Capture took about 12 seconds in both videos.

## 4. Motion

Timings are measured from video, so treat them as approximate (±0.1 s).

### Instruction glyph (10.5 s sequence)
White line face (circle, two eyes, hooked nose, smile) inside four dim grey arcs.
- The head “turns” in 3D: the circle narrows and the features slide toward that side. Order: left, right, up, down.
- As each direction is reached, its arc brightens to white, thickens and moves slightly outward, and **stays lit**.
- The face blinks (eyes become dashes) once near the end, then rests with all four lit.

### Completion (about 1 s)
1. The four arcs close their gaps into one ring (~0.3 s).
2. The ring shrinks toward the face while the preview blurs and dims (~0.3 s).
3. A checkmark draws inside the ring (~0.3 s) and holds.

### Unlock glyph (Dynamic Island)
Same face and arcs in blue on black. Brightness pulses with a period of about **1.04 s**, light sweeping between roughly `#62D8FA` and `#225FA8`. The arcs breathe in and out slightly, and the eyes and smile brighten at a different phase from the ring.
Source: designer Andreas Storm’s recreation as published by Design Compass. Neither hands-on video shows it clearly, so this is the least certain item.

### Lock Screen
Wake → Lock Screen → recognition happens while it is visible → swipe up → Home Screen.

## 5. The two videos

- **MacRumors, [P_hmw2EtZxM](https://www.youtube.com/watch?v=P_hmw2EtZxM)** (dark appearance): intro and limits 0:24–1:03, setup 1:03–1:36, hands-on 1:52–3:20, Close to Lock from 3:27. The presenter calls unlocking very fast.
- **Brian Tong, [JTEFz01JNzY](https://www.youtube.com/watch?v=JTEFz01JNzY)** (light appearance): setup 0:33–1:00. Reports more failures in dim light and that the several unlock methods may confuse people.

## 6. Bringing it to macOS

| iPhone Duo | Mac equivalent | Notes |
|---|---|---|
| Outer front camera | Built-in FaceTime camera | Same class of 2D sensor |
| Dynamic Island glyph | Panel at the top of the screen | Notch, island or pill, depending on the Mac |
| Closed-only | Built-in camera only, lid open | External and Continuity cameras excluded |
| Touch ID & Passcode settings | App settings window | Third-party apps cannot add a pane to Apple’s Touch ID settings |
| Recent Touch ID or passcode | Recent password or Touch ID unlock | 45-minute window |
| Swipe up | Not needed | Typing the password goes straight to the desktop |
| Apple Pay / passwords excluded | Automatically true | The app only touches the lock screen |

### Unlocking the lock screen
macOS has **no public API** for a third-party app to unlock the screen.

- **Authorization plug-in**: Apple DTS says to consider them deprecated and not to start new ones ([thread 851093](https://developer.apple.com/forums/thread/851093)), and developers report breakage on macOS 27. A faulty one can also lock you out. Rejected.
- **Typing the password**: the approach [BLEUnlock](https://github.com/ts1/BLEUnlock) takes. The login password is kept in the Keychain and posted as keystrokes after a match. Needs Accessibility permission. **Not verified on macOS 27**: it has to be tested on the real lock screen.

### Face matching
Apple’s Vision framework finds faces, landmarks, head angles and capture quality, but has **no public face-identity API**. Telling people apart needs a separate face-embedding model. Vision’s general image feature print is not good enough to guard a login.

### What cannot be matched
- No Secure Enclave processing for the face data. The template can be encrypted at rest, but matching runs in the app’s own memory.
- A photo or video of the owner is a real risk with a 2D camera. A liveness check lowers it and does not remove it.
- No Mac App Store distribution for the keystroke approach.

## 7. Hardening and Apple design

- Several independent gates must pass: identity on the unlocking frame, glare and device-edge checks, an anti-spoofing network, blink or 3D head motion, and optionally a random head-turn challenge.
- Why blinking failed at first: closing the eyes dropped the match score, which reset the scan, including the blink it was waiting for.
- Anti-spoofing model: [facenox/face-antispoof-onnx](https://github.com/facenox/face-antispoof-onnx), MiniFASNetV2-SE, 128×128. Its authors report 98.2% on CelebA-Spoof. That figure does not hold up here: on this Mac's camera it rejected the owner's real face four times, so it is off by default and only records its score.
- Also looked at: [Silent-Face-Anti-Spoofing](https://github.com/minivision-ai/Silent-Face-Anti-Spoofing) (the architecture's origin) and [Ward](https://github.com/0ctave/ward), whose strongest check needs an infrared camera that Macs lack.
- Colour: system blue for setup progress, cyan to deep blue for the notch glyph (sampled from footage), green for the app icon.
- SF Symbols may not be used, or imitated, in app icons or logos, and its face symbol refers to Apple's Face ID, so the menu bar uses the app's own drawing.

## 8. The Dynamic Island on the 2026 MacBook Pro

Announced 28 October 2026. [Apple](https://www.apple.com/newsroom/2026/10/apple-unveils-groundbreaking-macbook-pro-with-proled-xdr-display/) calls it the home of Spotlight, Live Activities and Siri AI. Read from Apple’s press images: a small resting pill; an expanded rounded card starting at the top edge, with the icon top-left, text below or beside it and two capsule buttons (grey and tinted) along the bottom. [Leaked system assets](https://www.macrumors.com/2026/10/28/pill-shaped-macos-27-dynamic-island-macbook-pro/) show compact pills with an icon on the left and a status on the right. Timing, easing, hover behaviour and any authentication or lock-screen presentation are **not published**, so those are this app’s own choices.

### What this app does on each Mac

| Screen | Detection | Presentation |
|---|---|---|
| Dynamic Island | Built-in display reports multi-touch (macOS 27) | Card grows from the island, floating |
| Notch | Top safe-area inset above zero | The whole notch grows downward |
| Neither | Everything else, including external displays | Pill drops from above the screen edge and floats, with no neck |

There is no public island API, so detection and the island's size are assumptions, not yet checked on that hardware. Content and shape only move vertically.

### Setup head turns

A side counts when the nose moves far enough between the eyes and mouth, or Vision's head angle does, held for 0.15 s. The thresholds are in `EnrollmentMachine.swift`. They still need checking against a real face; the log records the measurements (numbers only) as `Setup …` lines.

## Sources
- [MacRumors](https://www.macrumors.com/2026/11/16/iphone-duo-face-unlock/)
- [9to5Mac](https://9to5mac.com/2026/11/16/iphone-duo-gets-one-of-face-ids-best-features-with-upcoming-ios-27-3-update/)
- [iDownloadBlog](https://www.idownloadblog.com/2026/11/25/unlock-with-front-camera-iphone-duo/)
- [Macworld](https://www.macworld.com/article/3295383/apple-solved-one-of-the-iphone-duos-biggest-issues-heres-how-to-set-it-up.html)
- [Gadget Hacks](https://apple.gadgethacks.com/news/iphone-duo-face-unlock-in-ios-273-what-it-unlocks/)
- [Design Compass](https://designcompass.org/en/2026/11/18/iphone-duo-face-unlock-animation/)
- Apple Developer Forums [857011](https://developer.apple.com/forums/thread/857011)
