import Foundation

/// A stop command returning does not confirm that the glasses stopped capture.
public enum CameraStopConfirmation {
    public static func wait(timeout: Duration = .seconds(3),
                            isStopped: @Sendable () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !isStopped(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        return isStopped()
    }
}

/// Pure lifecycle decisions shared by the SDK adapter and regression tests.
public enum CameraReuseDecision: Equatable, Sendable {
    case reuse, recreate, waitForResume

    public static func evaluate(hasCamera: Bool, cameraState: String, streamState: String, hasError: Bool,
                                startPending: Bool = false) -> Self {
        guard hasCamera else { return .recreate }
        if hasError || ["stopped", "stopping"].contains(cameraState)
            || streamState == "stopping" || (streamState == "stopped" && !startPending) { return .recreate }
        if streamState == "paused" { return .waitForResume }
        return .reuse
    }
}

public struct CameraStreamFailure: LocalizedError, Sendable {
    public let code: String
    public let message: String
    public let retryable: Bool
    public var errorDescription: String? { message }
    public init(code: String, message: String, retryable: Bool) {
        self.code = code; self.message = message; self.retryable = retryable
    }
    public func allowsRetry(attempt: Int, hasFrames: Bool) -> Bool { retryable && attempt == 1 && !hasFrames }
}
