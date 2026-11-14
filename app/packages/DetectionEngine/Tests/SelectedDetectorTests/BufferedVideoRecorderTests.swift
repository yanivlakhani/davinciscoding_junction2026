import XCTest
import AVFoundation
import ImageIO
import VideoToolbox
import os
import FallCaptureCore
import MonitoringRuntime

final class BufferedVideoRecorderTests: XCTestCase {
    private func frame(_ index: Int, fps: Int32 = 7) throws -> CMSampleBuffer {
        var pixel: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 160, 120, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary, &pixel), kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixel)
        CVPixelBufferLockBaseAddress(buffer, [])
        let bytes = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
        for offset in 0..<CVPixelBufferGetDataSize(buffer) { bytes[offset] = offset % 4 == 3 ? 255 : UInt8((index * 5 + offset % 3 * 20) % 255) }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        var format: CMVideoFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer, formatDescriptionOut: &format), noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: fps),
            presentationTimeStamp: CMTime(value: Int64(index), timescale: fps), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: buffer,
            formatDescription: try XCTUnwrap(format), sampleTiming: &timing, sampleBufferOut: &sample), noErr)
        return try XCTUnwrap(sample)
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func verifyImages(_ result: (duration: Double, frames: [String]), at directory: URL, count: Int) throws {
        XCTAssertEqual(result.duration, 1)
        XCTAssertEqual(result.frames.count, count)
        XCTAssertEqual(Set(result.frames).count, count)
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(files.filter { $0.hasSuffix(".jpg") }.count, count)
        XCTAssertFalse(files.contains { $0.hasSuffix(".mp4") || $0.hasSuffix(".mov") })
        for name in result.frames {
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(directory.appendingPathComponent(name) as CFURL, nil))
            XCTAssertNotNil(CGImageSourceCreateImageAtIndex(source, 0, nil))
        }
        let timing = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("timing.json"))) as! [String: Any]
        let times = try XCTUnwrap(timing["jpegFrameMediaSeconds"] as? [Double])
        XCTAssertEqual(times.count, count)
        XCTAssertEqual(times, times.sorted())
        XCTAssertEqual(Set(times).count, count)
        XCTAssertEqual(timing["mp4Created"] as? Bool, false)
        XCTAssertLessThan(try XCTUnwrap(times.last) - XCTUnwrap(times.first), 1)
    }

    func testProducerCanEnqueueWithoutWaitingForConsumerAndOverflowIsExplicit() async throws {
        let inbox = MotionInbox(capacity: 2)
        XCTAssertTrue(inbox.offer(.init(data: Data([1]), receiptUptimeNs: 1)))
        XCTAssertTrue(inbox.offer(.init(data: Data([2]), receiptUptimeNs: 2)))
        XCTAssertFalse(inbox.offer(.init(data: Data([3]), receiptUptimeNs: 3)))
        inbox.finish()
        var received: [UInt64] = []
        for await packet in inbox.packets { received.append(packet.receiptUptimeNs) }
        XCTAssertEqual(received, [1, 2])
        XCTAssertFalse(inbox.offer(.init(data: Data([4]), receiptUptimeNs: 4)))
    }

    func testRollingMemoryBoundAndRejectedCandidateDiscard() throws {
        let bytes = BufferedVideoFrame(sample: try frame(0), receipt: 0).bytes
        let recorder = BufferedVideoRecorder(maximumBytes: bytes * 3)
        for index in 0..<80 { recorder.append(try frame(index), receipt: UInt64(index)) }
        XCTAssertLessThanOrEqual(recorder.snapshot.bufferedBytes, bytes * 3)
        XCTAssertEqual(recorder.snapshot.bufferedFrames, 3)
        recorder.reset()
        XCTAssertEqual(recorder.snapshot.bufferedFrames, 0)
        XCTAssertNil(recorder.snapshot.firstReceipt)
    }

    func testSevenFPSExportsEveryFrameWithoutMovieOrBoundaryDuplicate() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let recorder = BufferedVideoRecorder()
        try recorder.begin(receiptUptimeNs: 0)
        for index in 0..<6 { recorder.append(try frame(index), receipt: UInt64(index + 1) * 142_857_142) }
        XCTAssertFalse(recorder.snapshot.complete)
        recorder.append(try frame(6), receipt: 1_000_000_000)
        XCTAssertTrue(recorder.snapshot.complete)
        recorder.append(try frame(7), receipt: 1_0142_857_142)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        try verifyImages(try await recorder.export(to: root), at: root, count: 7)
    }

    func testLowerDeliveredRateExportsAllFramesWithoutDuplication() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let recorder = BufferedVideoRecorder()
        try recorder.begin(receiptUptimeNs: 0)
        for index in 0..<2 { recorder.append(try frame(index, fps: 2), receipt: UInt64(index + 1) * 500_000_000) }
        XCTAssertTrue(recorder.snapshot.complete)
        try verifyImages(try await recorder.export(to: root), at: root, count: 2)
    }

    func testWarmBufferPreservesBoundedPreRollAndEveryFrame() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let recorder = BufferedVideoRecorder()
        for index in 0...14 { recorder.append(try frame(index), receipt: UInt64(index + 1) * 142_857_142) }
        try recorder.begin(receiptUptimeNs: 15 * 142_857_142)
        XCTAssertGreaterThan(recorder.snapshot.preRollSeconds, 0)
        XCTAssertLessThanOrEqual(recorder.snapshot.preRollSeconds, 0.25)
        for index in 15...28 { recorder.append(try frame(index), receipt: UInt64(index + 1) * 142_857_142) }
        XCTAssertTrue(recorder.snapshot.complete)
        try verifyImages(try await recorder.export(to: root), at: root, count: 7)
        recorder.cancelClip()
        XCTAssertFalse(recorder.snapshot.recording)
    }

    func testIncompleteBurstAndTimestampRegressionCannotExportPartialFrames() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let recorder = BufferedVideoRecorder()
        recorder.append(try frame(2), receipt: 1)
        try recorder.begin()
        recorder.append(try frame(1), receipt: 2)
        XCTAssertNotNil(recorder.snapshot.error)
        do { _ = try await recorder.export(to: root); XCTFail("Incomplete burst exported") } catch {}
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    func testHEVCDecodesAllFramesInMemoryWithMissingSDKTimingAndFlags() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let output = CompressedFrames()
        var encoder: VTCompressionSession?
        XCTAssertEqual(VTCompressionSessionCreate(allocator: nil, width: 160, height: 120, codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: { reference, _, status, _, sample in
                guard let reference else { return }
                Unmanaged<CompressedFrames>.fromOpaque(reference).takeUnretainedValue().append(sample, status: status)
            }, refcon: Unmanaged.passUnretained(output).toOpaque(), compressionSessionOut: &encoder), noErr)
        let session = try XCTUnwrap(encoder)
        defer { VTCompressionSessionInvalidate(session); withExtendedLifetime(output) {} }
        XCTAssertEqual(VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse), noErr)
        XCTAssertEqual(VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 7 as CFNumber), noErr)
        for index in 0..<21 {
            let pixel = try XCTUnwrap(CMSampleBufferGetImageBuffer(try frame(index)))
            XCTAssertEqual(VTCompressionSessionEncodeFrame(session, imageBuffer: pixel,
                presentationTimeStamp: CMTime(value: Int64(index), timescale: 7), duration: CMTime(value: 1, timescale: 7),
                frameProperties: nil, sourceFrameRefcon: nil, infoFlagsOut: nil), noErr)
        }
        XCTAssertEqual(VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid), noErr)
        XCTAssertEqual(output.samples.count, 21)
        let recorder = BufferedVideoRecorder()
        try recorder.begin(receiptUptimeNs: 0)
        var waitedForKeyframe = false
        for (index, original) in output.samples.enumerated() where index >= 1 {
            var timing = CMSampleTimingInfo(duration: .invalid,
                presentationTimeStamp: CMTimeAdd(CMSampleBufferGetPresentationTimeStamp(original), CMTime(seconds: 5, preferredTimescale: 30)),
                decodeTimeStamp: .invalid)
            var copy: CMSampleBuffer?
            XCTAssertEqual(CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: original,
                sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &copy), noErr)
            let sample = try XCTUnwrap(copy)
            (CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) as? [NSMutableDictionary])?.first?.removeAllObjects()
            recorder.append(sample, receipt: UInt64(index + 1) * 142_857_142)
            if recorder.snapshot.firstReceipt == nil { waitedForKeyframe = true }
        }
        XCTAssertTrue(waitedForKeyframe)
        XCTAssertTrue(recorder.snapshot.complete)
        try verifyImages(try await recorder.export(to: root), at: root, count: 7)
        XCTAssertEqual(output.errors, 0)
    }
}

private final class CompressedFrames: @unchecked Sendable {
    private struct State { var samples: [CMSampleBuffer] = []; var errors = 0 }
    private let state = OSAllocatedUnfairLock(uncheckedState: State())
    var samples: [CMSampleBuffer] { state.withLockUnchecked { $0.samples.sorted { CMSampleBufferGetPresentationTimeStamp($0) < CMSampleBufferGetPresentationTimeStamp($1) } } }
    var errors: Int { state.withLockUnchecked { $0.errors } }
    func append(_ sample: CMSampleBuffer?, status: OSStatus) {
        state.withLockUnchecked { value in
            if status == noErr, let sample { value.samples.append(sample) } else { value.errors += 1 }
        }
    }
}
