import XCTest
@testable import TEGCore

final class GestureEngineTests: XCTestCase {
    private let dt = 1.0 / 60.0

    /// Builds a two-finger sequence. Each step moves both fingers by (dx, dy).
    private func run(
        _ engine: GestureRecognitionEngine,
        settings: AppSettings = .default,
        gate: @escaping (Int) -> Bool = { _ in true },
        startX: (Float, Float),
        startY: Float = 0.3,
        steps: Int,
        dy: Float,
        dx: Float = 0,
        t0: Double = 1.0
    ) -> [GestureEvent] {
        var events: [GestureEvent] = []
        var y = startY
        var x = startX
        for i in 0..<steps {
            let contacts = [
                TouchContact(id: 1, x: x.0, y: y),
                TouchContact(id: 2, x: x.1, y: y + 0.02),
            ]
            events.append(engine.process(TouchFrame(timestamp: t0 + Double(i) * dt, contacts: contacts),
                                         gateOpen: gate(i), settings: settings))
            y += dy
            x.0 += dx
            x.1 += dx
        }
        return events
    }

    private func lift(_ engine: GestureRecognitionEngine, at t: Double, settings: AppSettings = .default) -> GestureEvent {
        engine.process(TouchFrame(timestamp: t, contacts: []), gateOpen: true, settings: settings)
    }

    private func deltas(_ events: [GestureEvent]) -> [Float] {
        events.compactMap { (event: GestureEvent) -> Float? in
            if case .delta(_, let d) = event { return d }
            return nil
        }
    }

    func testRightEdgeUpActivatesVolumeWithPositiveDelta() {
        let e = GestureRecognitionEngine()
        let ev = run(e, startX: (0.93, 0.96), steps: 30, dy: 0.01)
        XCTAssertTrue(ev.contains(.began(.volume)))
        let d = deltas(ev)
        XCTAssertFalse(d.isEmpty)
        XCTAssertTrue(d.allSatisfy { $0 > 0 })
        XCTAssertEqual(e.phase, .active(.volume))
    }

    func testLeftEdgeDownActivatesBrightnessWithNegativeDelta() {
        let e = GestureRecognitionEngine()
        let ev = run(e, startX: (0.03, 0.06), startY: 0.8, steps: 30, dy: -0.01)
        XCTAssertTrue(ev.contains(.began(.brightness)))
        let d = deltas(ev)
        XCTAssertFalse(d.isEmpty)
        XCTAssertTrue(d.allSatisfy { $0 < 0 })
    }

    func testCenterNeverActivates() {
        let e = GestureRecognitionEngine()
        let ev = run(e, startX: (0.45, 0.55), steps: 40, dy: 0.01)
        XCTAssertTrue(ev.allSatisfy { $0 == .none })
        XCTAssertEqual(e.phase, .idle)
    }

    func testOneFingerOutsideZoneNeverActivates() {
        let e = GestureRecognitionEngine()
        let ev = run(e, startX: (0.95, 0.5), steps: 40, dy: 0.01)
        XCTAssertTrue(ev.allSatisfy { $0 == .none })
    }

    func testDifferentZonesNeverActivate() {
        let e = GestureRecognitionEngine()
        let ev = run(e, startX: (0.05, 0.95), steps: 40, dy: 0.01)
        XCTAssertTrue(ev.allSatisfy { $0 == .none })
    }

    func testBelowThresholdStaysCandidateWithoutOutput() {
        let e = GestureRecognitionEngine()
        let ev = run(e, startX: (0.93, 0.96), steps: 6, dy: 0.002)
        XCTAssertTrue(ev.allSatisfy { $0 == .none })
        XCTAssertEqual(e.phase, .candidate(.volume))
    }

    func testHorizontalDominanceAborts() {
        let e = GestureRecognitionEngine()
        // Moves sideways but stays inside zone + hysteresis long enough to exceed minMovement.
        let ev = run(e, startX: (0.86, 0.88), steps: 10, dy: 0.002, dx: 0.004)
        XCTAssertFalse(ev.contains(.began(.volume)))
        XCTAssertEqual(e.phase, .idle)
    }

    func testThirdFingerEndsActiveGesture() {
        let e = GestureRecognitionEngine()
        _ = run(e, startX: (0.93, 0.96), steps: 20, dy: 0.01)
        XCTAssertTrue(e.isActive)
        let three = [
            TouchContact(id: 1, x: 0.93, y: 0.6),
            TouchContact(id: 2, x: 0.96, y: 0.62),
            TouchContact(id: 3, x: 0.5, y: 0.5),
        ]
        let ev = e.process(TouchFrame(timestamp: 5, contacts: three), gateOpen: true, settings: .default)
        XCTAssertEqual(ev, .ended(.volume))
        XCTAssertEqual(e.phase, .idle)
    }

    func testLiftEndsAndCooldownBlocksImmediateRestart() {
        let e = GestureRecognitionEngine()
        _ = run(e, startX: (0.93, 0.96), steps: 20, dy: 0.01, t0: 1.0)
        XCTAssertEqual(lift(e, at: 2.0), .ended(.volume))

        // New touch within the 150 ms cooldown is ignored.
        let ev = run(e, startX: (0.93, 0.96), steps: 6, dy: 0.01, t0: 2.05)
        XCTAssertTrue(ev.allSatisfy { $0 == .none })
    }

    func testRestartAfterCooldownWorks() {
        let e = GestureRecognitionEngine()
        _ = run(e, startX: (0.93, 0.96), steps: 20, dy: 0.01, t0: 1.0)
        _ = lift(e, at: 2.0)
        _ = lift(e, at: 2.5)
        let ev = run(e, startX: (0.93, 0.96), steps: 20, dy: 0.01, t0: 3.0)
        XCTAssertTrue(ev.contains(.began(.volume)))
    }

    func testCrossingZoneBoundaryDoesNotEndOrSwitchAction() {
        let e = GestureRecognitionEngine()
        // Drifts left across the whole pad while moving up; once active it stays volume.
        let ev = run(e, startX: (0.93, 0.96), steps: 60, dy: 0.01, dx: -0.002)
        XCTAssertTrue(ev.contains(.began(.volume)))
        XCTAssertFalse(ev.contains(.began(.brightness)))
        XCTAssertFalse(ev.contains { if case .ended = $0 { return true } else { return false } })
    }

    func testGateClosedPreventsStart() {
        let e = GestureRecognitionEngine()
        let ev = run(e, gate: { _ in false }, startX: (0.93, 0.96), steps: 30, dy: 0.01)
        XCTAssertTrue(ev.allSatisfy { $0 == .none })
    }

    func testGateClosingMidGestureLetsItEndNaturally() {
        let e = GestureRecognitionEngine()
        let ev = run(e, gate: { $0 < 10 }, startX: (0.93, 0.96), steps: 40, dy: 0.01)
        XCTAssertTrue(ev.contains(.began(.volume)))
        XCTAssertTrue(e.isActive)
        XCTAssertFalse(ev.contains { if case .ended = $0 { return true } else { return false } })
    }

    func testJitterProducesNoOutput() {
        let e = GestureRecognitionEngine()
        _ = run(e, startX: (0.93, 0.96), steps: 12, dy: 0.01)
        XCTAssertTrue(e.isActive)
        let rest: Float = 0.3 + 0.01 * 11          // where contact 1 stopped
        // Let the smoothing filter settle with the fingers perfectly still.
        for i in 0..<40 {
            _ = e.process(TouchFrame(timestamp: 5 + Double(i) * dt, contacts: [
                TouchContact(id: 1, x: 0.93, y: rest), TouchContact(id: 2, x: 0.96, y: rest + 0.02),
            ]), gateOpen: true, settings: .default)
        }
        var out: [GestureEvent] = []
        for i in 0..<30 {
            let y = rest + ((i % 2 == 0) ? 0.0004 : -0.0004)
            out.append(e.process(TouchFrame(timestamp: 8 + Double(i) * dt, contacts: [
                TouchContact(id: 1, x: 0.93, y: y), TouchContact(id: 2, x: 0.96, y: y + 0.02),
            ]), gateOpen: true, settings: .default))
        }
        XCTAssertTrue(deltas(out).isEmpty)
    }

    func testLargeJumpIsCapped() {
        let e = GestureRecognitionEngine()
        _ = run(e, startX: (0.93, 0.96), steps: 8, dy: 0.01)
        XCTAssertTrue(e.isActive)
        var s = AppSettings.default
        s.smoothing = .low
        let ev = e.process(TouchFrame(timestamp: 5, contacts: [
            TouchContact(id: 1, x: 0.93, y: 0.95), TouchContact(id: 2, x: 0.96, y: 0.97),
        ]), gateOpen: true, settings: s)
        guard case .delta(_, let d) = ev else { return XCTFail("expected delta, got \(ev)") }
        XCTAssertLessThanOrEqual(abs(d), 0.03 + 0.0001)
    }

    func testInvertFlipsSign() {
        var s = AppSettings.default
        s.invertDirection = true
        let e = GestureRecognitionEngine()
        let ev = run(e, settings: s, startX: (0.93, 0.96), steps: 30, dy: 0.01)
        XCTAssertTrue(deltas(ev).allSatisfy { $0 < 0 })
    }

    func testSensitivityScalesLinearly() {
        func total(_ sens: Float) -> Float {
            var s = AppSettings.default
            s.sensitivity = sens
            let e = GestureRecognitionEngine()
            return deltas(run(e, settings: s, startX: (0.93, 0.96), steps: 30, dy: 0.004)).reduce(0, +)
        }
        let a = total(1.0), b = total(2.0)
        XCTAssertGreaterThan(a, 0)
        XCTAssertEqual(b / a, 2.0, accuracy: 0.15)
    }

    func testZoneWidthChangeAppliesToNextGestureOnly() {
        let e = GestureRecognitionEngine()
        _ = run(e, startX: (0.93, 0.96), steps: 20, dy: 0.01)
        XCTAssertTrue(e.isActive)
        var narrow = AppSettings.default
        narrow.rightZoneWidth = 0.08
        let ev = e.process(TouchFrame(timestamp: 6, contacts: [
            TouchContact(id: 1, x: 0.90, y: 0.9), TouchContact(id: 2, x: 0.92, y: 0.92),
        ]), gateOpen: true, settings: narrow)
        if case .ended = ev { XCTFail("active gesture must survive a settings change") }
    }

    func testDisabledGestureEndsActive() {
        let e = GestureRecognitionEngine()
        _ = run(e, startX: (0.93, 0.96), steps: 20, dy: 0.01)
        var s = AppSettings.default
        s.gesturesEnabled = false
        let ev = e.process(TouchFrame(timestamp: 6, contacts: [
            TouchContact(id: 1, x: 0.93, y: 0.9), TouchContact(id: 2, x: 0.96, y: 0.92),
        ]), gateOpen: true, settings: s)
        XCTAssertEqual(ev, .ended(.volume))
    }

    func testHoveringContactsAreIgnored() {
        let e = GestureRecognitionEngine()
        var out: [GestureEvent] = []
        for i in 0..<30 {
            let y = 0.3 + Float(i) * 0.01
            out.append(e.process(TouchFrame(timestamp: 1 + Double(i) * dt, contacts: [
                TouchContact(id: 1, x: 0.93, y: y, state: 2), TouchContact(id: 2, x: 0.96, y: y, state: 2),
            ]), gateOpen: true, settings: .default))
        }
        XCTAssertTrue(out.allSatisfy { $0 == .none })
    }

    func testFingersLandingFarApartInTimeAreRejected() {
        let e = GestureRecognitionEngine()
        var out: [GestureEvent] = []
        // First finger down, second arrives 400 ms later.
        for i in 0..<40 {
            let t = 1 + Double(i) * dt
            var c = [TouchContact(id: 1, x: 0.93, y: 0.3 + Float(i) * 0.01)]
            if t > 1.4 { c.append(TouchContact(id: 2, x: 0.96, y: 0.3 + Float(i) * 0.01)) }
            out.append(e.process(TouchFrame(timestamp: t, contacts: c), gateOpen: true, settings: .default))
        }
        XCTAssertTrue(out.allSatisfy { $0 == .none })
    }
}
