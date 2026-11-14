import AVFoundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import VideoToolbox
import os

/// Export every received frame directly. No movie writer, container or temporary video.
enum JPEGFrameExporter {
    static func export(_ frames: [BufferedVideoFrame], to directory: URL) throws -> (duration: Double, frames: [String]) {
        guard !frames.isEmpty else { throw RecordingFailure.message("No camera frames received") }
        let started = DispatchTime.now().uptimeNanoseconds
        let output = JPEGOutput()
        var decoder: VTDecompressionSession?
        defer { if let decoder { VTDecompressionSessionInvalidate(decoder) }; withExtendedLifetime(output) {} }
        for frame in frames {
            try Task.checkCancellation()
            if let pixel = CMSampleBufferGetImageBuffer(frame.sample) {
                output.append(pixel, at: CMSampleBufferGetPresentationTimeStamp(frame.sample))
            } else {
                guard let format = CMSampleBufferGetFormatDescription(frame.sample),
                      CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_HEVC else {
                    throw RecordingFailure.message("Unsupported camera frame format")
                }
                if decoder == nil {
                    var callback = VTDecompressionOutputCallbackRecord(decompressionOutputCallback: {
                        reference, _, status, _, pixel, timestamp, _ in
                        guard let reference else { return }
                        let output = Unmanaged<JPEGOutput>.fromOpaque(reference).takeUnretainedValue()
                        guard status == noErr, let pixel else { output.fail("HEVC frame decode failed: \(status)"); return }
                        output.append(pixel, at: timestamp)
                    }, decompressionOutputRefCon: Unmanaged.passUnretained(output).toOpaque())
                    let status = VTDecompressionSessionCreate(allocator: nil, formatDescription: format,
                        decoderSpecification: nil,
                        imageBufferAttributes: [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA] as CFDictionary,
                        outputCallback: &callback, decompressionSessionOut: &decoder)
                    guard status == noErr, decoder != nil else { throw RecordingFailure.message("Cannot open HEVC decoder: \(status)") }
                }
                // DAT may omit timing and sync flags. Supply decode metadata only;
                // presentation timestamps remain exactly those received from glasses.
                let pts = CMSampleBufferGetPresentationTimeStamp(frame.sample)
                let originalDTS = CMSampleBufferGetDecodeTimeStamp(frame.sample)
                let duration = CMSampleBufferGetDuration(frame.sample)
                var timing = CMSampleTimingInfo(duration: duration.isNumeric && duration > .zero ? duration : CMTime(value: 1, timescale: Int32(FrameBurstConfiguration.framesPerSecond)),
                    presentationTimeStamp: pts, decodeTimeStamp: originalDTS.isNumeric ? originalDTS : pts)
                var adjusted: CMSampleBuffer?
                guard CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: frame.sample,
                    sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &adjusted) == noErr,
                      let adjusted else { throw RecordingFailure.message("Cannot normalize camera frame timing") }
                if let flags = (CMSampleBufferGetSampleAttachmentsArray(adjusted, createIfNecessary: true) as? [NSMutableDictionary])?.first {
                    flags[kCMSampleAttachmentKey_NotSync] = !frame.sync
                    flags[kCMSampleAttachmentKey_DependsOnOthers] = !frame.sync
                }
                let status = VTDecompressionSessionDecodeFrame(decoder!, sampleBuffer: adjusted,
                    flags: [], frameRefcon: nil, infoFlagsOut: nil)
                guard status == noErr else { throw RecordingFailure.message("Cannot decode camera frame: \(status)") }
            }
        }
        if let decoder {
            guard VTDecompressionSessionFinishDelayedFrames(decoder) == noErr,
                  VTDecompressionSessionWaitForAsynchronousFrames(decoder) == noErr else {
                throw RecordingFailure.message("HEVC decoder did not finish all frames")
            }
        }
        let images = try output.result(expectedCount: frames.count)
        var names: [String] = []
        do {
            for (index, image) in images.enumerated() {
                try Task.checkCancellation()
                let name = "frame-\(index).jpg"
                try image.data.write(to: directory.appendingPathComponent(name), options: .atomic)
                names.append(name)
            }
            let timing: [String: Any] = ["captureFormat": "jpeg_frames_only", "requestedFrameRate": FrameBurstConfiguration.framesPerSecond,
                "durationSeconds": 1.0, "receivedFrames": frames.count, "writtenFrames": images.count,
                "firstFramePhoneReceiptNs": String(frames.first!.receipt), "lastWrittenFramePhoneReceiptNs": String(frames.last!.receipt),
                "jpegFrameMediaSeconds": images.map(\.seconds), "jpegExtractionStartNs": String(started),
                "actualFrameSpanSeconds": images.last!.seconds - images.first!.seconds,
                "jpegExtractionEndNs": String(DispatchTime.now().uptimeNanoseconds), "mp4Created": false]
            try JSONSerialization.data(withJSONObject: timing).write(to: directory.appendingPathComponent("timing.json"), options: .atomic)
        } catch {
            for name in names { try? FileManager.default.removeItem(at: directory.appendingPathComponent(name)) }
            throw error
        }
        return (1, names)
    }
}

private final class JPEGOutput: @unchecked Sendable {
    struct Image { let seconds: Double; let data: Data }
    private struct State { var images: [Image] = []; var bytes = 0; var error: String? }
    private let state = OSAllocatedUnfairLock(uncheckedState: State())
    private let context = CIContext(options: [.cacheIntermediates: false])

    func fail(_ message: String) { state.withLockUnchecked { if $0.error == nil { $0.error = message } } }

    func append(_ pixel: CVPixelBuffer, at time: CMTime) {
        guard time.isNumeric else { fail("Invalid frame presentation timestamp"); return }
        autoreleasepool {
            let image = CIImage(cvPixelBuffer: pixel)
            guard let cgImage = context.createCGImage(image, from: image.extent) else { fail("Cannot render camera frame"); return }
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
                fail("Cannot create JPEG encoder"); return
            }
            CGImageDestinationAddImage(destination, cgImage, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { fail("Cannot encode JPEG frame"); return }
            state.withLockUnchecked { value in
                guard value.error == nil else { return }
                guard value.images.count < 120, value.bytes + data.length <= 32 * 1024 * 1024 else {
                    value.error = "JPEG burst memory limit exceeded; no partial upload"; return
                }
                value.images.append(Image(seconds: time.seconds, data: data as Data)); value.bytes += data.length
            }
        }
    }

    func result(expectedCount: Int) throws -> [Image] {
        try state.withLockUnchecked { value in
            if let error = value.error { throw RecordingFailure.message(error) }
            guard value.images.count == expectedCount else { throw RecordingFailure.message("Decoder lost camera frames; burst incomplete") }
            return value.images.sorted { $0.seconds < $1.seconds }
        }
    }
}

public enum RecordingFailure: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}
