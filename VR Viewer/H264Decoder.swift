import Foundation
import AVFoundation
import CoreMedia
import VideoToolbox

/// H.264 receiver/renderer for the Windows VR Viewer stream.
///
/// The Windows side sends a 4-byte big-endian payload length followed by
/// Annex-B H.264 bytes. This decoder keeps the transport framing intact,
/// collects NAL units into picture access units, and hands complete CMSample
/// Buffers to AVSampleBufferDisplayLayer. AVFoundation/VideoToolbox performs
/// the actual decode and rendering.
final class H264Decoder {
    private final class WeakDisplayLayer {
        weak var layer: AVSampleBufferDisplayLayer?
        init(_ layer: AVSampleBufferDisplayLayer) {
            self.layer = layer
        }
    }
    private let queue = DispatchQueue(label: "com.adrian.vrviewer.h264", qos: .userInitiated)
    private let stateLock = NSLock()

    private var sps: Data?
    private var pps: Data?
    private var formatDescription: CMVideoFormatDescription?
    private var pendingVCL: [Data] = []
    private var pendingHasIDR = false
    private var waitingForKeyframe = true
    private var sequence: Int64 = 0

    private var displayLayers: [ObjectIdentifier: WeakDisplayLayer] = [:]
    private var displayStatusText = "No renderer"

    private var lastBytes = 0
    private var lastFrames = 0

    private(set) var bytesReceived = 0
    private(set) var nalCount = 0
    private(set) var framesEnqueued = 0
    private(set) var sampleBuffersCreated = 0
    private(set) var framesDecoded = 0
    private(set) var spsSeen = false
    private(set) var ppsSeen = false
    private(set) var pixelWidth = 0
    private(set) var pixelHeight = 0
    private(set) var pixelLumaMin = 0
    private(set) var pixelLumaMax = 0
    private(set) var pixelLumaAverage = 0
    var lastError = ""

    var onStats: ((H264Stats) -> Void)?

    struct H264Stats {
        let bytesReceived: Int
        let nalCount: Int
        let framesEnqueued: Int
        let sampleBuffersCreated: Int
        let framesDecoded: Int
        let spsSeen: Bool
        let ppsSeen: Bool
        let displayStatus: String
        let lastError: String
        let pixelWidth: Int
        let pixelHeight: Int
        let pixelLumaMin: Int
        let pixelLumaMax: Int
        let pixelLumaAverage: Int
    }

    init() {}

    deinit {
        queue.async { [weak self] in
            guard let self else { return }
            self.flushAllDisplayLayers()
            self.displayLayers.removeAll()
        }
    }

    /// Registers one renderer. Multiple views may be attached at the same time
    /// (for example, the normal preview and the fullscreen renderer).
    func attachDisplayLayer(_ layer: AVSampleBufferDisplayLayer) {
        queue.async { [weak self, weak layer] in
            guard let self, let layer else { return }

            self.displayLayers[ObjectIdentifier(layer)] = WeakDisplayLayer(layer)
            layer.videoGravity = .resizeAspect
            self.displayStatusText = self.statusString(for: layer.status)
            self.lastError = ""
            self.publishStats(force: true)
        }
    }

    /// Detaches exactly this renderer. It must never remove another view's
    /// renderer during a SwiftUI fullscreen transition.
    func detachDisplayLayer(_ layer: AVSampleBufferDisplayLayer) {
        queue.async { [weak self, weak layer] in
            guard let self, let layer else { return }
            layer.flushAndRemoveImage()
            self.displayLayers.removeValue(forKey: ObjectIdentifier(layer))
            self.cleanupDeadDisplayLayers()
            self.displayStatusText = self.currentDisplayStatus()
            self.publishStats(force: true)
        }
    }

    func reset() {
        queue.async { [weak self] in
            guard let self else { return }
            self.flushAllDisplayLayers()
            self.sps = nil
            self.pps = nil
            self.formatDescription = nil
            self.pendingVCL.removeAll(keepingCapacity: true)
            self.pendingHasIDR = false
            self.waitingForKeyframe = true
            self.sequence = 0
            self.bytesReceived = 0
            self.nalCount = 0
            self.framesEnqueued = 0
            self.sampleBuffersCreated = 0
            self.framesDecoded = 0
            self.spsSeen = false
            self.ppsSeen = false
            self.pixelWidth = 0
            self.pixelHeight = 0
            self.pixelLumaMin = 0
            self.pixelLumaMax = 0
            self.pixelLumaAverage = 0
            self.lastError = ""
            self.displayStatusText = self.currentDisplayStatus()
            self.publishStats(force: true)
        }
    }

    func decode(_ data: Data) {
        guard !data.isEmpty else { return }
        queue.async { [weak self] in
            guard let self else { return }
            self.bytesReceived += data.count
            let nals = Self.extractNALUnits(from: data)
            guard !nals.isEmpty else {
                self.lastError = "No H.264 NAL units detected"
                self.publishStats(force: true)
                return
            }
            self.nalCount += nals.count
            self.consume(nals)
            self.publishStats(force: true)
        }
    }

    private func consume(_ nals: [Data]) {
        for nal in nals {
            guard let header = nal.first else { continue }
            let type = header & 0x1F
            switch type {
            case 7:
                if sps != nal {
                    flushPendingAccessUnit()
                    sps = nal
                    spsSeen = true
                    rebuildFormatDescription()
                }
            case 8:
                if pps != nal {
                    flushPendingAccessUnit()
                    pps = nal
                    ppsSeen = true
                    rebuildFormatDescription()
                }
            case 9:
                // AUD marks the end/start of an access unit. Flush the VCL
                // collected before it. The AUD itself is not needed by the
                // decoder sample.
                flushPendingAccessUnit()
            case 1, 5:
                // If a new first slice starts while we already have VCL data,
                // the preceding VCL belongs to the previous picture.
                if !pendingVCL.isEmpty && Self.firstMbInSlice(nal) == 0 {
                    flushPendingAccessUnit()
                }
                pendingVCL.append(nal)
                if type == 5 { pendingHasIDR = true }
            default:
                // SEI/filler are intentionally omitted from the sample. SPS,
                // PPS and VCL are sufficient for the decoder.
                break
            }
        }
    }

    private func flushPendingAccessUnit() {
        guard !pendingVCL.isEmpty else { return }
        let vcl = pendingVCL
        let idr = pendingHasIDR
        pendingVCL.removeAll(keepingCapacity: true)
        pendingHasIDR = false

        guard let formatDescription else {
            lastError = "Waiting for H.264 format description"
            return
        }
        guard !waitingForKeyframe || idr else { return }
        if idr { waitingForKeyframe = false }

        // Include SPS/PPS before the VCL in each sample. This makes the
        // display-layer decoder self-contained after reconnects/keyframes.
        var sampleNals: [Data] = []
        if let sps { sampleNals.append(sps) }
        if let pps { sampleNals.append(pps) }
        sampleNals.append(contentsOf: vcl)

        guard let sampleBuffer = makeSampleBuffer(nals: sampleNals, formatDescription: formatDescription) else {
            return
        }

        cleanupDeadDisplayLayers()
        guard !displayLayers.isEmpty else {
            lastError = "No AVSampleBufferDisplayLayer attached"
            return
        }

        sequence += 1
        framesEnqueued += 1

        var renderedCount = 0
        var failedError: String?

        for box in displayLayers.values {
            guard let layer = box.layer else { continue }

            if layer.status == .failed {
                layer.flushAndRemoveImage()
            }

            layer.enqueue(sampleBuffer)

            let status = layer.status
            if status == .rendering {
                renderedCount += 1
            } else if status == .failed, failedError == nil {
                failedError = layer.error.map(String.init(describing:)) ?? "unknown renderer error"
            }
        }

        displayStatusText = currentDisplayStatus()

        if let failedError {
            lastError = "Display layer failed: \(failedError)"
        } else {
            lastError = "Enqueued sample #\(framesEnqueued); \(renderedCount) renderer(s) rendering"
        }

        publishStats(force: true)

        // Each AVSampleBufferDisplayLayer can transition asynchronously.
        queue.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }

            self.cleanupDeadDisplayLayers()

            var renderingCount = 0
            var failedError: String?

            for box in self.displayLayers.values {
                guard let layer = box.layer else { continue }

                switch layer.status {
                case .rendering:
                    renderingCount += 1
                case .failed:
                    if failedError == nil {
                        failedError = layer.error.map(String.init(describing:)) ?? "unknown"
                    }
                default:
                    break
                }
            }

            self.displayStatusText = self.currentDisplayStatus()

            if let failedError {
                self.lastError = "Display layer async failure: \(failedError)"
            } else if renderingCount > 0 {
                self.lastError = "Renderer accepted sample #\(self.framesEnqueued)"
            }

            self.publishStats(force: true)
        }

        _ = formatDescription
    }

    private func rebuildFormatDescription() {
        guard let sps, let pps else { return }
        var desc: CMVideoFormatDescription?
        let status = sps.withUnsafeBytes { spsRaw in
            pps.withUnsafeBytes { ppsRaw in
                guard let spsPtr = spsRaw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let ppsPtr = ppsRaw.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    return OSStatus(kCMFormatDescriptionBridgeError_InvalidParameter)
                }
                var pointers: [UnsafePointer<UInt8>] = [spsPtr, ppsPtr]
                var sizes: [Int] = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: &pointers,
                    parameterSetSizes: &sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &desc
                )
            }
        }
        if status == noErr, let desc {
            formatDescription = desc
            waitingForKeyframe = true
            flushAllDisplayLayers()
            lastError = "Format ready; waiting for IDR (SPS \(sps.count)B, PPS \(pps.count)B)"
        } else {
            formatDescription = nil
            waitingForKeyframe = true
            lastError = "H.264 format description error: \(status)"
        }
    }

    private func makeSampleBuffer(nals: [Data], formatDescription: CMVideoFormatDescription) -> CMSampleBuffer? {
        var avcc = Data()
        avcc.reserveCapacity(nals.reduce(0) { $0 + 4 + $1.count })
        for nal in nals {
            var length = UInt32(nal.count).bigEndian
            withUnsafeBytes(of: &length) { avcc.append(contentsOf: $0) }
            avcc.append(nal)
        }

        var block: CMBlockBuffer?
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: avcc.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: avcc.count,
            flags: 0,
            blockBufferOut: &block
        )
        guard blockStatus == kCMBlockBufferNoErr, let block else {
            lastError = "CMBlockBuffer error: \(blockStatus)"
            return nil
        }

        let copyStatus = avcc.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -50 }
            return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: block, offsetIntoDestination: 0, dataLength: avcc.count)
        }
        guard copyStatus == noErr else {
            lastError = "CMBlockBuffer copy error: \(copyStatus)"
            return nil
        }

        sequence += 1
        let timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: sequence, timescale: 90_000),
            decodeTimeStamp: .invalid
        )
        var timingEntry = timing
        var sampleSize = avcc.count
        var sample: CMSampleBuffer?
        let status = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timingEntry,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sample
        )
        guard status == noErr else {
            lastError = "CMSampleBuffer error: \(status)"
            return nil
        }
        sampleBuffersCreated += 1
        return sample
    }

    private func cleanupDeadDisplayLayers() {
        displayLayers = displayLayers.filter { $0.value.layer != nil }
    }

    private func flushAllDisplayLayers() {
        cleanupDeadDisplayLayers()
        for box in displayLayers.values {
            box.layer?.flushAndRemoveImage()
        }
    }

    private func currentDisplayStatus() -> String {
        cleanupDeadDisplayLayers()

        guard !displayLayers.isEmpty else {
            return "No renderer"
        }

        let statuses = displayLayers.values.compactMap { box in
            box.layer?.status
        }

        if statuses.contains(.rendering) {
            return "renderer rendering"
        }
        if statuses.contains(.failed) {
            return "renderer failed"
        }
        return "renderer unknown"
    }

    private func statusString(for status: AVQueuedSampleBufferRenderingStatus) -> String {
        switch status {
        case .unknown: return "renderer unknown"
        case .rendering: return "renderer rendering"
        case .failed: return "renderer failed"
        @unknown default: return "renderer \(status.rawValue)"
        }
    }

    func publishStats(force: Bool = false) {
        guard force || bytesReceived != lastBytes || framesEnqueued != lastFrames else { return }
        lastBytes = bytesReceived
        lastFrames = framesEnqueued
        onStats?(H264Stats(
            bytesReceived: bytesReceived,
            nalCount: nalCount,
            framesEnqueued: framesEnqueued,
            sampleBuffersCreated: sampleBuffersCreated,
            framesDecoded: framesDecoded,
            spsSeen: spsSeen,
            ppsSeen: ppsSeen,
            displayStatus: displayStatusText,
            lastError: lastError,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            pixelLumaMin: pixelLumaMin,
            pixelLumaMax: pixelLumaMax,
            pixelLumaAverage: pixelLumaAverage
        ))
    }

    private static func extractNALUnits(from data: Data) -> [Data] {
        let bytes = [UInt8](data)
        guard !bytes.isEmpty else { return [] }
        if let result = splitAnnexB(bytes), !result.isEmpty { return result }
        if let result = splitAVCC(bytes, lengthFieldBytes: 4), !result.isEmpty { return result }
        if let result = splitAVCC(bytes, lengthFieldBytes: 2), !result.isEmpty { return result }
        let type = bytes[0] & 0x1F
        return (1...23).contains(type) ? [data] : []
    }

    private static func splitAnnexB(_ bytes: [UInt8]) -> [Data]? {
        var starts: [Int] = []
        var i = 0
        while i + 2 < bytes.count {
            if bytes[i] == 0 && bytes[i + 1] == 0 && bytes[i + 2] == 1 {
                starts.append(i + 3); i += 3
            } else if i + 3 < bytes.count && bytes[i] == 0 && bytes[i + 1] == 0 && bytes[i + 2] == 0 && bytes[i + 3] == 1 {
                starts.append(i + 4); i += 4
            } else { i += 1 }
        }
        guard !starts.isEmpty else { return nil }
        var result: [Data] = []
        for i in starts.indices {
            let start = starts[i]
            let end = i + 1 < starts.count ? starts[i + 1] : bytes.count
            guard start < end else { continue }
            var actualEnd = end
            while actualEnd > start && bytes[actualEnd - 1] == 0 { actualEnd -= 1 }
            if actualEnd > start { result.append(Data(bytes[start..<actualEnd])) }
        }
        return result.isEmpty ? nil : result
    }

    private static func splitAVCC(_ bytes: [UInt8], lengthFieldBytes: Int) -> [Data]? {
        guard bytes.count > lengthFieldBytes else { return nil }
        var offset = 0
        var result: [Data] = []
        while offset + lengthFieldBytes <= bytes.count {
            var length = 0
            for _ in 0..<lengthFieldBytes { length = (length << 8) | Int(bytes[offset]); offset += 1 }
            guard length > 0, length <= bytes.count - offset else { return nil }
            let type = bytes[offset] & 0x1F
            guard (1...23).contains(type) else { return nil }
            result.append(Data(bytes[offset..<(offset + length)]))
            offset += length
        }
        return offset == bytes.count && !result.isEmpty ? result : nil
    }

    private static func firstMbInSlice(_ nal: Data) -> Int {
        let bytes = Array(nal.dropFirst())
        guard !bytes.isEmpty else { return -1 }
        var rbsp: [UInt8] = []
        rbsp.reserveCapacity(bytes.count)
        var zeros = 0
        for b in bytes {
            if zeros >= 2 && b == 0x03 { zeros = 0; continue }
            rbsp.append(b)
            zeros = b == 0 ? zeros + 1 : 0
        }
        var reader = BitReader(bytes: rbsp)
        return reader.readUE() ?? -1
    }

    private struct BitReader {
        let bytes: [UInt8]
        var bitIndex = 0
        mutating func readBit() -> Int? {
            guard bitIndex < bytes.count * 8 else { return nil }
            let byte = bytes[bitIndex >> 3]
            let shift = 7 - (bitIndex & 7)
            bitIndex += 1
            return Int((byte >> shift) & 1)
        }
        mutating func readUE() -> Int? {
            var zeros = 0
            while let bit = readBit() {
                if bit == 1 { break }
                zeros += 1
                if zeros > 31 { return nil }
            }
            guard zeros < 32 else { return nil }
            var value = 0
            for _ in 0..<zeros { guard let b = readBit() else { return nil }; value = (value << 1) | b }
            return (1 << zeros) - 1 + value
        }
    }
}
