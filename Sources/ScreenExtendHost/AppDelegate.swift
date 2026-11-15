import AppKit
import ServiceManagement

/// Menu bar item that adds and removes virtual displays.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var displays: [VirtualDisplay] = []
    private var nextSerial: UInt32 = 1
    private let devices = DeviceManager()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "rectangle.on.rectangle",
                                           accessibilityDescription: "Screen Extend")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        // Asks once and adds ScreenExtend to the Screen Recording list in System Settings.
        if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }

        // Start at Login is off unless the user turns it on in the menu. An earlier build
        // enabled it by itself; undo that if the user never asked for it.
        if runningAsApp, SMAppService.mainApp.status == .enabled,
           !UserDefaults.standard.bool(forKey: "startAtLoginChosenByUser") {
            try? SMAppService.mainApp.unregister()
        }
        print("ScreenExtend: started (screen recording allowed: \(CGPreflightScreenCaptureAccess()), "
              + "start at login: \(SMAppService.mainApp.status == .enabled))")

        devices.start()

        // Keep the menu bar item, and the menu while it is open, in step with the devices.
        // `.common` makes the timer fire even while the menu is being shown.
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(timer, forMode: .common)
        refresh()
    }

    private var lastSummary = ""

    private func refresh() {
        let sessions = devices.sessions.values.sorted { $0.deviceName < $1.deviceName }
        let summary = sessions.map { "\($0.deviceName): \($0.status)" }.joined(separator: "\n")
        guard summary != lastSummary else { return }
        lastSummary = summary

        // Menu bar: plain icon when idle; while streaming, a screen outline with a small
        // cable or Wi-Fi sign inside it. No text.
        let streaming = sessions.filter { $0.status.hasPrefix("Streaming") }
        statusItem.button?.title = ""
        if streaming.isEmpty {
            statusItem.button?.image = NSImage(systemSymbolName: "rectangle.on.rectangle",
                                               accessibilityDescription: "ScreenExtend, no device")
        } else {
            let onCable = streaming.contains { $0.transport == .usb }
            statusItem.button?.image = Self.screenIcon(
                containing: onCable ? "cable.connector" : "wifi",
                description: onCable ? "ScreenExtend, connected by cable" : "ScreenExtend, connected by Wi-Fi")
        }

        if let menu = statusItem.menu { menuNeedsUpdate(menu) }   // live update if it is open
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let sessions = devices.sessions.values.sorted { $0.deviceName < $1.deviceName }
        if sessions.isEmpty {
            menu.addItem(disabled("Waiting for devices… open ScreenExtend on a device"))
        } else {
            for session in sessions {
                menu.addItem(disabled("\(session.deviceName): \(session.status)"))
            }
        }
        if !CGPreflightScreenCaptureAccess() {
            let item = NSMenuItem(title: "⚠️ Allow Screen Recording, then quit and reopen…",
                                  action: #selector(openScreenRecordingSettings), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        if runningAsApp {
            let login = NSMenuItem(title: "Start at Login", action: #selector(toggleStartAtLogin), keyEquivalent: "")
            login.target = self
            login.state = SMAppService.mainApp.status == .enabled ? .on : .off
            menu.addItem(login)
        }
        menu.addItem(.separator())
        menu.addItem(disabled("Test displays (no device needed)"))

        for (index, preset) in DisplayPreset.all.enumerated() {
            let item = NSMenuItem(title: "Add \(preset.name) (\(preset.width)×\(preset.height))",
                                  action: #selector(addDisplay(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            menu.addItem(item)
        }

        if !displays.isEmpty {
            menu.addItem(.separator())
            for (index, display) in displays.enumerated() {
                let item = NSMenuItem(title: "Remove \(display.preset.name) (ID \(display.displayID))",
                                      action: #selector(removeDisplay(_:)), keyEquivalent: "")
                item.target = self
                item.tag = index
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Open Display Settings…",
                                  action: #selector(openDisplaySettings), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
    }

    @objc private func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func toggleStartAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
                UserDefaults.standard.set(false, forKey: "startAtLoginChosenByUser")
            } else {
                try SMAppService.mainApp.register()
                UserDefaults.standard.set(true, forKey: "startAtLoginChosenByUser")
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not change the Start at Login setting"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    /// Two overlapping solid screens with a small symbol cut out of the front one.
    /// A template image, so it follows the menu bar's light or dark appearance.
    static func screenIcon(containing symbolName: String, description: String) -> NSImage {
        let size = NSSize(width: 25, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            guard let context = NSGraphicsContext.current else { return false }
            let back = NSRect(x: 8, y: 6.5, width: 16, height: 10.5)
            let front = NSRect(x: 1, y: 1, width: 17.5, height: 12)

            NSColor.black.setFill()
            NSBezierPath(roundedRect: back, xRadius: 2.5, yRadius: 2.5).fill()

            // Clear a thin gap around the front screen so the two read as separate shapes.
            context.compositingOperation = .destinationOut
            NSBezierPath(roundedRect: front.insetBy(dx: -1.5, dy: -1.5), xRadius: 4, yRadius: 4).fill()
            context.compositingOperation = .sourceOver
            NSBezierPath(roundedRect: front, xRadius: 2.5, yRadius: 2.5).fill()

            // Punch the symbol out of the front screen.
            let configuration = NSImage.SymbolConfiguration(pointSize: 8, weight: .heavy)
            if let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration) {
                let origin = NSPoint(x: front.midX - symbol.size.width / 2,
                                     y: front.midY - symbol.size.height / 2)
                symbol.draw(in: NSRect(origin: origin, size: symbol.size), from: .zero,
                            operation: .destinationOut, fraction: 1)
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = description
        return image
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc private func addDisplay(_ sender: NSMenuItem) {
        let preset = DisplayPreset.all[sender.tag]
        guard let display = VirtualDisplay(preset: preset, serial: nextSerial) else {
            let alert = NSAlert()
            alert.messageText = "Could not create the virtual display"
            alert.informativeText = "macOS refused the request. The private display API may have changed in this macOS version."
            alert.runModal()
            return
        }
        nextSerial += 1
        displays.append(display)
        // The display takes a moment to come online; then force the intended mode.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak display] in
            display?.selectPreferredMode()
        }
    }

    @objc private func removeDisplay(_ sender: NSMenuItem) {
        guard displays.indices.contains(sender.tag) else { return }
        displays.remove(at: sender.tag)   // releasing the object removes the monitor
    }

    @objc private func openDisplaySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}
