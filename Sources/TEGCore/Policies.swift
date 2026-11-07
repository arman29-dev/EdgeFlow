import Foundation

// MARK: - Output rate limiting

/// Accumulates motion and releases it at most once per `minInterval`, so no movement is lost.
public struct OutputLimiter {
    public let minInterval: Double
    private var last = -Double.infinity
    private var pending: Float = 0

    public init(minInterval: Double) { self.minInterval = minInterval }

    public mutating func push(_ delta: Float, now: Double) -> Float? {
        pending += delta
        guard now - last >= minInterval else { return nil }
        last = now
        let out = pending
        pending = 0
        return out
    }

    /// Returns whatever is still waiting (call when a gesture ends).
    public mutating func flush() -> Float? {
        defer { pending = 0 }
        return pending == 0 ? nil : pending
    }

    public mutating func reset() {
        pending = 0
        last = -Double.infinity
    }
}

// MARK: - Haptics

/// Decides when a haptic pulse is due. The value itself stays continuous; this only marks boundaries.
public struct HapticPolicy {
    public var enabled: Bool
    public var intervalPoints: Int
    public var atLimits: Bool
    public var minSpacing: Double

    private var lastPulse = -Double.infinity
    private var limitPulsedThisGesture = false

    public init(enabled: Bool = true, intervalPoints: Int = 10, atLimits: Bool = true, minSpacing: Double = 0.08) {
        self.enabled = enabled
        self.intervalPoints = max(1, intervalPoints)
        self.atLimits = atLimits
        self.minSpacing = minSpacing
    }

    public mutating func beginGesture() {
        limitPulsedThisGesture = false
    }

    /// `old` and `new` are positions in 0...1 across the control's range.
    public mutating func shouldPulse(old: Float, new: Float, now: Double) -> Bool {
        guard enabled, old != new else { return false }
        guard now - lastPulse >= minSpacing else { return false }

        let step = Float(intervalPoints)
        let crossed = Int(floor(old * 100 / step)) != Int(floor(new * 100 / step))

        var limit = false
        if atLimits && !limitPulsedThisGesture {
            let hitTop = new >= 1 && old < 1
            let hitBottom = new <= 0 && old > 0
            limit = hitTop || hitBottom
        }

        guard crossed || limit else { return false }
        if limit { limitPulsedThisGesture = true }
        lastPulse = now
        return true
    }
}

// MARK: - Media gate

public enum PlaybackConfidence: Equatable {
    case verified      // an app told us directly (Music, Spotify, Now Playing)
    case approximate   // some process has been producing audio output; cannot tell paused from playing
}

public enum PlaybackState: Equatable {
    case playing(source: String, confidence: PlaybackConfidence)
    case notPlaying
    case unknown(String)
    case unavailable(String)

    public var isPlaying: Bool {
        if case .playing = self { return true }
        return false
    }
}

/// Opens when playback is detected, closes `closeGrace` seconds after it stops.
/// Unknown and unavailable states never open it.
public struct PlaybackGate {
    public var closeGrace: Double = 1.0

    private var eligibleNow = false
    private var lastEligibleAt: Double?

    public init() {}

    public static func isEligible(_ state: PlaybackState, allowApproximate: Bool) -> Bool {
        switch state {
        case .playing(_, let confidence):
            return confidence == .verified || allowApproximate
        case .notPlaying, .unknown, .unavailable:
            return false
        }
    }

    public mutating func update(state: PlaybackState, allowApproximate: Bool, now: Double) {
        if PlaybackGate.isEligible(state, allowApproximate: allowApproximate) {
            eligibleNow = true
            lastEligibleAt = now
        } else {
            if eligibleNow { lastEligibleAt = now }
            eligibleNow = false
        }
    }

    /// `overrideUntil` is a timestamp in the same clock as `now`; `.infinity` means "until turned off".
    public func isOpen(mediaOnly: Bool, overrideUntil: Double?, now: Double) -> Bool {
        if !mediaOnly { return true }
        if let until = overrideUntil, until > now { return true }
        if eligibleNow { return true }
        if let last = lastEligibleAt, now - last < closeGrace { return true }
        return false
    }
}

// MARK: - CoreAudio activity (approximate playback)

public struct AudioProcessInfo: Equatable {
    public var pid: Int32
    public var bundleID: String
    public var isRunningOutput: Bool

    public init(pid: Int32, bundleID: String, isRunningOutput: Bool) {
        self.pid = pid
        self.bundleID = bundleID
        self.isRunningOutput = isRunningOutput
    }
}

public struct AudioActivityResult: Equatable {
    public var playing: Bool
    public var source: String?
    /// Seconds until the next evaluation is useful (a process hasn't yet been running long enough).
    public var recheckIn: Double?
}

/// Turns "these processes have active audio output" into a conservative guess at "media is playing".
/// Cannot distinguish a paused session, muted video or non-media sound; callers must label it approximate.
public struct AudioActivityEvaluator {
    public var minDuration: Double = 2.0
    public var excludedPrefixes: [String] = [
        "com.apple.coreaudiod", "com.apple.audio.", "com.apple.siri", "com.apple.assistant",
        "com.apple.accessibility", "com.apple.speech", "com.apple.systemsound",
        "com.apple.FaceTime", "com.apple.avconferenced", "com.apple.notificationcenter",
        "zoom.us", "us.zoom", "com.microsoft.teams", "com.cisco.webex", "com.webex",
        "com.hnc.Discord", "com.tinyspeck.slackmacgap", "com.skype",
    ]

    private var since: [Int32: Double] = [:]

    public init() {}

    public mutating func evaluate(
        processes: [AudioProcessInfo],
        inputDeviceRunning: Bool,
        now: Double,
        ignore: (String) -> Bool = { _ in false }
    ) -> AudioActivityResult {
        let running = processes.filter { $0.isRunningOutput }
        let livePids = Set(running.map { $0.pid })
        for k in Array(since.keys) where !livePids.contains(k) { since.removeValue(forKey: k) }

        var qualifyingSource: String?
        var soonest: Double?

        for p in running {
            if since[p.pid] == nil { since[p.pid] = now }
            if isExcluded(p.bundleID) || ignore(p.bundleID) { continue }
            let age = now - (since[p.pid] ?? now)
            if age >= minDuration {
                if qualifyingSource == nil { qualifyingSource = p.bundleID }
            } else {
                let remaining = minDuration - age
                soonest = min(soonest ?? remaining, remaining)
            }
        }

        // Something is capturing the microphone: assume a call, not media.
        if inputDeviceRunning { return AudioActivityResult(playing: false, source: nil, recheckIn: nil) }

        if let source = qualifyingSource {
            return AudioActivityResult(playing: true, source: source, recheckIn: nil)
        }
        return AudioActivityResult(playing: false, source: nil, recheckIn: soonest)
    }

    private func isExcluded(_ bundleID: String) -> Bool {
        excludedPrefixes.contains { bundleID.hasPrefix($0) }
    }
}
