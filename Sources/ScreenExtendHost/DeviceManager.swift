import Foundation
import Network

/// Finds devices running the ScreenExtend app, by cable and on the local network, and
/// keeps exactly one session per device. A cable connection is preferred over Wi-Fi.
final class DeviceManager {
    /// Keyed by "usb:<usbmuxd device number>" or "wifi:<device id>".
    private(set) var sessions: [String: DeviceSession] = [:]

    private var wifiEndpoints: [String: NWEndpoint] = [:]   // device id -> endpoint
    private var browser: NWBrowser?
    private let usb = USBMuxListener()
    private var usbConnecting: Set<Int> = []
    private var retryTimer: Timer?
    private var tick = 0

    func start() {
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: Wire.bonjourType, domain: nil), using: parameters)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            var endpoints: [String: NWEndpoint] = [:]
            for result in results {
                if case let .service(name, _, _, _) = result.endpoint { endpoints[name] = result.endpoint }
            }
            self?.wifiEndpoints = endpoints
            self?.reconcile()
        }
        browser.start(queue: .main)
        self.browser = browser

        usb.onChange = { [weak self] in self?.reconcile() }
        usb.start()

        // Covers a device app opened after the cable was plugged in, and dropped connections.
        retryTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            for session in Array(self.sessions.values) { session.heartbeat() }
            self.tick += 1
            if self.tick % 3 == 0 { self.reconcile() }
        }
    }

    private func reconcile() {
        connectUSBDevices()
        connectWiFiDevices()
    }

    private func connectUSBDevices() {
        for deviceID in usb.devices.keys {
            let key = "usb:\(deviceID)"
            guard sessions[key] == nil, !usbConnecting.contains(deviceID) else { continue }
            usbConnecting.insert(deviceID)
            USBMux.connect(deviceID: deviceID, port: Wire.port) { [weak self] connection in
                guard let self else { connection?.cancel(); return }
                self.usbConnecting.remove(deviceID)
                if let connection {
                    self.add(DeviceSession(connection: connection, transport: .usb, alreadyStarted: true), key: key)
                } else {
                    self.connectWiFiDevices()   // app not open on that device, or no cable path
                }
            }
        }
    }

    private func connectWiFiDevices() {
        // While a cable connection is being set up we do not yet know which device it is.
        // Connecting over Wi-Fi at the same moment would make the two fight over the device.
        let usbSessions = sessions.values.filter { $0.transport == .usb }
        guard usbConnecting.isEmpty, usbSessions.allSatisfy({ $0.deviceIdentifier != nil }) else { return }
        let onCable = Set(usbSessions.compactMap(\.deviceIdentifier))

        for (deviceIdentifier, endpoint) in wifiEndpoints {
            let key = "wifi:\(deviceIdentifier)"
            guard sessions[key] == nil, !onCable.contains(deviceIdentifier) else { continue }
            let connection = NWConnection(to: endpoint, using: Wire.parameters())
            add(DeviceSession(connection: connection, transport: .wifi, alreadyStarted: false), key: key)
        }
    }

    private func add(_ session: DeviceSession, key: String) {
        sessions[key] = session
        session.onEnd = { [weak self] in
            self?.sessions[key] = nil
            // e.g. cable unplugged: fall back to Wi-Fi quickly.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self?.reconcile() }
        }
        session.shouldBegin = { [weak self, weak session] deviceIdentifier in
            guard let self, let session else { return false }
            for other in Array(self.sessions.values)
            where other !== session && other.deviceIdentifier == deviceIdentifier {
                if session.transport == .wifi && other.transport == .usb { return false }   // cable wins
                other.end()   // parks its display so this session can take it over
            }
            return true
        }
        session.start()
    }
}
