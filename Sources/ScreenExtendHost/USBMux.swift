import Foundation
import Network

/// Talks to usbmuxd, the macOS service that Xcode and Finder use to reach iPhones and
/// iPads over the cable. It can open a tunnel to a TCP port on a plugged-in device.
enum USBMux {
    static let socketPath = "/var/run/usbmuxd"

    static func makeConnection() -> NWConnection {
        NWConnection(to: .unix(path: socketPath), using: .tcp)
    }

    /// usbmuxd packet: 16-byte little-endian header (length, version 1, type 8 = plist, tag) + XML plist.
    static func packet(_ body: [String: Any], tag: UInt32) -> Data {
        var plist = body
        plist["ClientVersionString"] = "ScreenExtend"
        plist["ProgName"] = "ScreenExtend"
        let payload = (try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)) ?? Data()
        var data = Data()
        for value in [UInt32(16 + payload.count), 1, 8, tag] {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(payload)
        return data
    }

    static func readPacket(on connection: NWConnection, completion: @escaping ([String: Any]?) -> Void) {
        connection.receive(minimumIncompleteLength: 16, maximumLength: 16) { header, _, _, error in
            guard let header, header.count == 16, error == nil else { completion(nil); return }
            let bytes = [UInt8](header)
            let length = Int(bytes[0]) | Int(bytes[1]) << 8 | Int(bytes[2]) << 16 | Int(bytes[3]) << 24
            let bodyLength = length - 16
            guard bodyLength > 0 else { completion([:]); return }
            connection.receive(minimumIncompleteLength: bodyLength, maximumLength: bodyLength) { body, _, _, error in
                guard let body, error == nil,
                      let plist = try? PropertyListSerialization.propertyList(from: body, format: nil) as? [String: Any]
                else { completion(nil); return }
                completion(plist)
            }
        }
    }

    /// Opens a tunnel to `port` on a plugged-in device. On success the returned connection
    /// carries raw bytes to and from the app listening on that port. Returns nil when
    /// nothing is listening (the app is not open) or the device is gone.
    static func connect(deviceID: Int, port: UInt16, completion: @escaping (NWConnection?) -> Void) {
        let connection = makeConnection()
        var finished = false
        let finish: (Bool) -> Void = { success in
            guard !finished else { return }
            finished = true
            if success {
                connection.stateUpdateHandler = nil
                completion(connection)
            } else {
                connection.stateUpdateHandler = nil
                connection.cancel()
                completion(nil)
            }
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                let networkOrderPort = Int((port << 8) | (port >> 8))   // usbmuxd expects big-endian
                let request = packet(["MessageType": "Connect", "DeviceID": deviceID,
                                      "PortNumber": networkOrderPort], tag: 2)
                connection.send(content: request, completion: .contentProcessed { _ in })
                readPacket(on: connection) { reply in
                    finish((reply?["Number"] as? Int) == 0)
                }
            case .failed, .cancelled, .waiting:
                finish(false)
            default:
                break
            }
        }
        connection.start(queue: .main)
    }
}

/// Keeps a live list of devices plugged in by cable.
final class USBMuxListener {
    /// usbmuxd device number -> serial number, cable connections only.
    private(set) var devices: [Int: String] = [:]
    var onChange: (() -> Void)?

    private var connection: NWConnection?

    func start() {
        let connection = USBMux.makeConnection()
        self.connection = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection, connection === self.connection else { return }
            switch state {
            case .ready:
                connection.send(content: USBMux.packet(["MessageType": "Listen"], tag: 1),
                                completion: .contentProcessed { _ in })
                self.readNext(connection)
            case .failed, .cancelled, .waiting:
                self.restartLater()
            default:
                break
            }
        }
        connection.start(queue: .main)
    }

    private func readNext(_ connection: NWConnection) {
        USBMux.readPacket(on: connection) { [weak self, weak connection] plist in
            guard let self, let connection, connection === self.connection else { return }
            guard let plist else { self.restartLater(); return }
            switch plist["MessageType"] as? String {
            case "Attached":
                if let id = plist["DeviceID"] as? Int,
                   let properties = plist["Properties"] as? [String: Any],
                   properties["ConnectionType"] as? String == "USB" {
                    self.devices[id] = properties["SerialNumber"] as? String ?? ""
                    self.onChange?()
                }
            case "Detached":
                if let id = plist["DeviceID"] as? Int, self.devices.removeValue(forKey: id) != nil {
                    self.onChange?()
                }
            default:
                break
            }
            self.readNext(connection)
        }
    }

    private func restartLater() {
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        if !devices.isEmpty { devices = [:]; onChange?() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            if self?.connection == nil { self?.start() }
        }
    }
}
