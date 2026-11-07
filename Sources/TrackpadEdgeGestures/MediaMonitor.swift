import AppKit
import CoreAudio
import TEGCore

/// Decides whether media is playing, from the best signal available (see docs/RESEARCH.md):
///  1. Music / Spotify play-state notifications (verified, event-driven, no extra permission).
///  2. CoreAudio per-process output activity (approximate: cannot tell paused sessions or muted video from playback).
/// Unknown or unavailable never counts as playing. The manual override lives in AppCoordinator.
final class MediaMonitor {
    private struct AppSource {
        let name: String
        let bundle: String
        let notification: String
    }

    private let appSources = [
        AppSource(name: "Music", bundle: "com.apple.Music", notification: "com.apple.Music.playerInfo"),
        AppSource(name: "Spotify", bundle: "com.spotify.client", notification: "com.spotify.client.PlaybackStateChanged"),
    ]

    var onState: ((PlaybackState) -> Void)?
    var useAppSignals: () -> Bool = { true }

    private(set) var capability: Capability = .unavailable("Not started")

    private let queue = DispatchQueue(label: "teg.media")
    private var evaluator = AudioActivityEvaluator()
    private var appPlaying: [String: Bool] = [:]
    private var observedProcesses: [AudioObjectID] = []
    private var processListener: AudioObjectPropertyListenerBlock?
    private var runningListener: AudioObjectPropertyListenerBlock?
    private var tokens: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    private var lastState: PlaybackState?
    private var started = false

    // MARK: Lifecycle

    func start() {
        queue.async { [self] in
            guard !started else { return }
            started = true
            installAudioListeners()
        }
        installNotificationObservers()
        queue.async { [self] in evaluate() }
    }

    func stop() {
        queue.async { [self] in
            guard started else { return }
            started = false
            removeAudioListeners()
        }
        for t in tokens { t.center.removeObserver(t.token) }
        tokens.removeAll()
    }

    // MARK: Notifications (Music / Spotify)

    private func installNotificationObservers() {
        guard tokens.isEmpty else { return }
        let distributed = DistributedNotificationCenter.default()
        for source in appSources {
            let token = distributed.addObserver(forName: Notification.Name(source.notification), object: nil, queue: nil) { [weak self] note in
                let state = (note.userInfo?["Player State"] as? String)?.lowercased()
                self?.queue.async {
                    self?.appPlaying[source.bundle] = (state == "playing")
                    self?.evaluate()
                }
            }
            tokens.append((distributed, token))
        }

        let workspace = NSWorkspace.shared.notificationCenter
        let quit = workspace.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: nil) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bundle = app.bundleIdentifier else { return }
            self?.queue.async {
                guard let self, self.appSources.contains(where: { $0.bundle == bundle }) else { return }
                self.appPlaying[bundle] = false
                self.evaluate()
            }
        }
        tokens.append((workspace, quit))
    }

    // MARK: CoreAudio listeners

    private func installAudioListeners() {
        let processList: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.observeProcesses()
            self?.evaluate()
        }
        processListener = processList
        runningListener = { [weak self] _, _ in self?.evaluate() }

        var a = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        _ = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, queue, processList)
        observeProcesses()
    }

    private func removeAudioListeners() {
        if let l = processListener {
            var a = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyProcessObjectList,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            _ = AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, queue, l)
        }
        unobserveProcesses()
        processListener = nil
        runningListener = nil
    }

    private func unobserveProcesses() {
        guard let l = runningListener else { observedProcesses.removeAll(); return }
        for id in observedProcesses {
            var a = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyIsRunningOutput,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            _ = AudioObjectRemovePropertyListenerBlock(id, &a, queue, l)
        }
        observedProcesses.removeAll()
    }

    private func observeProcesses() {
        unobserveProcesses()
        guard let l = runningListener, let ids = Self.processObjectIDs() else { return }
        for id in ids {
            var a = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyIsRunningOutput,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            if AudioObjectAddPropertyListenerBlock(id, &a, queue, l) == noErr {
                observedProcesses.append(id)
            }
        }
    }

    // MARK: Evaluation (always on `queue`)

    private func evaluate() {
        let signals = useAppSignals()
        let now = uptime()
        let state: PlaybackState

        if signals, let playing = appSources.first(where: { appPlaying[$0.bundle] == true }) {
            state = .playing(source: playing.name, confidence: .verified)
            capability = .available
        } else if let processes = Self.readProcesses() {
            capability = .available
            let ignore: (String) -> Bool = { [weak self] bundle in
                guard signals, let self else { return false }
                // Apps that report their own state are judged by that signal, not by raw audio activity.
                return self.appSources.contains { bundle.hasPrefix($0.bundle) && self.appPlaying[$0.bundle] != nil }
            }
            let result = evaluator.evaluate(
                processes: processes,
                inputDeviceRunning: Self.defaultInputRunning(),
                now: now,
                ignore: ignore)
            if result.playing {
                state = .playing(source: "Audio output (\(result.source ?? "app"))", confidence: .approximate)
            } else {
                state = .notPlaying
                if let wait = result.recheckIn {
                    queue.asyncAfter(deadline: .now() + wait + 0.05) { [weak self] in self?.evaluate() }
                }
            }
        } else {
            capability = .unavailable("CoreAudio process list could not be read")
            state = .unavailable("CoreAudio process list could not be read")
        }

        if state != lastState {
            lastState = state
            onState?(state)
        }
    }

    // MARK: CoreAudio reads

    static func processObjectIDs() -> [AudioObjectID]? {
        var a = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size) == noErr else { return nil }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &ids) == noErr else { return nil }
        return ids
    }

    static func readProcesses() -> [AudioProcessInfo]? {
        guard let ids = processObjectIDs() else { return nil }
        var result: [AudioProcessInfo] = []
        for id in ids {
            var pidAddr = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyPID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            var pid: Int32 = 0
            var pidSize = UInt32(MemoryLayout<Int32>.size)
            guard AudioObjectGetPropertyData(id, &pidAddr, 0, nil, &pidSize, &pid) == noErr else { continue }

            var runAddr = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyIsRunningOutput,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            var running: UInt32 = 0
            var runSize = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(id, &runAddr, 0, nil, &runSize, &running) == noErr else { continue }

            var bundleAddr = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyBundleID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            var bundle: Unmanaged<CFString>?
            var bundleSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            var bundleID = ""
            if AudioObjectGetPropertyData(id, &bundleAddr, 0, nil, &bundleSize, &bundle) == noErr, let b = bundle {
                bundleID = b.takeRetainedValue() as String
            }

            result.append(AudioProcessInfo(pid: pid, bundleID: bundleID, isRunningOutput: running != 0))
        }
        return result
    }

    /// True when something is capturing the default input device (a call, dictation, a recorder).
    /// Only the "is running somewhere" flag is read; no audio is ever captured.
    static func defaultInputRunning() -> Bool {
        var a = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &device) == noErr,
              device != AudioObjectID(kAudioObjectUnknown) else { return false }

        var r = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var running: UInt32 = 0
        var rSize = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &r, 0, nil, &rSize, &running) == noErr else { return false }
        return running != 0
    }
}
