import CoreGraphics
import Foundation

/// Controls the BUILT-IN display brightness through Apple's PRIVATE DisplayServices framework.
/// There is no supported API for this on Apple Silicon. Loaded at runtime; failure disables only brightness.
/// No overlay or gamma tricks are used.
final class BrightnessController {
    private typealias GetFn = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (UInt32, Float) -> Int32

    private static let path = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
    /// Never go fully dark: the user must always be able to see the screen.
    static let minimum: Float = 0.02

    private let lock = NSLock()
    private var getFn: GetFn?
    private var setFn: SetFn?
    private var display: CGDirectDisplayID = 0
    private var cached: Float = 0

    private(set) var capability: Capability = .unavailable("Not checked")
    var isAvailable: Bool { capability.isUsable }

    /// Resolves the private symbols and finds the built-in display. With `writeTest`, also nudges the brightness by
    /// 1% and restores it to prove that setting works.
    @discardableResult
    func probe(writeTest: Bool) -> Capability {
        lock.lock()
        defer { lock.unlock() }

        if getFn == nil || setFn == nil {
            guard let h = dlopen(Self.path, RTLD_NOW) else {
                capability = .unavailable("DisplayServices.framework could not be loaded")
                return capability
            }
            guard let g = dlsym(h, "DisplayServicesGetBrightness"),
                  let s = dlsym(h, "DisplayServicesSetBrightness") else {
                capability = .unavailable("DisplayServices brightness symbols are missing on this macOS version")
                return capability
            }
            getFn = unsafeBitCast(g, to: GetFn.self)
            setFn = unsafeBitCast(s, to: SetFn.self)
        }

        guard let id = builtInDisplay() else {
            capability = .unavailable("No active built-in display")
            return capability
        }
        display = id

        var value: Float = 0
        guard let get = getFn, let set = setFn, get(id, &value) == 0 else {
            capability = .unavailable("Reading the brightness failed")
            return capability
        }
        cached = value

        guard writeTest else {
            capability = .available
            return capability
        }

        let target = min(max(value + (value > 0.5 ? -0.01 : 0.01), Self.minimum), 1)
        guard set(id, target) == 0 else {
            capability = .unavailable("Setting the brightness failed")
            return capability
        }
        var readBack: Float = 0
        _ = get(id, &readBack)
        _ = set(id, value)                     // always restore the original value

        capability = abs(readBack - target) > 0.02
            ? .degraded("Brightness did not follow the request (automatic brightness may be interfering)")
            : .available
        return capability
    }

    /// Call when a gesture starts.
    func begin() {
        lock.lock()
        defer { lock.unlock() }
        guard let get = getFn else { return }
        var v: Float = 0
        if get(display, &v) == 0 { cached = v }
    }

    /// Returns old and new positions normalized to 0...1 across the usable range (minimum...1).
    func adjust(by delta: Float) -> (old: Float, new: Float)? {
        lock.lock()
        defer { lock.unlock() }
        guard capability.isUsable, let set = setFn else { return nil }

        let span = 1 - Self.minimum
        let oldValue = cached
        let newValue = min(max(oldValue + delta * span, Self.minimum), 1)
        guard newValue != oldValue else { return nil }
        guard set(display, newValue) == 0 else {
            capability = .degraded("Setting the brightness failed")
            return nil
        }
        cached = newValue
        return ((oldValue - Self.minimum) / span, (newValue - Self.minimum) / span)
    }

    /// Current raw value 0...1 for display.
    func current() -> Float? {
        lock.lock()
        defer { lock.unlock() }
        guard capability.isUsable, let get = getFn else { return nil }
        var v: Float = 0
        return get(display, &v) == 0 ? v : nil
    }

    private func builtInDisplay() -> CGDirectDisplayID? {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return nil }
        return ids.first(where: { CGDisplayIsBuiltin($0) != 0 })
    }
}
