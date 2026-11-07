import Foundation

public enum GestureAction: Equatable {
    case volume
    case brightness
}

/// One finger on the trackpad. x and y are normalized 0...1.
public struct TouchContact: Equatable {
    public var id: Int32
    public var x: Float
    public var y: Float
    public var state: Int32
    public var size: Float

    public init(id: Int32, x: Float, y: Float, state: Int32 = 4, size: Float = 0) {
        self.id = id
        self.x = x
        self.y = y
        self.state = state
        self.size = size
    }

    /// MultitouchSupport states: 1 starting, 2 hovering, 3 making, 4 touching, 5 breaking, 6 lingering, 7 leaving.
    /// Only "making" and "touching" count as a finger on the glass.
    public var isDown: Bool { state == 3 || state == 4 }
}

public struct TouchFrame {
    public var timestamp: Double
    public var contacts: [TouchContact]

    public init(timestamp: Double, contacts: [TouchContact]) {
        self.timestamp = timestamp
        self.contacts = contacts
    }
}

public enum GestureEvent: Equatable {
    case none
    case began(GestureAction)
    /// Signed change as a fraction of the control's full range (already scaled by sensitivity and capped).
    case delta(GestureAction, Float)
    case ended(GestureAction)
}

/// Pure state machine: idle -> candidate -> active -> (ended). Feed it frames, get events.
/// Not thread-safe; call from one queue.
public final class GestureRecognitionEngine {
    public enum Phase: Equatable {
        case idle
        case candidate(GestureAction)
        case active(GestureAction)
    }

    public private(set) var phase: Phase = .idle

    /// Pad width divided by pad height. Used to compare horizontal and vertical travel in the same units.
    public var padAspect: Float = 1.6
    /// MultitouchSupport normalized y grows upward (UNVERIFIED on the target Mac: confirm with `--probe`).
    public var yUpIsPositive = true
    public var dominance: Float = 2.0
    public var pairWindow: Double = 0.15
    public var cooldown: Double = 0.15
    public var stationaryTimeout: Double = 0.4
    public var zoneHysteresis: Float = 0.03
    public var deadzone: Float = 0.002
    public var maxStep: Float = 0.03

    private struct Seen { var t: Double; var x: Float; var y: Float }

    private var seen: [Int32: Seen] = [:]
    private var blocked = false
    private var cooldownUntil: Double = -Double.infinity
    private var idA: Int32 = 0
    private var idB: Int32 = 0
    private var startTime: Double = 0
    private var startMeanX: Float = 0
    private var startMeanY: Float = 0
    private var smoothedY: Float = 0
    private var accum: Float = 0

    public init() {}

    public var isActive: Bool {
        if case .active = phase { return true }
        return false
    }

    /// Cancels whatever is in progress (sleep, lock, disable, device loss).
    @discardableResult
    public func cancel(at time: Double = 0) -> GestureEvent {
        seen.removeAll(keepingCapacity: true)
        return finish(time)
    }

    public func process(_ frame: TouchFrame, gateOpen: Bool, settings s: AppSettings) -> GestureEvent {
        let t = frame.timestamp

        if !s.gesturesEnabled {
            return finish(t)
        }

        var downs: [TouchContact] = []
        downs.reserveCapacity(frame.contacts.count)
        for c in frame.contacts where c.isDown { downs.append(c) }

        if downs.isEmpty {
            seen.removeAll(keepingCapacity: true)
            let ev = finish(t)
            blocked = false
            return ev
        }

        // Remember where and when each current finger first touched down.
        for c in downs where seen[c.id] == nil {
            seen[c.id] = Seen(t: t, x: c.x, y: c.y)
        }
        if seen.count > downs.count {
            let live = Set(downs.map { $0.id })
            for k in Array(seen.keys) where !live.contains(k) { seen.removeValue(forKey: k) }
        }

        switch phase {
        case .idle:
            return evaluateStart(downs: downs, t: t, gateOpen: gateOpen, s: s)

        case .candidate(let action):
            guard downs.count == 2,
                  let a = downs.first(where: { $0.id == idA }),
                  let b = downs.first(where: { $0.id == idB }) else { return finish(t) }
            guard gateOpen else { return finish(t) }
            if !inZone(a.x, action, s, slack: zoneHysteresis) || !inZone(b.x, action, s, slack: zoneHysteresis) {
                return finish(t)
            }
            let meanX = (a.x + b.x) / 2
            let meanY = (a.y + b.y) / 2
            let dy = (meanY - startMeanY) * direction(s)
            let dxPhys = (meanX - startMeanX) * padAspect
            if abs(dy) >= s.minMovement {
                if abs(dy) >= dominance * abs(dxPhys) {
                    phase = .active(action)
                    smoothedY = meanY
                    accum = 0
                    return .began(action)
                }
                return finish(t)
            }
            if abs(dxPhys) >= s.minMovement { return finish(t) }
            if t - startTime > stationaryTimeout && abs(dy) < s.minMovement * 0.5 { return finish(t) }
            return .none

        case .active(let action):
            guard downs.count == 2,
                  let a = downs.first(where: { $0.id == idA }),
                  let b = downs.first(where: { $0.id == idB }) else { return finish(t) }
            let meanY = (a.y + b.y) / 2
            let previous = smoothedY
            smoothedY += s.smoothing.alpha * (meanY - smoothedY)
            accum += (smoothedY - previous) * direction(s)
            if abs(accum) < deadzone { return .none }
            var out = accum * s.sensitivity
            accum = 0
            out = min(max(out, -maxStep), maxStep)
            return .delta(action, out)
        }
    }

    // MARK: - Private

    private func evaluateStart(downs: [TouchContact], t: Double, gateOpen: Bool, s: AppSettings) -> GestureEvent {
        if blocked || t < cooldownUntil { return .none }
        if downs.count > 2 { blocked = true; return .none }
        guard downs.count == 2 else { return .none }

        let a = downs[0], b = downs[1]
        guard gateOpen,
              s.activationMethod == .edgeZones,
              let sa = seen[a.id], let sb = seen[b.id],
              abs(sa.t - sb.t) <= pairWindow,
              let za = zone(sa.x, s), let zb = zone(sb.x, s), za == zb,
              (za == .volume ? s.volumeEnabled : s.brightnessEnabled) else {
            blocked = true
            return .none
        }

        phase = .candidate(za)
        idA = a.id
        idB = b.id
        startTime = max(sa.t, sb.t)
        startMeanX = (sa.x + sb.x) / 2
        startMeanY = (sa.y + sb.y) / 2
        return .none
    }

    @discardableResult
    private func finish(_ t: Double) -> GestureEvent {
        let old = phase
        guard old != .idle else { return .none }
        phase = .idle
        blocked = true            // ignore the rest of this touch sequence until every finger lifts
        cooldownUntil = t + cooldown
        accum = 0
        if case .active(let action) = old { return .ended(action) }
        return .none
    }

    private func direction(_ s: AppSettings) -> Float {
        var d: Float = yUpIsPositive ? 1 : -1
        if s.invertDirection { d = -d }
        return d
    }

    private func zone(_ x: Float, _ s: AppSettings) -> GestureAction? {
        if x <= s.leftZoneWidth { return .brightness }
        if x >= 1 - s.rightZoneWidth { return .volume }
        return nil
    }

    private func inZone(_ x: Float, _ action: GestureAction, _ s: AppSettings, slack: Float) -> Bool {
        switch action {
        case .brightness: return x <= s.leftZoneWidth + slack
        case .volume: return x >= 1 - s.rightZoneWidth - slack
        }
    }
}
