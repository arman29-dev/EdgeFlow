import CoreAudio
import AudioToolbox
import Foundation

/// Controls the default output device's volume with CoreAudio properties (public API).
/// Devices without a settable volume (some HDMI/DisplayPort outputs) are reported as unavailable.
final class VolumeController {
    private enum Mode { case virtualMain, scalarMain, scalarChannels }

    /// 'vmvc' (kAudioHardwareServiceDeviceProperty_VirtualMainVolume), used directly to avoid deprecated AudioHardwareService calls.
    private let virtualMainVolume: AudioObjectPropertySelector = 0x766D_7663

    private let lock = NSLock()
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var mode: Mode?
    private var cached: Float = 0
    private var wasMuted = false
    private var listener: AudioObjectPropertyListenerBlock?

    private(set) var capability: Capability = .unavailable("Not checked")
    private(set) var deviceName = "Unknown"

    var onDeviceChange: (() -> Void)?

    var isAvailable: Bool { capability.isUsable }

    // MARK: Device discovery

    func startListening() {
        guard listener == nil else { return }
        var a = address(kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.refresh()
            self?.onDeviceChange?()
        }
        listener = block
        _ = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, DispatchQueue.main, block)
    }

    func refresh() {
        lock.lock()
        defer { lock.unlock() }

        var a = address(kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal)
        var dev = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &dev)
        guard status == noErr, dev != AudioObjectID(kAudioObjectUnknown) else {
            device = AudioObjectID(kAudioObjectUnknown)
            mode = nil
            deviceName = "None"
            capability = .unavailable("No output device")
            return
        }

        device = dev
        deviceName = readName(dev)

        if canSet(virtualMainVolume, element: kAudioObjectPropertyElementMain) {
            mode = .virtualMain
        } else if canSet(kAudioDevicePropertyVolumeScalar, element: kAudioObjectPropertyElementMain) {
            mode = .scalarMain
        } else if canSet(kAudioDevicePropertyVolumeScalar, element: 1), canSet(kAudioDevicePropertyVolumeScalar, element: 2) {
            mode = .scalarChannels
        } else {
            mode = nil
        }

        capability = mode == nil
            ? .unavailable("\(deviceName) has no software volume control")
            : .available
    }

    // MARK: Gesture API

    /// Call when a gesture starts: reads the current value and mute state.
    func begin() {
        lock.lock()
        defer { lock.unlock() }
        guard mode != nil, let v = readVolume() else { return }
        cached = v
        wasMuted = isMuted()
    }

    /// Returns old and new values (0...1), or nil when nothing changed.
    func adjust(by delta: Float) -> (old: Float, new: Float)? {
        lock.lock()
        defer { lock.unlock() }
        guard mode != nil else { return nil }

        if wasMuted {
            // Going up on a muted device unmutes it; going down does nothing.
            guard delta > 0 else { return nil }
            setMuted(false)
            wasMuted = false
        }

        let old = cached
        let new = min(max(old + delta, 0), 1)
        guard new != old else { return nil }
        guard writeVolume(new) else {
            capability = .degraded("Setting the volume failed")
            return nil
        }
        cached = new
        return (old, new)
    }

    /// Current value for display (0...1).
    func current() -> Float? {
        lock.lock()
        defer { lock.unlock() }
        return mode == nil ? nil : readVolume()
    }

    // MARK: CoreAudio helpers

    private func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioDevicePropertyScopeOutput,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    private func canSet(_ selector: AudioObjectPropertySelector, element: AudioObjectPropertyElement) -> Bool {
        var a = address(selector, element: element)
        guard AudioObjectHasProperty(device, &a) else { return false }
        var settable = DarwinBoolean(false)
        guard AudioObjectIsPropertySettable(device, &a, &settable) == noErr else { return false }
        return settable.boolValue
    }

    private func getFloat(_ selector: AudioObjectPropertySelector, element: AudioObjectPropertyElement) -> Float? {
        var a = address(selector, element: element)
        var v: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &a, 0, nil, &size, &v) == noErr else { return nil }
        return v
    }

    private func setFloat(_ selector: AudioObjectPropertySelector, element: AudioObjectPropertyElement, _ value: Float) -> Bool {
        var a = address(selector, element: element)
        var v: Float32 = value
        return AudioObjectSetPropertyData(device, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &v) == noErr
    }

    private func readVolume() -> Float? {
        switch mode {
        case .virtualMain:
            return getFloat(virtualMainVolume, element: kAudioObjectPropertyElementMain)
        case .scalarMain:
            return getFloat(kAudioDevicePropertyVolumeScalar, element: kAudioObjectPropertyElementMain)
        case .scalarChannels:
            guard let l = getFloat(kAudioDevicePropertyVolumeScalar, element: 1),
                  let r = getFloat(kAudioDevicePropertyVolumeScalar, element: 2) else { return nil }
            return (l + r) / 2
        case nil:
            return nil
        }
    }

    private func writeVolume(_ value: Float) -> Bool {
        switch mode {
        case .virtualMain:
            return setFloat(virtualMainVolume, element: kAudioObjectPropertyElementMain, value)
        case .scalarMain:
            return setFloat(kAudioDevicePropertyVolumeScalar, element: kAudioObjectPropertyElementMain, value)
        case .scalarChannels:
            let l = setFloat(kAudioDevicePropertyVolumeScalar, element: 1, value)
            let r = setFloat(kAudioDevicePropertyVolumeScalar, element: 2, value)
            return l && r
        case nil:
            return false
        }
    }

    private func isMuted() -> Bool {
        var a = address(kAudioDevicePropertyMute)
        guard AudioObjectHasProperty(device, &a) else { return false }
        var v: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &a, 0, nil, &size, &v) == noErr else { return false }
        return v != 0
    }

    private func setMuted(_ muted: Bool) {
        var a = address(kAudioDevicePropertyMute)
        guard canSet(kAudioDevicePropertyMute, element: kAudioObjectPropertyElementMain) else { return }
        var v: UInt32 = muted ? 1 : 0
        _ = AudioObjectSetPropertyData(device, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &v)
    }

    private func readName(_ dev: AudioObjectID) -> String {
        var a = address(kAudioObjectPropertyName, scope: kAudioObjectPropertyScopeGlobal)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(dev, &a, 0, nil, &size, &name)
        if status == noErr, let n = name {
            return n.takeRetainedValue() as String
        }
        return "Output device"
    }
}
