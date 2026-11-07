import Foundation

public enum SmoothingLevel: String, Codable, CaseIterable {
    case low, medium, high

    /// EMA factor applied to the finger position (higher = more responsive, less smooth).
    public var alpha: Float {
        switch self {
        case .low: return 0.6
        case .medium: return 0.35
        case .high: return 0.2
        }
    }

    public var title: String {
        switch self {
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        }
    }
}

public enum ActivationMethod: String, Codable, CaseIterable {
    /// Two fingers starting inside a trackpad edge zone (needs the private MultitouchSupport framework).
    case edgeZones
    /// Hold Control+Option (+Shift for brightness) and two-finger scroll. No edge awareness.
    case modifier

    public var title: String {
        switch self {
        case .edgeZones: return "Trackpad edge zones"
        case .modifier: return "Modifier key + scroll (fallback)"
        }
    }
}

public struct AppSettings: Codable, Equatable {
    public static let currentVersion = 1

    public var version: Int = AppSettings.currentVersion

    // General
    public var gesturesEnabled = true
    public var launchAtLogin = true
    public var launchAtLoginHandled = false      // first-run registration done once; later opt-outs respected
    public var mediaOnly = true

    // Gestures
    public var leftZoneWidth: Float = 0.15
    public var rightZoneWidth: Float = 0.15
    public var sensitivity: Float = 1.2          // full range per pad-height of travel
    public var minMovement: Float = 0.025        // fraction of pad height
    public var smoothing: SmoothingLevel = .medium
    public var activationMethod: ActivationMethod = .edgeZones
    public var suppressScroll = true
    public var invertDirection = false

    // Volume / brightness
    public var volumeEnabled = true
    public var volumeSensitivity: Float = 1.0
    public var brightnessEnabled = true
    public var brightnessSensitivity: Float = 1.0

    // Haptics
    public var hapticsEnabled = true
    public var hapticIntervalPoints = 10
    public var hapticAtLimits = true

    // Media detection
    public var allowApproximate = true
    public var useAppSignals = true              // Music / Spotify notifications

    // Feedback
    public var showHUD = true

    public init() {}

    public static let `default` = AppSettings()

    public static let zoneRange: ClosedRange<Float> = 0.08...0.30
    public static let maxCombinedZones: Float = 0.60

    /// Returns a copy with every value clamped to its safe range.
    public func validated() -> AppSettings {
        var s = self
        s.version = AppSettings.currentVersion
        s.leftZoneWidth = AppSettings.clamp(s.leftZoneWidth, AppSettings.zoneRange)
        s.rightZoneWidth = AppSettings.clamp(s.rightZoneWidth, AppSettings.zoneRange)
        let sum = s.leftZoneWidth + s.rightZoneWidth
        if sum > AppSettings.maxCombinedZones {
            let k = AppSettings.maxCombinedZones / sum
            s.leftZoneWidth *= k
            s.rightZoneWidth *= k
        }
        s.sensitivity = AppSettings.clamp(s.sensitivity, 0.5...3.0)
        s.minMovement = AppSettings.clamp(s.minMovement, 0.01...0.08)
        s.volumeSensitivity = AppSettings.clamp(s.volumeSensitivity, 0.5...2.0)
        s.brightnessSensitivity = AppSettings.clamp(s.brightnessSensitivity, 0.5...2.0)
        if ![5, 10, 20].contains(s.hapticIntervalPoints) { s.hapticIntervalPoints = 10 }
        return s
    }

    private static func clamp(_ v: Float, _ r: ClosedRange<Float>) -> Float {
        if v.isNaN { return r.lowerBound }
        return min(max(v, r.lowerBound), r.upperBound)
    }
}

/// Stores one versioned JSON blob in UserDefaults. Corrupt or unknown data falls back to defaults.
public struct SettingsStorage {
    public let defaults: UserDefaults
    public let key: String

    public init(defaults: UserDefaults = .standard, key: String = "EdgeFlow.settings.v1") {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> AppSettings {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return AppSettings.default
        }
        return decoded.validated()
    }

    public func save(_ settings: AppSettings) {
        guard let data = try? JSONEncoder().encode(settings.validated()) else { return }
        defaults.set(data, forKey: key)
    }

    public func reset() {
        defaults.removeObject(forKey: key)
    }
}
