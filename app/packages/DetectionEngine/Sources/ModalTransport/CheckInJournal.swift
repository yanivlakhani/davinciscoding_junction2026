import Foundation

/// Persist a claim before any speech so duplicate responses/relaunches cannot re-ask.
public actor CheckInJournal {
    private let directory: URL
    public init(root: URL) { directory = root.appendingPathComponent("check-ins") }
    public func claim(_ assessment: ServerAssessment) throws -> Bool {
        guard ModalRequest.validID(assessment.eventId) else { throw DeliveryError.invalidRequest }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: directory.path)
        #endif
        let file = directory.appendingPathComponent(assessment.eventId + ".json")
        guard !FileManager.default.fileExists(atPath: file.path) else { return false }
        try JSONEncoder().encode(Record(assessment: assessment, state: "claimed", transcript: nil)).write(to: file, options: .atomic)
        return true
    }
    public func save(_ assessment: ServerAssessment, state: String, transcript: String? = nil) throws {
        try JSONEncoder().encode(Record(assessment: assessment, state: state, transcript: transcript))
            .write(to: directory.appendingPathComponent(assessment.eventId + ".json"), options: .atomic)
    }
    public func saveTurn(_ assessment: ServerAssessment, stage: CheckInSubmission.Stage, state: String, transcript: String?) throws {
        try JSONEncoder().encode(Record(assessment: assessment, state: state, transcript: transcript))
            .write(to: directory.appendingPathComponent(assessment.eventId + "-" + stage.rawValue + ".json"), options: .atomic)
    }
    private struct Record: Codable { let assessment: ServerAssessment; let state: String; let transcript: String? }
}
