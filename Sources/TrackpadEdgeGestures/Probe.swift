import AppKit
import ApplicationServices
import TEGCore

/// `EdgeFlow --probe`: prints what works on THIS Mac, so nothing has to be taken on faith.
/// Run it from Terminal (macOS attributes permissions to Terminal in that case) while touching the trackpad.
func runProbes() {
    print("== Trackpad Edge Gestures: hardware probe ==")
    print("macOS:    \(ProcessInfo.processInfo.operatingSystemVersionString)")
    #if arch(arm64)
    print("CPU:      arm64 (Apple Silicon)")
    #else
    print("CPU:      x86_64 (not the intended target)")
    #endif
    print("Accessibility trusted: \(AXIsProcessTrusted())")
    print()

    // 1. Trackpad
    print("-- 1. Trackpad (private MultitouchSupport) --")
    let provider = MultitouchProvider()
    var frames = 0
    var shown = 0
    provider.onFrame = { frame in
        if frame.contacts.isEmpty { return }
        frames += 1
        if shown < 25 {
            shown += 1
            for c in frame.contacts {
                print(String(format: "  t=%.3f id=%d state=%d x=%.3f y=%.3f size=%.2f", frame.timestamp, c.id, c.state, c.x, c.y, c.size))
            }
        }
    }
    let trackpad = provider.start()
    print("Result: \(trackpad.text); built-in devices: \(provider.deviceCount)")
    if trackpad.isUsable {
        print("Touch the trackpad now (slide two fingers UP along the right edge), 8 seconds…")
        Thread.sleep(forTimeInterval: 8)
        provider.stop()
        print("Frames with contacts received: \(frames)")
        if frames == 0 {
            print("  No frames. Either nothing touched the pad, or macOS needs Input Monitoring for this process:")
            print("  System Settings > Privacy & Security > Input Monitoring > add Terminal (or the app), then rerun.")
        } else {
            print("  CHECK: moving fingers UP should make y INCREASE. If y decreased, tell the app (Settings > Gestures > Invert direction)")
            print("  CHECK: right-edge touches should have x close to 1.0, left-edge close to 0.0.")
            print("  CHECK: a finger on the glass should show state 3 or 4.")
        }
    }
    print()

    // 2. Brightness
    print("-- 2. Built-in display brightness (private DisplayServices) --")
    let brightness = BrightnessController()
    let b = brightness.probe(writeTest: true)
    print("Result: \(b.text)")
    if let v = brightness.current() { print("Current brightness: \(Int((v * 100).rounded()))% (probe restored the original value)") }
    print()

    // 3. Volume
    print("-- 3. Volume (CoreAudio) --")
    let volume = VolumeController()
    volume.refresh()
    print("Default output: \(volume.deviceName)")
    print("Result: \(volume.capability.text)")
    if let v = volume.current() { print("Current volume: \(Int((v * 100).rounded()))%") }
    print()

    // 4. Haptics
    print("-- 4. Haptics --")
    print("Sending one .levelChange pulse; rest a finger on the trackpad to feel it.")
    NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    Thread.sleep(forTimeInterval: 1)
    print("Request issued (cannot be verified from software).")
    print()

    // 5. Media
    print("-- 5. Media signals --")
    if let processes = MediaMonitor.readProcesses() {
        let active = processes.filter { $0.isRunningOutput }
        print("Audio processes: \(processes.count), producing output now: \(active.count)")
        for p in active { print("  pid \(p.pid)  \(p.bundleID.isEmpty ? "(no bundle id)" : p.bundleID)") }
    } else {
        print("CoreAudio process list: unavailable")
    }
    print("Input device in use by someone (call/dictation): \(MediaMonitor.defaultInputRunning())")
    print("Tip: start a YouTube video, rerun, and confirm the browser's helper process appears above.")
    print()
    print("== done ==")
}
