import AppKit

/// The menu-bar icon and its menu. The menu is rebuilt each time it opens so it always shows live state.
final class StatusItemController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private unowned let coordinator: AppCoordinator
    private var current: AppStatus = .waiting

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        super.init()
        menu.delegate = self
        item.menu = menu
        setStatus(.waiting)
    }

    func setStatus(_ status: AppStatus) {
        current = status
        guard let button = item.button else { return }
        if let image = NSImage(systemSymbolName: status.symbol, accessibilityDescription: "Trackpad Edge Gestures: \(status.title)") {
            image.isTemplate = true
            button.image = image
            button.title = ""
        } else {
            button.image = nil
            button.title = "TEG"
        }
        button.toolTip = "Trackpad Edge Gestures: \(status.title)"
    }

    // MARK: NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let s = coordinator.settings.value

        add(current.title, nil, enabled: false)
        add(coordinator.playbackDescription, nil, enabled: false)
        menu.addItem(.separator())

        add("Enable gestures", #selector(toggleGestures), checked: s.gesturesEnabled)

        let overrideItem = NSMenuItem(title: "Manual override", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.addItem(makeItem("Enable for 15 minutes", #selector(override15)))
        sub.addItem(makeItem("Enable for 1 hour", #selector(override60)))
        sub.addItem(makeItem("Enable until turned off", #selector(overrideForever)))
        if coordinator.overrideActive {
            sub.addItem(.separator())
            sub.addItem(makeItem("Cancel override", #selector(cancelOverride)))
        }
        overrideItem.submenu = sub
        menu.addItem(overrideItem)

        menu.addItem(.separator())
        let volumeText = coordinator.currentVolumePercent().map { "\($0)%" } ?? "unavailable"
        let brightnessText = coordinator.currentBrightnessPercent().map { "\($0)%" } ?? "unavailable"
        add("Volume: \(volumeText)", nil, enabled: false)
        add("Brightness: \(brightnessText)", nil, enabled: false)

        menu.addItem(.separator())
        menu.addItem(makeItem("Settings…", #selector(openSettings), key: ","))
        add("Launch at Login", #selector(toggleLogin), checked: LoginItem.isEnabledInSystem)
        menu.addItem(.separator())
        menu.addItem(makeItem("Quit Trackpad Edge Gestures", #selector(quit), key: "q"))
    }

    // MARK: Helpers

    private func makeItem(_ title: String, _ action: Selector?, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func add(_ title: String, _ action: Selector?, checked: Bool = false, enabled: Bool = true) {
        let item = makeItem(title, action)
        item.state = checked ? .on : .off
        item.isEnabled = enabled && action != nil
        menu.addItem(item)
    }

    // MARK: Actions

    @objc private func toggleGestures() { coordinator.toggleGestures() }
    @objc private func override15() { coordinator.enableOverride(minutes: 15) }
    @objc private func override60() { coordinator.enableOverride(minutes: 60) }
    @objc private func overrideForever() { coordinator.enableOverride(minutes: nil) }
    @objc private func cancelOverride() { coordinator.cancelOverride() }
    @objc private func openSettings() { coordinator.openSettings() }
    @objc private func toggleLogin() { coordinator.setLaunchAtLogin(!LoginItem.isEnabledInSystem) }
    @objc private func quit() { coordinator.quit() }
}
