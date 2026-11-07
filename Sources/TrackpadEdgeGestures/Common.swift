import Foundation

/// Health of one feature. Each feature fails independently; the app keeps running.
enum Capability: Equatable {
    case available
    case degraded(String)
    case unavailable(String)

    var isUsable: Bool {
        if case .unavailable = self { return false }
        return true
    }

    var text: String {
        switch self {
        case .available: return "Available"
        case .degraded(let why): return "Degraded: \(why)"
        case .unavailable(let why): return "Unavailable: \(why)"
        }
    }
}

/// Overall state shown by the menu-bar icon.
enum AppStatus {
    case active
    case waiting
    case manual
    case paused
    case missingPermission
    case unsupported
    case error

    var title: String {
        switch self {
        case .active: return "Gestures active"
        case .waiting: return "Waiting for media"
        case .manual: return "Manually enabled"
        case .paused: return "Paused"
        case .missingPermission: return "Missing permission"
        case .unsupported: return "Feature unsupported"
        case .error: return "Error: see Diagnostics"
        }
    }

    var symbol: String {
        switch self {
        case .active: return "slider.vertical.3"
        case .waiting: return "pause.circle"
        case .manual: return "play.circle"
        case .paused: return "minus.circle"
        case .missingPermission: return "lock.shield"
        case .unsupported: return "exclamationmark.triangle"
        case .error: return "xmark.octagon"
        }
    }
}

@inline(__always)
func uptime() -> Double {
    ProcessInfo.processInfo.systemUptime
}
