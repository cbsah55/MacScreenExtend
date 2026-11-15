import CGVirtualDisplayPrivate
import CoreGraphics
import Foundation

/// Size of a virtual display, in points. The backing store is 2x (HiDPI).
struct DisplayPreset {
    let name: String
    let width: Int
    let height: Int

    /// Physical size reported to macOS. macOS silently refuses displays whose
    /// pixel density is too high (found by testing on macOS 26.6: ~265 ppi works,
    /// ~305 ppi does not), so report a size that gives a safe 220 ppi regardless
    /// of the real device. This value is only a label; it does not affect the image.
    var sizeInMillimeters: CGSize {
        let mmPerPixel = 25.4 / 220.0
        return CGSize(width: (Double(width * 2) * mmPerPixel).rounded(),
                      height: (Double(height * 2) * mmPerPixel).rounded())
    }

    static let all: [DisplayPreset] = [
        // Backing store 2796x1290 = native pixels of a 6.7" iPhone. macOS 26.6 refuses
        // to switch to smaller HiDPI modes such as 932x430 (error 1001).
        DisplayPreset(name: "iPhone landscape", width: 1398, height: 645),
        DisplayPreset(name: "iPhone portrait", width: 645, height: 1398),
        DisplayPreset(name: "iPad landscape", width: 1366, height: 1024),
        DisplayPreset(name: "1080p", width: 1920, height: 1080),
    ]
}

/// One virtual monitor. It exists for as long as this object is alive.
final class VirtualDisplay {
    let preset: DisplayPreset
    private let display: CGVirtualDisplay

    var displayID: CGDirectDisplayID { display.displayID }

    init?(preset: DisplayPreset, serial: UInt32) {
        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.setDispatchQueue(DispatchQueue.main)
        descriptor.name = "ScreenExtend \(preset.name)"
        descriptor.maxPixelsWide = UInt32(preset.width * 2)
        descriptor.maxPixelsHigh = UInt32(preset.height * 2)
        descriptor.sizeInMillimeters = preset.sizeInMillimeters
        descriptor.vendorID = 0x5345    // "SE"
        // macOS remembers display settings per vendor/product identity. Reusing one
        // identity for different sizes makes it apply a stale mode (or keep the
        // display offline), so every size gets its own product ID.
        descriptor.productID = UInt32((preset.width * 31 + preset.height) & 0xFFFF)
        descriptor.serialNum = serial

        guard let display = CGVirtualDisplay(descriptor: descriptor) else { return nil }

        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = 1
        settings.modes = [
            CGVirtualDisplayMode(width: UInt(preset.width), height: UInt(preset.height), refreshRate: 60)
        ]
        guard display.apply(settings) else { return nil }

        self.preset = preset
        self.display = display
    }

    /// Switch to the intended HiDPI mode. macOS adds scaled modes of its own and may
    /// pick one of those by default. Call once the display is online.
    @discardableResult
    func selectPreferredMode() -> Bool {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode],
              let wanted = modes
                  .filter({ $0.width == preset.width && $0.height == preset.height && $0.pixelWidth > $0.width })
                  .max(by: { $0.pixelWidth < $1.pixelWidth })
        else { print("ScreenExtend: HiDPI mode \(preset.width)x\(preset.height) not offered"); return false }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { print("ScreenExtend: could not begin display configuration"); return false }
        guard CGConfigureDisplayWithDisplayMode(config, displayID, wanted, nil) == .success else {
            CGCancelDisplayConfiguration(config)
            print("ScreenExtend: mode rejected for display \(displayID)")
            return false
        }
        let result = CGCompleteDisplayConfiguration(config, .forSession)
        if result != .success { print("ScreenExtend: mode switch failed (\(result.rawValue))") }
        return result == .success
    }

    /// True once macOS lists this display alongside the real ones.
    var isOnline: Bool {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        return ids.prefix(Int(count)).contains(displayID)
    }
}
