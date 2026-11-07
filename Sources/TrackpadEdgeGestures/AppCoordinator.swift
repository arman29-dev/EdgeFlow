import AppKit
import TEGCore

/// Owns every service and connects them:
/// trackpad frames -> gesture engine (gated by media state) -> volume / brightness -> haptics + HUD.
final class AppCoordinator {
    let settings = SettingsManager()
    let status = StatusModel()

    private let engine = GestureRecognitionEngine()
    private let provider = MultitouchProvider()
    private let media = MediaMonitor()
    private let volume = VolumeController()
    private let brightness = BrightnessController()
    private let haptics = HapticController()
    private let hud = HUDPanel()
    private let ownership = GestureOwnership()
    private lazy var scroll = ScrollConflictManager(ownership: ownership)
    private let gestureQueue = DispatchQueue(label: "teg.gesture", qos: .userInteractive)

    // Media gate state (touched from several queues).
    private let gateLock = NSLock()
    private var gate = PlaybackGate()
    private var playback: PlaybackState = .unknown("Not started")
    private var overrideUntil: Double?

    // Only touched on `gestureQueue`.
    private var volumeLimiter = OutputLimiter(minInterval: 1.0 / 60)
    private var brightnessLimiter = OutputLimiter(minInterval: 1.0 / 30)
    private var lastModifierScroll = -1000.0

    private var statusItem: StatusItemController?
    private var settingsWindow: SettingsWindowController?
    private var overrideTimer: Timer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var listeningToVolume = false
    private var liveEnabled = false
    private var terminating = false

    // MARK: - Startup

    func start() {
        // Register as a login item once, on the very first launch. Later opt-outs are respected.
        let initial = settings.value
        if !initial.launchAtLoginHandled && LoginItem.isAppBundle {
            if let error = LoginItem.set(initial.launchAtLogin) { status.logError("Login item: \(error)") }
            settings.update { $0.launchAtLoginHandled = true }
        }

        provider.onFrame = { [weak self] frame in
            self?.gestureQueue.async { self?.handle(frame) }
        }
        media.useAppSignals = { [weak self] in self?.settings.value.useAppSignals ?? true }
        media.onState = { [weak self] state in self?.mediaChanged(state) }
        scroll.settings = { [weak self] in self?.settings.value ?? .default }
        scroll.gateOpen = { [weak self] in self?.isGateOpen() ?? false }
        scroll.onModifierScroll = { [weak self] action, delta in
            self?.gestureQueue.async { self?.modifierScroll(action, delta) }
        }
        scroll.onTapDisabled = { [weak self] in
            self?.gestureQueue.async { self?.cancelGesture() }
            self?.status.logError("Event tap was disabled by the system and re-enabled")
        }
        volume.onDeviceChange = { [weak self] in self?.refreshStatus() }
        settings.onChange = { [weak self] old, new in self?.settingsChanged(old: old, new: new) }

        statusItem = StatusItemController(coordinator: self)
        settingsWindow = SettingsWindowController(coordinator: self)

        registerSystemObservers()
        startServices(attempt: 0)
        media.start()
        refreshStatus()
    }

    func shutdown() {
        terminating = true
        stopServices()
        media.stop()
        settings.flush()
    }

    // MARK: - Services

    private func startServices(attempt: Int) {
        guard !terminating else { return }

        volume.refresh()
        if !listeningToVolume {
            volume.startListening()
            listeningToVolume = true
        }
        if !brightness.isAvailable { brightness.probe(writeTest: attempt == 0) }

        let s = settings.value
        if s.gesturesEnabled && s.activationMethod == .edgeZones {
            let cap = provider.start()
            if case .unavailable(let why) = cap {
                status.logError("Trackpad: \(why)")
                if attempt < 6 {      // the device list can be empty for a moment right after login or wake
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                        self?.startServices(attempt: attempt + 1)
                    }
                }
            }
        }
        updateScrollTap()
        refreshStatus()
    }

    private func stopServices() {
        provider.stop()
        scroll.stop()
        gestureQueue.async { [weak self] in self?.cancelGesture() }
    }

    private func updateScrollTap() {
        let s = settings.value
        let needed = s.gesturesEnabled && ((s.activationMethod == .edgeZones && s.suppressScroll) || s.activationMethod == .modifier)
        if needed {
            scroll.start()
            if case .unavailable(let why) = scroll.capability { status.logError("Scroll tap: \(why)") }
        } else {
            scroll.stop()
        }
    }

    // MARK: - Gesture pipeline (gestureQueue)

    private func handle(_ frame: TouchFrame) {
        var s = settings.value
        if !volume.isAvailable { s.volumeEnabled = false }
        if !brightness.isAvailable { s.brightnessEnabled = false }

        if liveEnabled { publishLive(frame) }

        let event = engine.process(frame, gateOpen: isGateOpen(s), settings: s)
        switch event {
        case .none:
            break
        case .began(let action):
            began(action, s)
        case .delta(let action, let delta):
            let multiplier = action == .volume ? s.volumeSensitivity : s.brightnessSensitivity
            var out: Float?
            if action == .volume {
                out = volumeLimiter.push(delta * multiplier, now: frame.timestamp)
            } else {
                out = brightnessLimiter.push(delta * multiplier, now: frame.timestamp)
            }
            if let amount = out { perform(action, amount, s) }
        case .ended(let action):
            if action == .volume {
                if let rest = volumeLimiter.flush() { perform(.volume, rest, s) }
            } else {
                if let rest = brightnessLimiter.flush() { perform(.brightness, rest, s) }
            }
            ownership.set(false)
        }
    }

    private func began(_ action: GestureAction, _ s: AppSettings) {
        ownership.set(true)
        volumeLimiter.reset()
        brightnessLimiter.reset()
        haptics.configure(from: s)
        haptics.beginGesture()
        if action == .volume { volume.begin() } else { brightness.begin() }
    }

    private func perform(_ action: GestureAction, _ amount: Float, _ s: AppSettings) {
        let result = action == .volume ? volume.adjust(by: amount) : brightness.adjust(by: amount)
        guard let r = result else { return }
        haptics.evaluate(old: r.old, new: r.new, now: uptime())
        if s.showHUD {
            DispatchQueue.main.async { [weak self] in
                if action == .volume { self?.hud.show(volume: r.new) } else { self?.hud.show(brightness: r.new) }
            }
        }
    }

    private func modifierScroll(_ action: GestureAction, _ delta: Float) {
        let s = settings.value
        let now = uptime()
        if now - lastModifierScroll > 0.5 {
            haptics.configure(from: s)
            haptics.beginGesture()
            if action == .volume { volume.begin() } else { brightness.begin() }
        }
        lastModifierScroll = now
        let enabled = action == .volume ? (s.volumeEnabled && volume.isAvailable) : (s.brightnessEnabled && brightness.isAvailable)
        guard enabled else { return }
        let multiplier = action == .volume ? s.volumeSensitivity : s.brightnessSensitivity
        perform(action, delta * multiplier, s)
    }

    private func cancelGesture() {
        engine.cancel(at: uptime())
        ownership.set(false)
    }

    private func publishLive(_ frame: TouchFrame) {
        let text = frame.contacts.map {
            String(format: "id %d  state %d  x %.3f  y %.3f  size %.2f", $0.id, $0.state, $0.x, $0.y, $0.size)
        }.joined(separator: "\n") + "\nphase: \(engine.phase)"
        DispatchQueue.main.async { [weak self] in self?.status.liveText = text }
    }

    // MARK: - Media gate

    func isGateOpen(_ s: AppSettings? = nil) -> Bool {
        let settingsValue = s ?? settings.value
        gateLock.lock()
        defer { gateLock.unlock() }
        return gate.isOpen(mediaOnly: settingsValue.mediaOnly, overrideUntil: overrideUntil, now: uptime())
    }

    private func mediaChanged(_ state: PlaybackState) {
        gateLock.lock()
        playback = state
        gate.update(state: state, allowApproximate: settings.value.allowApproximate, now: uptime())
        gateLock.unlock()
        refreshStatus()
        // The gate closes one grace period after playback stops; refresh the display then.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.refreshStatus() }
    }

    /// `minutes == nil` keeps the override on until it is turned off.
    func enableOverride(minutes: Double?) {
        gateLock.lock()
        if let minutes { overrideUntil = uptime() + minutes * 60 } else { overrideUntil = .infinity }
        gateLock.unlock()
        scheduleOverrideExpiry(minutes: minutes)
        refreshStatus()
    }

    func cancelOverride() {
        gateLock.lock()
        overrideUntil = nil
        gateLock.unlock()
        overrideTimer?.invalidate()
        refreshStatus()
    }

    var overrideActive: Bool {
        gateLock.lock()
        defer { gateLock.unlock() }
        if let until = overrideUntil { return until > uptime() }
        return false
    }

    private func scheduleOverrideExpiry(minutes: Double?) {
        DispatchQueue.main.async { [weak self] in
            self?.overrideTimer?.invalidate()
            guard let minutes else { return }
            self?.overrideTimer = Timer.scheduledTimer(withTimeInterval: minutes * 60 + 0.2, repeats: false) { _ in
                self?.refreshStatus()
            }
        }
    }

    // MARK: - Settings reactions

    private func settingsChanged(old: AppSettings, new: AppSettings) {
        if old.launchAtLogin != new.launchAtLogin { applyLoginItem(new.launchAtLogin) }

        if old.allowApproximate != new.allowApproximate {
            gateLock.lock()
            gate.update(state: playback, allowApproximate: new.allowApproximate, now: uptime())
            gateLock.unlock()
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if old.gesturesEnabled != new.gesturesEnabled || old.activationMethod != new.activationMethod {
                if new.gesturesEnabled && new.activationMethod == .edgeZones {
                    self.provider.start()
                } else {
                    self.provider.stop()
                }
            }
            if old.suppressScroll != new.suppressScroll
                || old.activationMethod != new.activationMethod
                || old.gesturesEnabled != new.gesturesEnabled {
                self.updateScrollTap()
            }
            self.refreshStatus()
        }

        if !new.gesturesEnabled {
            gestureQueue.async { [weak self] in self?.cancelGesture() }
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        applyLoginItem(enabled)
        settings.update { $0.launchAtLogin = enabled }
        refreshStatus()
    }

    private func applyLoginItem(_ enabled: Bool) {
        if let error = LoginItem.set(enabled) { status.logError("Login item: \(error)") }
        refreshStatus()
    }

    func toggleGestures() {
        settings.update { $0.gesturesEnabled.toggle() }
    }

    func openSettings() {
        settingsWindow?.show()
    }

    /// Diagnostics: show live normalized contacts. In memory only, never written to disk. Resets on restart.
    func setLiveDiagnostics(_ on: Bool) {
        liveEnabled = on
        status.liveEnabled = on
        if !on { status.liveText = "" }
    }

    func recheckPermissions() {
        updateScrollTap()
        refreshStatus()
    }

    func quit() {
        shutdown()
        NSApp.terminate(nil)
    }

    // MARK: - Menu data

    func currentVolumePercent() -> Int? {
        volume.current().map { Int(($0 * 100).rounded()) }
    }

    func currentBrightnessPercent() -> Int? {
        brightness.current().map { Int(($0 * 100).rounded()) }
    }

    var playbackDescription: String {
        gateLock.lock()
        defer { gateLock.unlock() }
        return Self.describe(playback)
    }

    private static func describe(_ state: PlaybackState) -> String {
        switch state {
        case .playing(let source, let confidence):
            return "Playing: \(source) (\(confidence == .verified ? "verified" : "approximate"))"
        case .notPlaying: return "Not playing"
        case .unknown(let why): return "Unknown: \(why)"
        case .unavailable(let why): return "Unavailable: \(why)"
        }
    }

    // MARK: - Status

    func refreshStatus() {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.terminating else { return }
            let s = self.settings.value
            let gateOpen = self.isGateOpen(s)
            let trusted = Permissions.accessibilityGranted
            let needsAccessibility = s.gesturesEnabled
                && ((s.activationMethod == .edgeZones && s.suppressScroll) || s.activationMethod == .modifier)

            let trackpadUnusable = s.activationMethod == .edgeZones && !self.provider.capability.isUsable
            let appStatus: AppStatus
            if !s.gesturesEnabled { appStatus = .paused }
            else if trackpadUnusable { appStatus = .unsupported }
            else if needsAccessibility && !trusted { appStatus = .missingPermission }
            else if !self.volume.isAvailable && !self.brightness.isAvailable { appStatus = .unsupported }
            else if gateOpen { appStatus = self.overrideActive ? .manual : .active }
            else { appStatus = .waiting }

            self.statusItem?.setStatus(appStatus)

            self.status.summary = appStatus.title
            self.status.trackpad = s.activationMethod == .edgeZones
                ? "\(self.provider.capability.text) (\(self.provider.deviceCount) built-in device(s))"
                : "Not used (modifier mode)"
            self.status.scrollTap = self.scroll.capability.text
            self.status.playback = self.playbackDescription + (self.overrideActive ? " + manual override" : "")
            self.status.volume = "\(self.volume.capability.text) [\(self.volume.deviceName)]"
            self.status.brightness = self.brightness.capability.text
            self.status.accessibility = trusted ? "Granted" : "Not granted"
            self.status.loginItem = LoginItem.statusText
        }
    }

    // MARK: - System events

    private func registerSystemObservers() {
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        let app = NotificationCenter.default

        func observe(_ center: NotificationCenter, _ name: Notification.Name, _ block: @escaping () -> Void) {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in block() }
            observers.append((center, token))
        }

        let sleep: () -> Void = { [weak self] in self?.stopServices() }
        let wake: () -> Void = { [weak self] in
            // Give the HID stack a moment to come back before reopening devices.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self?.startServices(attempt: 1) }
        }

        observe(workspace, NSWorkspace.willSleepNotification, sleep)
        observe(workspace, NSWorkspace.didWakeNotification, wake)
        observe(workspace, NSWorkspace.screensDidSleepNotification, sleep)
        observe(workspace, NSWorkspace.screensDidWakeNotification, wake)
        observe(distributed, Notification.Name("com.apple.screenIsLocked"), sleep)
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked"), wake)
        observe(app, NSApplication.didChangeScreenParametersNotification) { [weak self] in
            self?.brightness.probe(writeTest: false)
            self?.refreshStatus()
        }
        observe(app, NSApplication.didBecomeActiveNotification) { [weak self] in
            self?.recheckPermissions()
        }
    }
}
