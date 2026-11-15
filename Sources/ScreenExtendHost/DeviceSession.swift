import AppKit
import Network

/// One connected device: its network connection, its virtual display and its video stream.
final class DeviceSession {
    enum Transport: String { case usb = "USB", wifi = "Wi-Fi" }

    let transport: Transport
    /// The device's stable id, known once it has introduced itself.
    private(set) var deviceIdentifier: String?
    /// Asked before a display is created; return false to refuse this connection.
    var shouldBegin: ((String) -> Bool)?
    private(set) var deviceName = "Device"
    private(set) var status = "Connecting" {
        didSet { print("ScreenExtend: [\(deviceName) via \(transport.rawValue)] \(status)") }
    }
    var onEnd: (() -> Void)?

    private let connection: NWConnection
    private var display: VirtualDisplay?
    private var displayKey: String?
    private let streamer = ScreenStreamer()
    private var ended = false
    private let alreadyStarted: Bool
    private var lastHeard = Date()

    // Frames handed to the network but not yet sent; used to drop frames when Wi-Fi is behind.
    private let lock = NSLock()
    private var pendingFrames = 0

    /// `alreadyStarted` is true for a USB tunnel, which is handed over open and ready.
    init(connection: NWConnection, transport: Transport, alreadyStarted: Bool) {
        self.connection = connection
        self.transport = transport
        self.alreadyStarted = alreadyStarted
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled, .waiting: self?.end()
            default: break
            }
        }
        Wire.receive(on: connection, handler: { [weak self] type, payload in
            self?.lastHeard = Date()
            if type == .hello, let hello = try? JSONDecoder().decode(Hello.self, from: payload) {
                self?.begin(hello)
            }
        }, onClose: { [weak self] in self?.end() })
        if !alreadyStarted { connection.start(queue: .main) }
    }

    private func begin(_ hello: Hello) {
        guard display == nil, !ended else { return }
        deviceName = hello.name
        deviceIdentifier = hello.id
        guard shouldBegin?(hello.id) ?? true else { end(); return }
        status = "Creating display"

        // Points are half the device's pixels, so the stream is pixel-exact (Retina).
        let preset = DisplayPreset(name: hello.name, width: hello.pixelWidth / 2, height: hello.pixelHeight / 2)
        let key = "\(hello.id)|\(preset.width)x\(preset.height)"
        let serial = hello.id.utf8.reduce(UInt32(5381)) { ($0 &* 33) &+ UInt32($1) }
        guard let display = DisplayPool.take(key) ?? VirtualDisplay(preset: preset, serial: serial) else {
            status = "macOS refused to create the display"
            return
        }
        self.display = display
        displayKey = key
        waitUntilOnline(display, attemptsLeft: 20) { [weak self] in
            self?.startStreaming(display, hello: hello)
        }
    }

    private func waitUntilOnline(_ display: VirtualDisplay, attemptsLeft: Int, then: @escaping () -> Void) {
        if display.isOnline || attemptsLeft == 0 {
            display.selectPreferredMode()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: then)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.waitUntilOnline(display, attemptsLeft: attemptsLeft - 1, then: then)
            }
        }
    }

    private func startStreaming(_ display: VirtualDisplay, hello: Hello) {
        guard !ended else { return }
        streamer.onFormat = { [weak self] data in
            guard let self else { return }
            Wire.send(.videoFormat, data, on: self.connection)
        }
        streamer.onFrame = { [weak self] data in
            guard let self else { return }
            self.lock.lock(); self.pendingFrames += 1; self.lock.unlock()
            Wire.send(.videoFrame, data, on: self.connection) { [weak self] in
                guard let self else { return }
                self.lock.lock(); self.pendingFrames -= 1; self.lock.unlock()
            }
        }
        streamer.shouldSkipFrame = { [weak self] in
            guard let self else { return true }
            self.lock.lock(); defer { self.lock.unlock() }
            return self.pendingFrames > 4
        }
        streamer.onStopped = { [weak self] _ in
            DispatchQueue.main.async { self?.status = "Capture stopped" }
        }

        status = "Starting stream"
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.streamer.start(displayID: display.displayID,
                                              pixelWidth: hello.pixelWidth, pixelHeight: hello.pixelHeight,
                                              bitRate: self.transport == .usb ? 40_000_000 : 20_000_000)
                // The session can end while capture is starting (e.g. the cable took over
                // from Wi-Fi). Do not leave a capture running for a connection that is gone.
                if self.ended {
                    self.streamer.stop()
                    return
                }
                self.status = "Streaming \(hello.pixelWidth)×\(hello.pixelHeight) over \(self.transport.rawValue)"
            } catch {
                // Most often: Screen Recording permission has not been granted yet.
                self.status = "Cannot capture: \(error.localizedDescription)"
                print("ScreenExtend: capture failed for \(hello.name): \(error)")
            }
        }
    }

    /// Called once a second: tells the device we are alive and drops it if it has gone quiet
    /// (app backgrounded, phone locked, out of range). Without this a dead Wi-Fi connection
    /// can look healthy for a long time and block reconnecting.
    func heartbeat() {
        guard !ended else { return }
        if Date().timeIntervalSince(lastHeard) > Wire.silenceLimit {
            status = "Device stopped responding"
            end()
        } else {
            Wire.send(.ping, Data([0]), on: connection)
        }
    }

    func end() {
        guard !ended else { return }
        ended = true
        print("ScreenExtend: [\(deviceName) via \(transport.rawValue)] session ended")
        streamer.stop()
        if let display, let displayKey { DisplayPool.park(display, key: displayKey) }
        display = nil
        connection.cancel()
        onEnd?()
    }
}

/// Keeps a virtual display alive briefly after its device disconnects. Recreating a
/// display seconds after removing one makes macOS apply stale settings, and it would
/// also shuffle the user's windows on every short Wi-Fi drop.
enum DisplayPool {
    private static var parked: [String: (display: VirtualDisplay, expiry: DispatchWorkItem)] = [:]

    static func park(_ display: VirtualDisplay, key: String) {
        let expiry = DispatchWorkItem { parked[key] = nil }
        parked[key]?.expiry.cancel()
        parked[key] = (display, expiry)
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: expiry)
    }

    static func take(_ key: String) -> VirtualDisplay? {
        guard let entry = parked.removeValue(forKey: key) else { return nil }
        entry.expiry.cancel()
        return entry.display
    }
}
