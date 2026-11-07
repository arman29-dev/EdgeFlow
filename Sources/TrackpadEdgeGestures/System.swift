import AppKit
import ApplicationServices
import ServiceManagement
import TEGCore

// MARK: - Permissions

enum Permissions {
    static var accessibilityGranted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt for Accessibility (adds the app to the list in System Settings).
    static func promptAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    static func openInputMonitoringSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
    }

    static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private static func open(_ string: String) {
        if let url = URL(string: string) { NSWorkspace.shared.open(url) }
    }

    /// Explains why Accessibility is wanted before sending the user to System Settings. Main thread only.
    static func explainAccessibility() {
        let alert = NSAlert()
        alert.messageText = "Accessibility access is optional"
        alert.informativeText = """
        Trackpad Edge Gestures uses it for one thing: stopping the page behind you from scrolling while \
        you are adjusting volume or brightness (and for the modifier-key fallback mode).

        It never reads what you type or what is on screen. If you prefer not to grant it, turn off \
        "Stop the page scrolling during a gesture" in Settings.
        """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Not now")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            promptAccessibility()
            openAccessibilitySettings()
        }
    }
}

// MARK: - Launch at login

enum LoginItem {
    /// Registration only works from a real .app bundle (not from `.build/`).
    static var isAppBundle: Bool { Bundle.main.bundlePath.hasSuffix(".app") }

    static var status: SMAppService.Status { SMAppService.mainApp.status }

    static var isEnabledInSystem: Bool { status == .enabled }

    static var statusText: String {
        guard isAppBundle else { return "Run from a .app bundle to enable (see README)" }
        switch status {
        case .enabled: return "On"
        case .notRegistered: return "Off"
        case .requiresApproval: return "Needs approval in System Settings > Login Items"
        case .notFound: return "Not found (install the app in ~/Applications)"
        @unknown default: return "Unknown"
        }
    }

    /// Returns an error description on failure, nil on success.
    @discardableResult
    static func set(_ enabled: Bool) -> String? {
        guard isAppBundle else { return "Not running from a .app bundle" }
        do {
            if enabled {
                if status != .enabled { try SMAppService.mainApp.register() }
            } else if status == .enabled || status == .requiresApproval {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            // requiresApproval is a normal outcome and is reported through `status`, not as a failure.
            return status == .requiresApproval ? nil : error.localizedDescription
        }
    }
}

// MARK: - Settings manager

final class SettingsManager {
    private let storage = SettingsStorage()
    private let lock = NSLock()
    private var current: AppSettings
    private var saveWork: DispatchWorkItem?
    private var observers: [(AppSettings) -> Void] = []

    /// (old, new) after every accepted change.
    var onChange: ((AppSettings, AppSettings) -> Void)?

    init() {
        current = storage.load()
    }

    var value: AppSettings {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func addObserver(_ f: @escaping (AppSettings) -> Void) {
        lock.lock()
        observers.append(f)
        lock.unlock()
    }

    func set(_ new: AppSettings) {
        let v = new.validated()
        lock.lock()
        let old = current
        if old == v { lock.unlock(); return }
        current = v
        let obs = observers
        lock.unlock()

        scheduleSave(v)
        onChange?(old, v)
        for f in obs { f(v) }
    }

    func update(_ change: (inout AppSettings) -> Void) {
        var s = value
        change(&s)
        set(s)
    }

    func reset() {
        set(.default)
    }

    /// Writes immediately (called on quit).
    func flush() {
        let v = value
        DispatchQueue.main.async { [weak self] in
            self?.saveWork?.cancel()
            self?.storage.save(v)
        }
    }

    private func scheduleSave(_ v: AppSettings) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.saveWork?.cancel()
            let work = DispatchWorkItem { [storage = self.storage] in storage.save(v) }
            self.saveWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
        }
    }
}
