import AVFoundation
import Network
import UIKit

/// Waits for the Mac to connect, then decodes and shows the video it sends.
final class Receiver: ObservableObject {
    @Published var status = "Starting…"
    @Published var isStreaming = false

    let displayLayer: AVSampleBufferDisplayLayer = {
        let layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resizeAspect
        return layer
    }()

    private let queue = DispatchQueue(label: "screenextend.receiver", qos: .userInteractive)
    private var listener: NWListener?
    private var connection: NWConnection?
    private var format: CMVideoFormatDescription?
    private var formatData: Data?
    private var lastHeard = Date()
    private var heartbeat: DispatchSourceTimer?
    private var resumedFromBackground = false

    /// Call when the app leaves the foreground; the next `start()` then rebuilds the listener,
    /// because iOS may have closed it while the app was suspended.
    func didEnterBackground() {
        queue.async { self.resumedFromBackground = true }
    }
    private var hello = Hello(id: Receiver.deviceIdentifier, name: "Device", pixelWidth: 0, pixelHeight: 0)

    /// Created once per install; lets the Mac recognise this device over both cable and Wi-Fi.
    private static let deviceIdentifier: String = {
        let key = "deviceIdentifier"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let created = UUID().uuidString
        UserDefaults.standard.set(created, forKey: key)
        return created
    }()

    /// Safe to call repeatedly; restarts listening if it had stopped.
    func start() {
        // Always report landscape: the app is landscape-only for now.
        let native = UIScreen.main.nativeBounds.size
        hello = Hello(id: Receiver.deviceIdentifier, name: UIDevice.current.name,
                      pixelWidth: Int(max(native.width, native.height)),
                      pixelHeight: Int(min(native.width, native.height)))
        queue.async {
            // Returning from the background: sockets may be dead without any error having
            // been reported. If there is no working connection, start listening afresh.
            if self.connection != nil, Date().timeIntervalSince(self.lastHeard) <= Wire.silenceLimit {
                return
            }
            if self.connection == nil, self.listener != nil, !self.resumedFromBackground {
                self.startHeartbeat()
                return   // already listening (e.g. called twice at launch)
            }
            self.resumedFromBackground = false
            self.connection?.cancel()
            self.connection = nil
            self.listener?.cancel()
            self.listener = nil
            self.startListener()
            self.startHeartbeat()
        }
    }

    /// Once a second: tell the Mac we are alive, and drop the Mac if it has gone quiet.
    private func startHeartbeat() {
        guard heartbeat == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self, let connection = self.connection, connection.state == .ready else { return }
            if Date().timeIntervalSince(self.lastHeard) > Wire.silenceLimit {
                connection.cancel()
                self.disconnected()
            } else {
                Wire.send(.ping, Data([0]), on: connection)
            }
        }
        timer.resume()
        heartbeat = timer
    }

    private func startListener() {
        do {
            let listener = try NWListener(using: Wire.parameters(), on: NWEndpoint.Port(rawValue: Wire.port)!)
            listener.service = NWListener.Service(name: hello.id, type: Wire.bonjourType)
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self, let listener, listener === self.listener else { return }
                switch state {
                case .ready:
                    self.publish("Waiting for your Mac…\nMake sure ScreenExtend is running on it.\nPlug in the cable or join the same Wi-Fi.")
                case .failed, .cancelled:
                    self.listener = nil
                    self.queue.asyncAfter(deadline: .now() + 1) {
                        if self.listener == nil { self.startListener() }
                    }
                case .waiting:
                    self.publish("Allow Local Network access for ScreenExtend in Settings.")
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            publish("Could not start listening: \(error.localizedDescription)")
        }
    }

    private func accept(_ newConnection: NWConnection) {
        connection?.cancel()   // one Mac at a time; the newest wins
        connection = newConnection
        format = nil
        formatData = nil
        lastHeard = Date()

        newConnection.stateUpdateHandler = { [weak self, weak newConnection] state in
            guard let self, let newConnection, newConnection === self.connection else { return }
            switch state {
            case .ready:
                self.publish("Connected. Starting display…")
                if let payload = try? JSONEncoder().encode(self.hello) {
                    Wire.send(.hello, payload, on: newConnection)
                }
            case .failed, .cancelled:
                self.disconnected()
            default:
                break
            }
        }
        Wire.receive(on: newConnection, handler: { [weak self] type, payload in
            self?.lastHeard = Date()
            switch type {
            case .videoFormat: self?.setFormat(payload)
            case .videoFrame: self?.show(payload)
            case .hello, .ping: break
            }
        }, onClose: { [weak self, weak newConnection] in
            guard let self, let newConnection, newConnection === self.connection else { return }
            newConnection.cancel()
            self.disconnected()
        })
        newConnection.start(queue: queue)
    }

    private func disconnected() {
        connection = nil
        displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
        publish("Disconnected. Waiting for your Mac…", streaming: false)
    }

    private func publish(_ status: String, streaming: Bool? = nil) {
        DispatchQueue.main.async {
            self.status = status
            if let streaming { self.isStreaming = streaming }
        }
    }

    // MARK: Video

    private func setFormat(_ data: Data) {
        guard data != formatData else { return }   // repeated with every keyframe
        let bytes = [UInt8](data)
        var sets: [[UInt8]] = []
        var offset = 0
        while offset + 2 <= bytes.count {
            let size = Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
            offset += 2
            guard offset + size <= bytes.count else { return }
            sets.append(Array(bytes[offset..<offset + size]))
            offset += size
        }
        guard sets.count == 2 else { return }

        var description: CMVideoFormatDescription?
        let status = sets[0].withUnsafeBufferPointer { sps in
            sets[1].withUnsafeBufferPointer { pps in
                let pointers = [sps.baseAddress!, pps.baseAddress!]
                let sizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: 2,
                    parameterSetPointers: pointers, parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4, formatDescriptionOut: &description)
            }
        }
        guard status == noErr, let description else { return }
        format = description
        formatData = data
    }

    private func show(_ data: Data) {
        guard let format else { return }

        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: data.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: data.count, flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &block) == kCMBlockBufferNoErr, let block else { return }
        let copied = data.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: block,
                                          offsetIntoDestination: 0, dataLength: data.count)
        }
        guard copied == kCMBlockBufferNoErr else { return }

        var sample: CMSampleBuffer?
        var size = data.count
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
            sampleSizeEntryCount: 1, sampleSizeArray: &size,
            sampleBufferOut: &sample) == noErr, let sample else { return }

        // Show each frame as soon as it is decoded instead of following a clock.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let first = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(first,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }

        let renderer = displayLayer.sampleBufferRenderer
        if renderer.status == .failed { renderer.flush() }
        renderer.enqueue(sample)
        publishStreamingOnce()
    }

    private func publishStreamingOnce() {
        DispatchQueue.main.async {
            if !self.isStreaming { self.isStreaming = true }
        }
    }
}
