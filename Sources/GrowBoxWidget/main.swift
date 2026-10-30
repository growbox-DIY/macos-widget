import AppKit
import ServiceManagement
import SwiftUI

// A borderless window that sits on the desktop, under the other windows,
// on every Space. Drag it anywhere; the position is remembered.
// Menu bar item: temperature and humidity at a glance, click to show or
// hide the panel, right-click (or on the panel) for the menu.

final class WidgetWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

// SwiftUI takes the mouse for itself, so isMovableByWindowBackground alone
// does nothing: drag the window from any click, even the first one while
// another app is active
final class DragHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: WidgetWindow?
    private var statusItem: NSStatusItem?
    private let model = BoxModel()

    private static let hiddenKey = "panelHidden"
    private static let loginConfiguredKey = "loginItemConfigured"

    func applicationDidFinishLaunching(_ notification: Notification) {
        Ionicon.registerFont()
        let host = DragHostingView(rootView: WidgetView(model: model).fixedSize())
        host.menu = makeMenu()

        let window = WidgetWindow(
            contentRect: NSRect(origin: .zero, size: host.fittingSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        window.level = NSWindow.Level(Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

        if !window.setFrameUsingName("GrowBoxWidget") {
            if let screen = NSScreen.main?.visibleFrame {
                window.setFrameTopLeftPoint(NSPoint(x: screen.maxX - host.fittingSize.width - 24, y: screen.maxY - 24))
            }
        }
        window.setFrameAutosaveName("GrowBoxWidget")

        self.window = window
        setPanelVisible(!UserDefaults.standard.bool(forKey: Self.hiddenKey))
        setUpStatusItem()
        enableLoginItemOnFirstRun()
        model.start()

        // --snapshot <file.png>: render the widget once the data is in and
        // quit (for checking the layout without screen access)
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--snapshot"), index + 1 < args.count {
            let path = args[index + 1]
            // --snapshot-delay <s>: render earlier, e.g. 0 to see the loaders
            let delay = args.firstIndex(of: "--snapshot-delay")
                .flatMap { $0 + 1 < args.count ? Double(args[$0 + 1]) : nil } ?? 10
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                let renderer = ImageRenderer(content: WidgetView(model: model).fixedSize())
                renderer.scale = 2
                if let image = renderer.cgImage {
                    let rep = NSBitmapImageRep(cgImage: image)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                }
                NSApp.terminate(nil)
            }
        }
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        let toggle = NSMenuItem(title: "Hide panel", action: #selector(togglePanel), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)
        let login = NSMenuItem(title: "Open at login", action: #selector(toggleLoginItem), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit GrowBox Widget", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return menu
    }

    // --- menu bar ---

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = Ionicon.leafOutline.image(size: 15)
        item.button?.imagePosition = .imageLeading
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item

        updateStatusTitle()
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateStatusTitle() }
        }
    }

    private func updateStatusTitle() {
        guard let button = statusItem?.button else { return }

        let sensor = model.response?.sensor
        let temperature = sensor?.temperature.map { String(format: "%.1f°", $0) } ?? "--"
        let humidity = sensor?.humidity.map { String(format: "%.0f%%", $0) } ?? "--"

        button.title = model.error == nil ? " \(temperature)  \(humidity)" : " offline"
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = makeMenu()
            menu.items.first?.title = window?.isVisible == true ? "Hide panel" : "Show panel"
            statusItem?.menu = menu
            sender.performClick(nil)
            statusItem?.menu = nil
        } else {
            togglePanel()
        }
    }

    // --- start with the Mac ---

    // on by default: the first start from the installed app registers it
    // as a login item (System Settings → General → Login Items)
    private func enableLoginItemOnFirstRun() {
        guard !UserDefaults.standard.bool(forKey: Self.loginConfiguredKey),
              !CommandLine.arguments.contains("--snapshot") else { return }

        try? SMAppService.mainApp.register()
        UserDefaults.standard.set(true, forKey: Self.loginConfiguredKey)
    }

    @objc private func toggleLoginItem() {
        if SMAppService.mainApp.status == .enabled {
            try? SMAppService.mainApp.unregister()
        } else {
            try? SMAppService.mainApp.register()
        }
    }

    @objc private func togglePanel() {
        setPanelVisible(window?.isVisible != true)
    }

    private func setPanelVisible(_ visible: Bool) {
        if visible {
            window?.orderFront(nil)
        } else {
            window?.orderOut(nil)
        }
        UserDefaults.standard.set(!visible, forKey: Self.hiddenKey)
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
