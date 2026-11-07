import Foundation
import TEGCore

/// Reads raw contact positions from the built-in trackpad through Apple's PRIVATE MultitouchSupport framework.
///
/// Everything is resolved with dlopen/dlsym at runtime. If the framework or a symbol is missing (for example
/// after a macOS update), `start()` reports `.unavailable` and the rest of the app keeps working.
///
/// UNVERIFIED on the target Mac: the struct layout offsets below, the state values, and the y direction.
/// Run `EdgeFlow --probe` to check them.
final class MultitouchProvider {
    private typealias CreateListFn = @convention(c) () -> Unmanaged<CFArray>?
    private typealias IsBuiltInFn = @convention(c) (UnsafeMutableRawPointer) -> Bool
    private typealias StartFn = @convention(c) (UnsafeMutableRawPointer, Int32) -> Int32
    private typealias StopFn = @convention(c) (UnsafeMutableRawPointer) -> Int32
    private typealias IsRunningFn = @convention(c) (UnsafeMutableRawPointer) -> Bool
    typealias ContactCallback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32
    private typealias RegisterFn = @convention(c) (UnsafeMutableRawPointer, ContactCallback) -> Void

    private static let path = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"

    // Layout of the community-documented MTTouch struct (96 bytes per touch).
    private static let touchStride = 96
    private static let offId = 16
    private static let offState = 20
    private static let offX = 32
    private static let offY = 36
    private static let offSize = 48

    static weak var current: MultitouchProvider?

    /// Called on a framework thread for every frame (including empty frames when all fingers lift).
    var onFrame: ((TouchFrame) -> Void)?

    private(set) var capability: Capability = .unavailable("Not started")
    private(set) var deviceCount = 0

    private var handle: UnsafeMutableRawPointer?
    private var deviceList: CFArray?
    private var devices: [UnsafeMutableRawPointer] = []
    private var unregisterFn: RegisterFn?
    private var stopFn: StopFn?
    private var isRunningFn: IsRunningFn?

    @discardableResult
    func start() -> Capability {
        stop()

        guard let h = dlopen(Self.path, RTLD_NOW) else {
            return setCapability(.unavailable("MultitouchSupport.framework could not be loaded"))
        }
        handle = h

        guard let sCreate = dlsym(h, "MTDeviceCreateList"),
              let sBuilt = dlsym(h, "MTDeviceIsBuiltIn"),
              let sReg = dlsym(h, "MTRegisterContactFrameCallback"),
              let sStart = dlsym(h, "MTDeviceStart"),
              let sStop = dlsym(h, "MTDeviceStop") else {
            return setCapability(.unavailable("Required MultitouchSupport symbols are missing on this macOS version"))
        }

        let create = unsafeBitCast(sCreate, to: CreateListFn.self)
        let isBuiltIn = unsafeBitCast(sBuilt, to: IsBuiltInFn.self)
        let register = unsafeBitCast(sReg, to: RegisterFn.self)
        let startDevice = unsafeBitCast(sStart, to: StartFn.self)
        stopFn = unsafeBitCast(sStop, to: StopFn.self)
        if let s = dlsym(h, "MTUnregisterContactFrameCallback") { unregisterFn = unsafeBitCast(s, to: RegisterFn.self) }
        if let s = dlsym(h, "MTDeviceIsRunning") { isRunningFn = unsafeBitCast(s, to: IsRunningFn.self) }

        guard let list = create()?.takeRetainedValue() else {
            return setCapability(.unavailable("MTDeviceCreateList returned nothing"))
        }

        Self.current = self
        var found: [UnsafeMutableRawPointer] = []
        for i in 0..<CFArrayGetCount(list) {
            guard let raw = CFArrayGetValueAtIndex(list, i) else { continue }
            let device = UnsafeMutableRawPointer(mutating: raw)
            if isBuiltIn(device) {
                register(device, contactCallback)
                _ = startDevice(device, 0)
                found.append(device)
            }
        }

        deviceList = list          // keep the devices alive while we hold callbacks on them
        devices = found
        deviceCount = found.count

        if found.isEmpty {
            return setCapability(.unavailable("No built-in trackpad found"))
        }
        return setCapability(.available)
    }

    func stop() {
        for device in devices {
            unregisterFn?(device, contactCallback)
            // Stopping a device that isn't running has crashed other wrappers, so check first.
            if isRunningFn?(device) ?? true {
                _ = stopFn?(device)
            }
        }
        devices.removeAll()
        deviceList = nil
        deviceCount = 0
        if Self.current === self { Self.current = nil }
        capability = .unavailable("Stopped")
    }

    private func setCapability(_ c: Capability) -> Capability {
        capability = c
        return c
    }

    fileprivate static func deliver(data: UnsafeMutableRawPointer?, count: Int, timestamp: Double) {
        guard let provider = current, let callback = provider.onFrame else { return }
        var contacts: [TouchContact] = []
        let n = min(max(count, 0), 11)
        if let data, n > 0 {
            contacts.reserveCapacity(n)
            let base = UnsafeRawPointer(data)
            for i in 0..<n {
                let p = base.advanced(by: i * touchStride)
                contacts.append(TouchContact(
                    id: p.load(fromByteOffset: offId, as: Int32.self),
                    x: p.load(fromByteOffset: offX, as: Float.self),
                    y: p.load(fromByteOffset: offY, as: Float.self),
                    state: p.load(fromByteOffset: offState, as: Int32.self),
                    size: p.load(fromByteOffset: offSize, as: Float.self)
                ))
            }
        }
        callback(TouchFrame(timestamp: timestamp, contacts: contacts))
    }
}

/// A C function pointer cannot capture context, so it forwards through the static `current` provider.
private let contactCallback: MultitouchProvider.ContactCallback = { _, data, count, timestamp, _ in
    MultitouchProvider.deliver(data: data, count: Int(count), timestamp: timestamp)
    return 0
}
