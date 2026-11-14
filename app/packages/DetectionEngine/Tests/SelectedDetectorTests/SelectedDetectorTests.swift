import Foundation
import XCTest
import FallCore
import SelectedDetector

final class SelectedDetectorTests: XCTestCase {
    private struct Recording: Decodable {
        let metadata: RecordingMetadata
        let samples: [IMUSample]
    }

    func testSelectedModelReproducesAllFrozenRecordingTriggers() throws {
        guard let path = ProcessInfo.processInfo.environment["FALL_BASELINE_WORKSPACE"] else {
            throw XCTSkip("Set FALL_BASELINE_WORKSPACE to run private baseline replay; recordings are not distributed")
        }
        let root = URL(fileURLWithPath: path)
        let benchmark = root.appendingPathComponent("FallReplay/Reports/train-py-integration/paired-offline/benchmark_runs.json")
        let runs = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: benchmark)) as? [[String: Any]])
        XCTAssertEqual(runs.count, 17)
        for run in runs {
            let id = try XCTUnwrap(run["recordingID"] as? String)
            let data = try Data(contentsOf: root.appendingPathComponent("FallReplay/App/Resources/Recordings/\(id).json"))
            let recording = try JSONDecoder().decode(Recording.self, from: data)
            var detector = try SelectedDetector.make(sessionID: id, units: SensorUnits(metadata: recording.metadata))
            // Match original RecordingLoader's stable timestamp order exactly.
            let samples = recording.samples.enumerated().filter { $0.element.source == "GLASSES" }.sorted {
                $0.element.timestampNs == $1.element.timestampNs ? $0.offset < $1.offset : $0.element.timestampNs < $1.element.timestampNs
            }
            for row in samples { _ = detector.consume(row.element) }
            detector.finish()
            let lanes = try XCTUnwrap(run["lanes"] as? [[String: Any]])
            let lane = try XCTUnwrap(lanes.first { $0["detector"] as? String == "rule" })
            let events = try XCTUnwrap(lane["events"] as? [[String: Any]])
            let expected = try events.filter { $0["kind"] as? String == "trigger" }.map {
                try XCTUnwrap(($0["imuTimestampNs"] as? NSNumber)?.int64Value)
            }
            XCTAssertEqual(detector.triggers.map(\.emittedTimestampNs), expected, "Frozen decisions changed for \(id)")
        }
    }
}
