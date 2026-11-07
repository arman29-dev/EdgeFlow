import AppKit

private final class HUDBarView: NSView {
    var value: CGFloat = 0 {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        NSColor.labelColor.withAlphaComponent(0.2).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()

        guard value > 0 else { return }
        var filled = bounds
        filled.size.width = max(bounds.height, bounds.width * min(value, 1))
        NSColor.labelColor.withAlphaComponent(0.9).setFill()
        NSBezierPath(roundedRect: filled, xRadius: radius, yRadius: radius).fill()
    }
}

/// Small optional level indicator. Non-activating, ignores the mouse, never takes keyboard focus.
/// (macOS has no public API for showing its own volume/brightness HUD.) Main thread only.
final class HUDPanel {
    private var panel: NSPanel?
    private let icon = NSImageView()
    private let bar = HUDBarView()
    private var currentSymbol = ""
    private var hideWork: DispatchWorkItem?

    func show(volume value: Float) {
        let symbol: String
        if value <= 0.001 { symbol = "speaker.slash.fill" }
        else if value < 0.34 { symbol = "speaker.wave.1.fill" }
        else if value < 0.67 { symbol = "speaker.wave.2.fill" }
        else { symbol = "speaker.wave.3.fill" }
        present(symbol: symbol, value: value)
    }

    func show(brightness value: Float) {
        present(symbol: "sun.max.fill", value: value)
    }

    private func present(symbol: String, value: Float) {
        let panel = ensurePanel()

        if symbol != currentSymbol {
            currentSymbol = symbol
            icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
        bar.value = CGFloat(value)

        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let frame = screen.visibleFrame
            let origin = NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.minY + 90)
            panel.setFrameOrigin(origin)
        }

        panel.alphaValue = 1
        panel.orderFrontRegardless()

        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let panel = self?.panel else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.25
                panel.animator().alphaValue = 0
            }, completionHandler: {
                panel.orderOut(nil)
            })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }

        let size = NSSize(width: 240, height: 64)
        let p = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]

        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        effect.layer?.masksToBounds = true

        icon.frame = NSRect(x: 18, y: 20, width: 26, height: 24)
        icon.contentTintColor = .labelColor
        icon.imageScaling = .scaleProportionallyUpOrDown
        bar.frame = NSRect(x: 56, y: 28, width: 166, height: 8)

        effect.addSubview(icon)
        effect.addSubview(bar)
        p.contentView = effect

        panel = p
        return p
    }
}
