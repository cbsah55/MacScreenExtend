import CoreMedia
import Foundation
import ScreenCaptureKit
import VideoToolbox

enum StreamError: Error, CustomStringConvertible {
    case displayNotFound
    case encoder(OSStatus)

    var description: String {
        switch self {
        case .displayNotFound: return "macOS did not offer the virtual display for capture"
        case .encoder(let status): return "Video encoder could not start (\(status))"
        }
    }
}

/// Captures one display and turns it into a low-latency H.264 stream.
final class ScreenStreamer: NSObject, SCStreamOutput, SCStreamDelegate {
    var onFormat: ((Data) -> Void)?
    var onFrame: ((Data) -> Void)?
    /// Return true to drop a captured frame before it is encoded (network is behind).
    var shouldSkipFrame: (() -> Bool)?
    var onStopped: ((Error?) -> Void)?

    private var stream: SCStream?
    private var encoder: VTCompressionSession?
    private let queue = DispatchQueue(label: "screenextend.capture", qos: .userInteractive)

    func start(displayID: CGDirectDisplayID, pixelWidth: Int, pixelHeight: Int, bitRate: Int) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw StreamError.displayNotFound
        }

        let configuration = SCStreamConfiguration()
        configuration.width = pixelWidth
        configuration.height = pixelHeight
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        configuration.queueDepth = 3
        configuration.showsCursor = true

        try makeEncoder(width: pixelWidth, height: pixelHeight, bitRate: bitRate)

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() {
        let stream = self.stream
        self.stream = nil
        stream?.stopCapture { _ in }
        queue.async {
            if let encoder = self.encoder { VTCompressionSessionInvalidate(encoder) }
            self.encoder = nil
        }
    }

    private func makeEncoder(width: Int, height: Int, bitRate: Int) throws {
        var session: VTCompressionSession?
        let lowLatency = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: kCFBooleanTrue] as CFDictionary
        var status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(width), height: Int32(height),
            codecType: kCMVideoCodecType_H264, encoderSpecification: lowLatency,
            imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        if status != noErr {   // fall back to the standard encoder
            status = VTCompressionSessionCreate(
                allocator: nil, width: Int32(width), height: Int32(height),
                codecType: kCMVideoCodecType_H264, encoderSpecification: nil,
                imageBufferAttributes: nil, compressedDataAllocator: nil,
                outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        }
        guard status == noErr, let session else { throw StreamError.encoder(status) }

        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel,
                             value: kVTProfileLevel_H264_High_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 2 as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: 60 as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitRate as CFNumber)
        VTCompressionSessionPrepareToEncodeFrames(session)
        encoder = session
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        // Frames without an image mean "nothing changed"; nothing to send.
        guard type == .screen, sampleBuffer.isValid,
              let image = sampleBuffer.imageBuffer, let encoder else { return }
        if shouldSkipFrame?() == true { return }

        VTCompressionSessionEncodeFrame(
            encoder, imageBuffer: image,
            presentationTimeStamp: sampleBuffer.presentationTimeStamp,
            duration: .invalid, frameProperties: nil, infoFlagsOut: nil
        ) { [weak self] status, _, encoded in
            guard status == noErr, let encoded else { return }
            self?.send(encoded)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStopped?(error)
    }

    private func send(_ sample: CMSampleBuffer) {
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
            as? [[CFString: Any]]
        let isKeyframe = !((attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false)

        if isKeyframe, let format = CMSampleBufferGetFormatDescription(sample),
           let parameterSets = Self.parameterSets(from: format) {
            onFormat?(parameterSets)
        }

        guard let block = CMSampleBufferGetDataBuffer(sample) else { return }
        let length = CMBlockBufferGetDataLength(block)
        var data = Data(count: length)
        let status = data.withUnsafeMutableBytes { buffer in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: buffer.baseAddress!)
        }
        if status == kCMBlockBufferNoErr { onFrame?(data) }
    }

    /// SPS then PPS, each prefixed with a 2-byte big-endian length.
    private static func parameterSets(from format: CMFormatDescription) -> Data? {
        var result = Data()
        for index in 0..<2 {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            guard status == noErr, let pointer else { return nil }
            result.append(UInt8(size >> 8))
            result.append(UInt8(size & 0xFF))
            result.append(pointer, count: size)
        }
        return result
    }
}
