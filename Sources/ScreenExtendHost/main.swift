import AppKit

/// True when running as ScreenExtend.app rather than as a bare binary from Terminal.
let runningAsApp = Bundle.main.bundleURL.pathExtension == "app"

// An app launched from Finder or at login has nowhere to print, so keep a log file.
if runningAsApp {
    let logs = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs")
    try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
    freopen(logs.appendingPathComponent("ScreenExtend.log").path, "w", stdout)
}
setvbuf(stdout, nil, _IONBF, 0)   // show log lines immediately, even when piped to a file

// `--selftest`: create one virtual display for two seconds, report whether
// macOS accepted it, then exit. Used to check the private API on this macOS.
if CommandLine.arguments.contains("--selftest") {
    // Usage: --selftest [presetIndex]   or   --selftest <width> <height>
    let numbers = CommandLine.arguments.compactMap { Int($0) }
    let preset: DisplayPreset
    if numbers.count >= 2 {
        preset = DisplayPreset(name: "custom", width: numbers[0], height: numbers[1])
    } else {
        preset = DisplayPreset.all[min(numbers.first ?? 0, DisplayPreset.all.count - 1)]
    }
    print("Testing preset: \(preset.name) \(preset.width)x\(preset.height)")
    guard let display = VirtualDisplay(preset: preset, serial: UInt32(ProcessInfo.processInfo.environment["SE_SERIAL"] ?? "") ?? UInt32(preset.width * 10000 + preset.height)) else {
        print("FAIL: macOS refused to create the virtual display")
        exit(1)
    }
    for _ in 0..<10 where !display.isOnline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
    }
    let modeSet = display.selectPreferredMode()
    RunLoop.main.run(until: Date().addingTimeInterval(0.5))
    print("Preferred mode applied: \(modeSet)")
    if CommandLine.arguments.contains("--modes"),
       let modes = CGDisplayCopyAllDisplayModes(display.displayID,
           [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary) as? [CGDisplayMode] {
        print("Modes: " + modes.map { "\($0.width)x\($0.height)@\($0.pixelWidth / max($0.width, 1))x" }.joined(separator: " "))
    }
    var n: UInt32 = 0
    var ids = [CGDirectDisplayID](repeating: 0, count: 16)
    CGGetOnlineDisplayList(16, &ids, &n)
    print("Online displays: \(Array(ids.prefix(Int(n))))")
    let bounds = CGDisplayBounds(display.displayID)
    var pixels = "\(CGDisplayPixelsWide(display.displayID))x\(CGDisplayPixelsHigh(display.displayID))"
    if let mode = CGDisplayCopyDisplayMode(display.displayID) {
        pixels = "\(mode.width)x\(mode.height)"
        pixels += " (backing \(mode.pixelWidth)x\(mode.pixelHeight))"
    }
    if display.isOnline {
        print("OK: display \(display.displayID) online, \(pixels) points at \(bounds.origin)")
        exit(0)
    } else {
        print("FAIL: display \(display.displayID) was created but is not online")
        exit(1)
    }
}

// `--icon-preview <folder>`: write enlarged PNGs of the menu bar icons, for checking the design.
if let index = CommandLine.arguments.firstIndex(of: "--icon-preview"), CommandLine.arguments.count > index + 1 {
    let folder = URL(fileURLWithPath: CommandLine.arguments[index + 1])
    for (name, symbol) in [("usb", "cable.connector"), ("wifi", "wifi")] {
        let icon = AppDelegate.screenIcon(containing: symbol, description: name)
        let scale = 10.0
        let pixels = NSSize(width: icon.size.width * scale, height: icon.size.height * scale)
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(pixels.width),
                                            pixelsHigh: Int(pixels.height), bitsPerSample: 8,
                                            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { continue }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor.white.setFill()
        NSRect(origin: .zero, size: pixels).fill()
        icon.draw(in: NSRect(origin: .zero, size: pixels))
        NSGraphicsContext.restoreGraphicsState()
        try? bitmap.representation(using: .png, properties: [:])?
            .write(to: folder.appendingPathComponent("icon-\(name).png"))
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
app.run()
