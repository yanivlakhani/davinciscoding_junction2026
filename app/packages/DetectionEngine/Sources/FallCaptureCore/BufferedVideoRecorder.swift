import AVFoundation
import CoreVideo
import os

/// Shared capture cadence for SDK configuration, missing sample timing and diagnostics.
public enum FrameBurstConfiguration {
    public static let framesPerSecond: UInt = 7
    public static let maximumFrames = 7
}

/// Retaining a sample retains its pixel/block buffer until JPEG export or eviction.
public struct BufferedVideoFrame: @unchecked Sendable {
    public let sample: CMSampleBuffer
    public let receipt: UInt64
    public var seconds: Double { CMSampleBufferGetPresentationTimeStamp(sample).seconds }
    public var bytes: Int {
        CMSampleBufferGetImageBuffer(sample).map(CVPixelBufferGetDataSize) ?? CMSampleBufferGetTotalSampleSize(sample)
    }
    public var sync: Bool { CMSampleBufferGetImageBuffer(sample) != nil || Self.isSync(sample) }
    public init(sample: CMSampleBuffer, receipt: UInt64) { self.sample = sample; self.receipt = receipt }
    static func isSync(_ sample: CMSampleBuffer) -> Bool {
        // DAT compressed samples may omit sync attachments. Inspect HEVC NAL
        // units instead of treating every unmarked P/B frame as a keyframe.
        guard let format = CMSampleBufferGetFormatDescription(sample),
              CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_HEVC,
              let block = CMSampleBufferGetDataBuffer(sample) else { return false }
        var headerLength: Int32 = 4
        _ = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: 0,
            parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: nil,
            nalUnitHeaderLengthOut: &headerLength)
        guard (1...4).contains(headerLength) else { return false }
        let length = Int(headerLength), total = CMBlockBufferGetDataLength(block)
        var offset = 0
        while offset + length + 2 <= total {
            var header = [UInt8](repeating: 0, count: length + 2)
            guard CMBlockBufferCopyDataBytes(block, atOffset: offset, dataLength: header.count,
                                            destination: &header) == noErr else { return false }
            let bytes = header.prefix(length).reduce(0) { ($0 << 8) | Int($1) }
            guard bytes >= 2, bytes <= total - offset - length else { return false }
            let type = (header[length] >> 1) & 0x3f
            if (16...21).contains(type) { return true }
            offset += length + bytes
        }
        return false
    }
}

/// SDK callbacks only retain/evict frames. No encoding, disk I/O or async task per frame.
/// Rolling RAM is capped by duration, bytes and frame count; confirmed clips have
/// independent limits and fail explicitly if those limits would be exceeded.
public final class BufferedVideoRecorder: Sendable {
    public struct Snapshot: Sendable {
        public let bufferedFrames: Int
        public let bufferedBytes: Int
        public let recording: Bool
        public let complete: Bool
        public let error: String?
        public let firstReceipt: UInt64?
        public let lastReceipt: UInt64?
        public let preRollSeconds: Double
    }
    private struct State {
        var ring: [BufferedVideoFrame] = []
        var ringBytes = 0
        var active: [BufferedVideoFrame]?
        var activeBytes = 0
        var complete = false
        var error: String?
        var preRoll = 0.0
    }
    private let state = OSAllocatedUnfairLock(uncheckedState: State())
    private let maximumBytes: Int
    private let maximumFrames = 240
    public init(maximumBytes: Int = 32 * 1024 * 1024) { self.maximumBytes = maximumBytes }

    public var snapshot: Snapshot {
        state.withLockUnchecked { s in
            Snapshot(bufferedFrames: s.ring.count, bufferedBytes: s.ringBytes,
                     recording: s.active != nil, complete: s.complete, error: s.error,
                     firstReceipt: s.active?.first?.receipt, lastReceipt: s.active?.last?.receipt,
                     preRollSeconds: s.preRoll)
        }
    }

    public func append(_ sample: CMSampleBuffer, receipt: UInt64) {
        let frame = BufferedVideoFrame(sample: sample, receipt: receipt)
        guard frame.seconds.isFinite, frame.bytes > 0 else { return }
        state.withLockUnchecked { s in
            if let previous = s.ring.last, frame.seconds < previous.seconds {
                s.ring = []; s.ringBytes = 0
                if s.active != nil { s.error = "Camera media timestamp moved backwards" }
            }
            s.ring.append(frame); s.ringBytes += frame.bytes
            while let first = s.ring.first,
                  frame.seconds - first.seconds > 2 || s.ringBytes > maximumBytes || s.ring.count > maximumFrames {
                s.ringBytes -= s.ring.removeFirst().bytes
            }
            guard s.active != nil, !s.complete, s.error == nil else { return }
            if s.active!.isEmpty && !frame.sync { return }
            guard s.activeBytes + frame.bytes <= maximumBytes, s.active!.count < maximumFrames else {
                s.error = "Confirmed video buffer full; capture incomplete"; return
            }
            if let first = s.active!.first, frame.seconds - first.seconds >= 1 - 0.000001 {
                s.complete = true; return // Boundary frame belongs to the next second.
            }
            s.active!.append(frame); s.activeBytes += frame.bytes
            let duration = CMSampleBufferGetDuration(sample).seconds
            // Complete at seven frames even if SDK timing jitters, so a burst
            // cannot exceed the backend's seven-frame input contract.
            let coverage = duration.isFinite && duration > 0 && duration <= 1
                ? duration : 1.0 / Double(FrameBurstConfiguration.framesPerSecond)
            if let first = s.active!.first, frame.seconds - first.seconds + coverage >= 1 - 0.000001
                || s.active!.count >= FrameBurstConfiguration.maximumFrames { s.complete = true }
        }
    }

    /// Preserve up to a quarter second before red, starting at a decodable frame.
    /// If HEVC has no recent keyframe, wait for the next one rather than export
    /// an undecodable clip. The actual available pre-roll is reported.
    public func begin(receiptUptimeNs now: UInt64 = DispatchTime.now().uptimeNanoseconds) throws {
        try state.withLockUnchecked { s in
            guard s.active == nil else { throw RecordingFailure.message("Capture already in progress") }
            s.active = []; s.activeBytes = 0; s.complete = false; s.error = nil; s.preRoll = 0
            if let newest = s.ring.last,
               let start = s.ring.firstIndex(where: { $0.seconds >= newest.seconds - 0.25 && $0.sync
                   && now >= $0.receipt && now - $0.receipt <= 1_000_000_000 }) {
                s.active = Array(s.ring[start...]); s.activeBytes = s.active!.reduce(0) { $0 + $1.bytes }
                s.preRoll = newest.seconds - s.active![0].seconds
            }
        }
    }

    public func reset() {
        state.withLockUnchecked { $0 = State() }
    }

    public func cancelClip() {
        state.withLockUnchecked { s in s.active = nil; s.activeBytes = 0; s.complete = false; s.error = nil }
    }

    public func export(to directory: URL) async throws -> (duration: Double, frames: [String]) {
        let frames = try state.withLockUnchecked { s -> [BufferedVideoFrame] in
            guard s.complete, s.error == nil, let active = s.active, !active.isEmpty else {
                throw RecordingFailure.message(s.error ?? "One-second frame burst incomplete")
            }
            return active
        }
        // Decode/encode directly, outside motion processing and SDK callbacks.
        return try await Task.detached(priority: .utility) {
            try JPEGFrameExporter.export(frames, to: directory)
        }.value
    }
}
