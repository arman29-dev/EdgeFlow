import XCTest
@testable import TEGCore

final class PolicyTests: XCTestCase {
    // MARK: Limiter

    func testLimiterCapsRateAndKeepsMotion() {
        var l = OutputLimiter(minInterval: 1.0 / 60)
        var outputs = 0
        var total: Float = 0
        // 240 Hz input for one second, each step +0.001
        for i in 0..<240 {
            if let o = l.push(0.001, now: Double(i) / 240.0) { outputs += 1; total += o }
        }
        if let rest = l.flush() { total += rest }
        XCTAssertLessThanOrEqual(outputs, 61)
        XCTAssertEqual(total, 0.24, accuracy: 0.0001)
    }

    func testBrightnessLimiterIsSlowerThanVolume() {
        var v = OutputLimiter(minInterval: 1.0 / 60)
        var b = OutputLimiter(minInterval: 1.0 / 30)
        var vc = 0, bc = 0
        for i in 0..<240 {
            let t = Double(i) / 240.0
            if v.push(0.001, now: t) != nil { vc += 1 }
            if b.push(0.001, now: t) != nil { bc += 1 }
        }
        XCTAssertGreaterThan(vc, bc)
        XCTAssertLessThanOrEqual(bc, 31)
    }

    // MARK: Haptics

    func testHapticPulsesOncePerBoundary() {
        var h = HapticPolicy(intervalPoints: 10, atLimits: false)
        XCTAssertTrue(h.shouldPulse(old: 0.08, new: 0.12, now: 1.0))
        XCTAssertFalse(h.shouldPulse(old: 0.12, new: 0.15, now: 2.0))
        XCTAssertTrue(h.shouldPulse(old: 0.15, new: 0.09, now: 3.0))   // reversing pulses too
    }

    func testHapticRespectsMinSpacing() {
        var h = HapticPolicy(intervalPoints: 10, atLimits: false, minSpacing: 0.08)
        XCTAssertTrue(h.shouldPulse(old: 0.09, new: 0.11, now: 1.0))
        XCTAssertFalse(h.shouldPulse(old: 0.11, new: 0.09, now: 1.02))  // jitter on the boundary
    }

    func testHapticDisabledNeverPulses() {
        var h = HapticPolicy(enabled: false, intervalPoints: 10, atLimits: true)
        XCTAssertFalse(h.shouldPulse(old: 0.1, new: 0.3, now: 1))
        XCTAssertFalse(h.shouldPulse(old: 0.9, new: 1.0, now: 2))
    }

    func testHapticLimitPulseOncePerGesture() {
        // Reaching 0 does not cross an interval boundary, so only the limit pulse can fire.
        var h = HapticPolicy(intervalPoints: 10, atLimits: true)
        h.beginGesture()
        XCTAssertTrue(h.shouldPulse(old: 0.05, new: 0.0, now: 1))
        XCTAssertFalse(h.shouldPulse(old: 0.0, new: 0.0, now: 2))
        XCTAssertFalse(h.shouldPulse(old: 0.04, new: 0.0, now: 3))   // already pulsed this gesture
        h.beginGesture()
        XCTAssertTrue(h.shouldPulse(old: 0.04, new: 0.0, now: 4))

        var off = HapticPolicy(intervalPoints: 10, atLimits: false)
        XCTAssertFalse(off.shouldPulse(old: 0.05, new: 0.0, now: 1))
    }

    // MARK: Gate

    func testUnknownAndUnavailableKeepGateClosed() {
        var g = PlaybackGate()
        g.update(state: .unknown("x"), allowApproximate: true, now: 0)
        XCTAssertFalse(g.isOpen(mediaOnly: true, overrideUntil: nil, now: 0))
        g.update(state: .unavailable("x"), allowApproximate: true, now: 1)
        XCTAssertFalse(g.isOpen(mediaOnly: true, overrideUntil: nil, now: 1))
        g.update(state: .notPlaying, allowApproximate: true, now: 2)
        XCTAssertFalse(g.isOpen(mediaOnly: true, overrideUntil: nil, now: 2))
    }

    func testVerifiedPlayingOpensImmediately() {
        var g = PlaybackGate()
        g.update(state: .playing(source: "Music", confidence: .verified), allowApproximate: false, now: 0)
        XCTAssertTrue(g.isOpen(mediaOnly: true, overrideUntil: nil, now: 0))
    }

    func testApproximateOnlyOpensWhenAllowed() {
        var g = PlaybackGate()
        let s = PlaybackState.playing(source: "audio", confidence: .approximate)
        g.update(state: s, allowApproximate: false, now: 0)
        XCTAssertFalse(g.isOpen(mediaOnly: true, overrideUntil: nil, now: 0))
        g.update(state: s, allowApproximate: true, now: 1)
        XCTAssertTrue(g.isOpen(mediaOnly: true, overrideUntil: nil, now: 1))
    }

    func testCloseGraceDebounce() {
        var g = PlaybackGate()
        let p = PlaybackState.playing(source: "Music", confidence: .verified)
        g.update(state: p, allowApproximate: true, now: 0)
        g.update(state: .notPlaying, allowApproximate: true, now: 10)
        XCTAssertTrue(g.isOpen(mediaOnly: true, overrideUntil: nil, now: 10.5))
        XCTAssertFalse(g.isOpen(mediaOnly: true, overrideUntil: nil, now: 11.01))
        // quick pause/resume never closes it
        g.update(state: p, allowApproximate: true, now: 10.4)
        XCTAssertTrue(g.isOpen(mediaOnly: true, overrideUntil: nil, now: 20))
    }

    func testManualOverrideAndMediaOnlyOff() {
        let g = PlaybackGate()
        XCTAssertFalse(g.isOpen(mediaOnly: true, overrideUntil: nil, now: 5))
        XCTAssertTrue(g.isOpen(mediaOnly: true, overrideUntil: 100, now: 5))
        XCTAssertFalse(g.isOpen(mediaOnly: true, overrideUntil: 100, now: 101))
        XCTAssertTrue(g.isOpen(mediaOnly: true, overrideUntil: .infinity, now: 1e9))
        XCTAssertTrue(g.isOpen(mediaOnly: false, overrideUntil: nil, now: 5))
    }

    // MARK: CoreAudio activity

    func testShortSoundsDoNotCount() {
        var ev = AudioActivityEvaluator()
        let p = [AudioProcessInfo(pid: 10, bundleID: "com.google.Chrome.helper", isRunningOutput: true)]
        let r0 = ev.evaluate(processes: p, inputDeviceRunning: false, now: 0)
        XCTAssertFalse(r0.playing)
        XCTAssertNotNil(r0.recheckIn)
        let r1 = ev.evaluate(processes: [], inputDeviceRunning: false, now: 1)   // ended after 1 s
        XCTAssertFalse(r1.playing)
    }

    func testSustainedOutputCounts() {
        var ev = AudioActivityEvaluator()
        let p = [AudioProcessInfo(pid: 10, bundleID: "org.videolan.vlc", isRunningOutput: true)]
        _ = ev.evaluate(processes: p, inputDeviceRunning: false, now: 0)
        let r = ev.evaluate(processes: p, inputDeviceRunning: false, now: 2.1)
        XCTAssertTrue(r.playing)
        XCTAssertEqual(r.source, "org.videolan.vlc")
    }

    func testConferencingAndInputDeviceExcluded() {
        var ev = AudioActivityEvaluator()
        let zoom = [AudioProcessInfo(pid: 5, bundleID: "us.zoom.xos", isRunningOutput: true)]
        _ = ev.evaluate(processes: zoom, inputDeviceRunning: false, now: 0)
        XCTAssertFalse(ev.evaluate(processes: zoom, inputDeviceRunning: false, now: 5).playing)

        var ev2 = AudioActivityEvaluator()
        let media = [AudioProcessInfo(pid: 6, bundleID: "com.apple.Safari", isRunningOutput: true)]
        _ = ev2.evaluate(processes: media, inputDeviceRunning: false, now: 0)
        XCTAssertFalse(ev2.evaluate(processes: media, inputDeviceRunning: true, now: 5).playing)
    }

    func testIgnoreClosureSkipsAppsWithDirectSignal() {
        var ev = AudioActivityEvaluator()
        let p = [AudioProcessInfo(pid: 7, bundleID: "com.spotify.client", isRunningOutput: true)]
        _ = ev.evaluate(processes: p, inputDeviceRunning: false, now: 0, ignore: { $0.hasPrefix("com.spotify") })
        let r = ev.evaluate(processes: p, inputDeviceRunning: false, now: 5, ignore: { $0.hasPrefix("com.spotify") })
        XCTAssertFalse(r.playing)
    }
}
