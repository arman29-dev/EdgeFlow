import AppKit
import ApplicationServices
import TEGCore

/// Tracks whether a recognized gesture currently "owns" the touch sequence.
final class GestureOwnership {
    private let lock = NSLock()
    private var owned = false
    private var endedAt = -1000.0

    func set(_ value: Bool) {
        lock.lock()
        owned = value
        if !value { endedAt = uptime() }
        lock.unlock()
    }

    /// True while a gesture is active, plus a short tail so trailing momentum scroll events are caught.
    func isOwned(tail: Double = 0.05) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return owned || (uptime() - endedAt) < tail
    }
}

/// Active CGEventTap for scroll events (needs Accessibility permission).
///
/// Edge-zone mode: drops trackpad scroll events ONLY while a gesture is positively recognized (plus 50 ms).
/// Everything else passes through untouched. Scroll movement before recognition has already reached the app
/// in front; that is unavoidable and documented.
///
/// Modifier mode (fallback): Control+Option + two-finger scroll adjusts volume; add Shift for brightness.
final class ScrollConflictManager {
    private let ownership: GestureOwnership
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    var settings: () -> AppSettings = { .default }
    var gateOpen: () -> Bool = { false }
    var onModifierScroll: ((GestureAction, Float) -> Void)?
    var onTapDisabled: (() -> Void)?

    private(set) var capability: Capability = .unavailable("Not started")

    init(ownership: GestureOwnership) {
        self.ownership = ownership
    }

    /// Must be called on the main thread.
    func start() {
        stop()
        guard AXIsProcessTrusted() else {
            capability = .unavailable("Accessibility permission is not granted")
            return
        }
        let mask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: scrollTapCallback,
            userInfo: refcon
        ) else {
            capability = .unavailable("The system refused to create the event tap")
            return
        }
        guard let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            capability = .unavailable("Could not create the event tap run loop source")
            return
        }
        tap = port
        source = runLoopSource
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        capability = .available
    }

    func stop() {
        if let port = tap { CGEvent.tapEnable(tap: port, enable: false) }
        if let src = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes) }
        tap = nil
        source = nil
        capability = .unavailable("Stopped")
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let passThrough = Unmanaged.passUnretained(event)

        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let port = tap { CGEvent.tapEnable(tap: port, enable: true) }
            onTapDisabled?()
            return passThrough

        case .scrollWheel:
            // Leave mouse-wheel ticks alone; only smooth trackpad scrolls are ever considered.
            guard event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0 else { return passThrough }
            let s = settings()
            guard s.gesturesEnabled else { return passThrough }

            switch s.activationMethod {
            case .edgeZones:
                if s.suppressScroll && ownership.isOwned() { return nil }
                return passThrough

            case .modifier:
                let flags = event.flags
                guard flags.contains(.maskControl), flags.contains(.maskAlternate), gateOpen() else { return passThrough }
                let points = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
                var fraction = -Float(points) / 800 * s.sensitivity       // sign UNVERIFIED; use "Invert direction" to flip
                if s.invertDirection { fraction = -fraction }
                fraction = min(max(fraction, -0.03), 0.03)
                onModifierScroll?(flags.contains(.maskShift) ? .brightness : .volume, fraction)
                return nil
            }

        default:
            return passThrough
        }
    }
}

private func scrollTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let manager = Unmanaged<ScrollConflictManager>.fromOpaque(refcon).takeUnretainedValue()
    return manager.handle(type: type, event: event)
}
