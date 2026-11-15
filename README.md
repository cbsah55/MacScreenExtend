# MacScreenExtend

Use spare devices (iPhone, iPad, another Mac, later Android) as extra displays for a Mac.

Free and open source under the [MIT License](LICENSE). Early stage: it works, but expect rough edges.

## Status

Working end to end on an iPhone 15 Pro Max (macOS 26.6, iOS 26.6):

- The Mac host finds the device app automatically, by cable or on the same Wi-Fi.
- It creates a Retina virtual display matching the device and streams it (H.264, 60 fps).
- Cable is preferred (40 Mbit/s); unplugging falls back to Wi-Fi (20 Mbit/s) and keeps the display.
- The menu bar item shows live status and the connection type.

Not started: touch input, portrait, Mac/Android clients, packaged Mac app with launch at login.

## Build and run

```
swift build
.build/debug/ScreenExtendHost                    # menu bar app: add / remove virtual displays
.build/debug/ScreenExtendHost --selftest 3       # create preset 3 briefly and report the result
.build/debug/ScreenExtendHost --selftest --modes 1398 645   # custom size, list offered modes
```

## Findings on macOS 26.6.2 (Apple Silicon)

- `CGVirtualDisplay` (private CoreGraphics API) works without special entitlements.
- Working HiDPI sizes: 1920x1080, 1366x1024, 1398x645.
- 932x430 HiDPI is listed by macOS but cannot be selected (error 1001); macOS falls back to
  1344x620 non-Retina. The smallest size that works is not yet known.
- macOS remembers settings per vendor/product ID, so each display size uses its own product ID.
- A display created within a few seconds of another being removed can inherit the old
  display's mode. Keep a display alive across short disconnects instead of recreating it.

## iPhone / iPad app

Requires the iOS platform in Xcode (Xcode > Settings > Components, or `xcodebuild -downloadPlatform iOS`).

Set your Apple Developer Team ID once (a free Apple ID works for your own devices):

```
echo 'DEVELOPMENT_TEAM = YOURTEAMID' > ios/Local.xcconfig
```

`ios/Local.xcconfig` is ignored by git; `ios/Signing.xcconfig` explains the options. If you sign
with your own team, also change `PRODUCT_BUNDLE_IDENTIFIER` in `ios/Signing.xcconfig`.

```
cd ios
xcodebuild -project ScreenExtend.xcodeproj -scheme ScreenExtend \
  -destination 'generic/platform=iOS' -derivedDataPath build -allowProvisioningUpdates build
xcrun devicectl device install app --device <device-id> build/Build/Products/Debug-iphoneos/ScreenExtend.app
```

Or open `ios/ScreenExtend.xcodeproj` in Xcode, pick the iPhone and press Run.

## How a connection works

1. The device app listens on TCP port 47990 and advertises `_screenextend._tcp` with Bonjour.
2. The Mac host connects: through the cable via `usbmuxd` if plugged in, otherwise over Wi-Fi.
3. The device sends its name and pixel size; the Mac creates a matching virtual display.
4. The Mac sends H.264 parameter sets and frames; the device shows them as they arrive.
5. Both sides ping every second; 5 seconds of silence ends the connection and it reconnects.

The Mac needs Screen Recording permission (and Local Network access). When run from Terminal,
macOS asks for these on behalf of Terminal.

## Layout

- `Sources/CGVirtualDisplayPrivate` - header declaring the private API
- `Sources/ScreenExtendHost` - Mac menu bar app: `VirtualDisplay`, `DeviceManager`, `DeviceSession`, `USBMux`, `ScreenStreamer`
- `ios/ScreenExtend` - device app: `Receiver` (network + decode), `ContentView`
- `Wire.swift` exists in both apps and must stay identical

## Caveats

- `CGVirtualDisplay` is a private macOS API. A macOS update can break it at any time, and it
  keeps the Mac app out of the Mac App Store. Screen capture and streaming use public APIs.
- The connection is not encrypted yet. Use it on a network you trust, or over the cable.

## Contributing

Issues and pull requests are welcome. Good places to start are the items under "Not started"
in Status above. Keep `Wire.swift` identical in both apps, and say in the pull request which
Mac, device and OS versions you tested on.

## Related projects

- [OpenDisplay](https://github.com/peetzweg/opendisplay) - a more complete open-source
  (GPL-3.0) app for the same job, with touch, portrait, HEVC and more receivers.
  This project shares no code with it.

## License

[MIT](LICENSE)
