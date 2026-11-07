import AppKit
import SwiftUI
import TEGCore

// MARK: - View model

final class SettingsViewModel: ObservableObject {
    private let manager: SettingsManager

    @Published var s: AppSettings {
        didSet {
            guard s != manager.value else { return }
            manager.set(s)
            let accepted = manager.value          // the manager clamps; reflect what was really stored
            if accepted != s { s = accepted }
        }
    }

    init(manager: SettingsManager) {
        self.manager = manager
        self.s = manager.value
        manager.addObserver { [weak self] new in
            DispatchQueue.main.async {
                if let self, self.s != new { self.s = new }
            }
        }
    }

    func reset() {
        manager.reset()
    }
}

// MARK: - Window

final class SettingsWindowController {
    private var window: NSWindow?
    private unowned let coordinator: AppCoordinator

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
    }

    func show() {
        if window == nil {
            let model = SettingsViewModel(manager: coordinator.settings)
            let root = SettingsRootView(model: model, status: coordinator.status, coordinator: coordinator)
            let w = NSWindow(contentViewController: NSHostingController(rootView: root))
            w.title = "Trackpad Edge Gestures"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        coordinator.recheckPermissions()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Views

private struct SliderRow: View {
    let title: String
    @Binding var value: Float
    let range: ClosedRange<Float>
    var format: (Float) -> String = { String(format: "%.2f", $0) }

    var body: some View {
        HStack {
            Text(title).frame(width: 190, alignment: .leading)
            Slider(value: $value, in: range)
            Text(format(value)).monospacedDigit().frame(width: 58, alignment: .trailing)
        }
    }
}

private func percent(_ v: Float) -> String { "\(Int((v * 100).rounded()))%" }

struct SettingsRootView: View {
    @ObservedObject var model: SettingsViewModel
    @ObservedObject var status: StatusModel
    let coordinator: AppCoordinator

    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gearshape") }
            gestures.tabItem { Label("Gestures", systemImage: "hand.draw") }
            levels.tabItem { Label("Volume & Brightness", systemImage: "speaker.wave.2") }
            haptics.tabItem { Label("Haptics", systemImage: "waveform") }
            media.tabItem { Label("Media", systemImage: "play.circle") }
            diagnostics.tabItem { Label("Diagnostics", systemImage: "stethoscope") }
        }
        .frame(width: 580, height: 440)
        .padding(.top, 6)
    }

    // MARK: General

    private var general: some View {
        Form {
            Toggle("Enable gesture control", isOn: $model.s.gesturesEnabled)
            Toggle("Launch at login", isOn: Binding(
                get: { model.s.launchAtLogin },
                set: { coordinator.setLaunchAtLogin($0) }))
            Text("Login item status: \(status.loginItem)").font(.caption).foregroundStyle(.secondary)
            Toggle("Only while media is playing", isOn: $model.s.mediaOnly)
            Toggle("Show on-screen level indicator", isOn: $model.s.showHUD)
            Section {
                Button("Reset all settings to defaults") { model.reset() }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Gestures

    private var gestures: some View {
        Form {
            Picker("Activation", selection: $model.s.activationMethod) {
                ForEach(ActivationMethod.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            if model.s.activationMethod == .modifier {
                Text("Hold Control + Option and scroll with two fingers: volume. Add Shift: brightness. Edge zones are not used in this mode.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            SliderRow(title: "Left zone (brightness)", value: $model.s.leftZoneWidth, range: AppSettings.zoneRange, format: percent)
            SliderRow(title: "Right zone (volume)", value: $model.s.rightZoneWidth, range: AppSettings.zoneRange, format: percent)
            SliderRow(title: "Sensitivity", value: $model.s.sensitivity, range: 0.5...3.0)
            SliderRow(title: "Minimum movement", value: $model.s.minMovement, range: 0.01...0.08, format: percent)
            Picker("Smoothing", selection: $model.s.smoothing) {
                ForEach(SmoothingLevel.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Toggle("Invert direction", isOn: $model.s.invertDirection)
            Toggle("Stop the page scrolling during a gesture (needs Accessibility)", isOn: $model.s.suppressScroll)
            Text("A little scroll movement before a gesture is recognised can still reach the app in front.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }

    // MARK: Volume & brightness

    private var levels: some View {
        Form {
            Section("Volume (right edge)") {
                Toggle("Enable volume gesture", isOn: $model.s.volumeEnabled)
                SliderRow(title: "Sensitivity", value: $model.s.volumeSensitivity, range: 0.5...2.0)
                Text(status.volume).font(.caption).foregroundStyle(.secondary)
                Text("A muted output unmutes when you go up; going down on a muted output does nothing.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Brightness (left edge, built-in display only)") {
                Toggle("Enable brightness gesture", isOn: $model.s.brightnessEnabled)
                SliderRow(title: "Sensitivity", value: $model.s.brightnessSensitivity, range: 0.5...2.0)
                Text(status.brightness).font(.caption).foregroundStyle(.secondary)
                Text("Uses a private Apple interface. Automatic brightness may adjust the level again afterwards.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Haptics

    private var haptics: some View {
        Form {
            Toggle("Haptic feedback", isOn: $model.s.hapticsEnabled)
            Picker("Pulse every", selection: $model.s.hapticIntervalPoints) {
                Text("5 points").tag(5)
                Text("10 points").tag(10)
                Text("20 points").tag(20)
            }
            .disabled(!model.s.hapticsEnabled)
            Toggle("Pulse when reaching the minimum or maximum", isOn: $model.s.hapticAtLimits)
                .disabled(!model.s.hapticsEnabled)
            Text("The value still changes smoothly; pulses only mark boundaries. macOS may skip a pulse (for example if you are not touching the trackpad), and this app cannot detect whether one was felt.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }

    // MARK: Media

    private var media: some View {
        Form {
            Text("Now: \(status.playback)")
            Toggle("Accept approximate detection (audio output activity)", isOn: $model.s.allowApproximate)
            Toggle("Use Music and Spotify play state", isOn: $model.s.useAppSignals)
            Section("What this can and cannot detect") {
                Text("macOS has no universal \"media is playing\" signal. Music and Spotify report their own state reliably. For other apps (browsers, VLC, QuickTime) the app only sees that some process has been producing audio for 2+ seconds. It cannot tell a paused session or a muted video from real playback, calls are excluded on a best-effort basis, and if the state is unknown gestures stay off. Use Manual override in the menu bar when detection is wrong.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Diagnostics

    private var diagnostics: some View {
        Form {
            Section("Status") {
                row("Overall", status.summary)
                row("Trackpad", status.trackpad)
                row("Scroll event tap", status.scrollTap)
                row("Playback", status.playback)
                row("Volume", status.volume)
                row("Brightness", status.brightness)
                row("Haptics", status.haptics)
                row("Accessibility", status.accessibility)
            }
            Section("Permissions") {
                HStack {
                    Button("Re-check") { coordinator.recheckPermissions() }
                    Button("Explain & open Accessibility settings") { Permissions.explainAccessibility() }
                    Button("Input Monitoring settings") { Permissions.openInputMonitoringSettings() }
                }
            }
            Section("Live contacts (this window only, never stored)") {
                Toggle("Show normalized touch positions", isOn: Binding(
                    get: { status.liveEnabled },
                    set: { coordinator.setLiveDiagnostics($0) }))
                if status.liveEnabled {
                    Text(status.liveText.isEmpty ? "Touch the trackpad…" : status.liveText)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Section("Recent errors") {
                if status.errors.isEmpty {
                    Text("None").foregroundStyle(.secondary)
                } else {
                    ForEach(Array(status.errors.suffix(8).enumerated()), id: \.offset) { item in
                        Text(item.element).font(.caption)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(title).frame(width: 130, alignment: .leading)
            Text(value).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
