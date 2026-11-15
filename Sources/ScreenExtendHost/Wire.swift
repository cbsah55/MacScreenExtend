// Wire protocol shared by the Mac host and the device app.
// KEEP IN SYNC: Sources/ScreenExtendHost/Wire.swift and ios/ScreenExtend/Wire.swift
//
// The device listens and advertises itself with Bonjour; the Mac finds it and connects,
// over Wi-Fi (Bonjour) or through the USB cable (usbmuxd tunnel to the same port).
// Every message is: 1 byte type, 4 bytes big-endian payload length, payload.
import Foundation
import Network

enum MessageType: UInt8 {
    case hello = 1        // device -> Mac, JSON `Hello`
    case videoFormat = 2  // Mac -> device, H.264 SPS and PPS, each prefixed by a 2-byte length
    case videoFrame = 3   // Mac -> device, one H.264 frame in AVCC form (4-byte NAL lengths)
    case ping = 4         // both ways, once a second; silence means the other side is gone
}

struct Hello: Codable {
    var id: String        // stable per device install; also used as the Bonjour service name
    var name: String
    var pixelWidth: Int
    var pixelHeight: Int
}

enum Wire {
    static let bonjourType = "_screenextend._tcp"
    /// The device listens on this fixed port so the Mac can also reach it through the USB cable.
    static let port: UInt16 = 47990
    /// A connection that has been silent this long is treated as dead.
    static let silenceLimit: TimeInterval = 5

    static func parameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 2
        tcp.keepaliveInterval = 2
        tcp.keepaliveCount = 2
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.includePeerToPeer = true
        parameters.allowLocalEndpointReuse = true
        return parameters
    }

    static func send(_ type: MessageType, _ payload: Data, on connection: NWConnection,
                     completion: (() -> Void)? = nil) {
        var message = Data(capacity: payload.count + 5)
        message.append(type.rawValue)
        withUnsafeBytes(of: UInt32(payload.count).bigEndian) { message.append(contentsOf: $0) }
        message.append(payload)
        connection.send(content: message, completion: .contentProcessed { _ in completion?() })
    }

    /// Reads messages until the connection closes, then calls `onClose` once.
    static func receive(on connection: NWConnection,
                        handler: @escaping (MessageType, Data) -> Void,
                        onClose: @escaping () -> Void) {
        connection.receive(minimumIncompleteLength: 5, maximumLength: 5) { header, _, _, error in
            guard let header, header.count == 5, error == nil else { onClose(); return }
            let bytes = [UInt8](header)
            let type = MessageType(rawValue: bytes[0])
            let length = Int(bytes[1]) << 24 | Int(bytes[2]) << 16 | Int(bytes[3]) << 8 | Int(bytes[4])
            guard length > 0 else {
                receive(on: connection, handler: handler, onClose: onClose)
                return
            }
            connection.receive(minimumIncompleteLength: length, maximumLength: length) { body, _, _, error in
                guard let body, body.count == length, error == nil else { onClose(); return }
                if let type { handler(type, body) }
                receive(on: connection, handler: handler, onClose: onClose)
            }
        }
    }
}
