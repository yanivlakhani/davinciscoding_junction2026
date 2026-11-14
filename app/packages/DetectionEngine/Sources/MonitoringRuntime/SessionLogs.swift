import Foundation

/// Disk work is serialized on its own queue, outside acquisition and inference.
/// The byte limit bounds pending work; errors stop monitoring on the next check.
final class SessionLogs: @unchecked Sendable {
    private let queue = DispatchQueue(label: "FallApp.session-logs", qos: .utility)
    private let lock = NSLock()
    private var pendingBytes = 0
    private var failure: Error?
    private var closed = false
    private var handles: [String: FileHandle] = [:] // queue-owned after init
    private var dirty = false
    private var timer: DispatchSourceTimer?
    private let maximumPendingBytes = 4 * 1024 * 1024

    init(directory: URL) throws {
        for name in ["motion.jsonl", "ordered-motion.jsonl", "events.jsonl", "latency.jsonl"] {
            let url = directory.appendingPathComponent(name)
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
            handles[name] = try FileHandle(forWritingTo: url)
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.synchronize() }
        self.timer = timer; timer.resume()
    }

    func check() throws {
        lock.lock(); let error = failure; lock.unlock()
        if let error { throw error }
    }

    func append(_ data: Data, to name: String) throws {
        var line = data; line.append(10)
        lock.lock()
        if let failure { lock.unlock(); throw failure }
        guard !closed, pendingBytes + line.count <= maximumPendingBytes else {
            let error = RecordingLogFailure.overloaded
            failure = error; lock.unlock(); throw error
        }
        pendingBytes += line.count
        lock.unlock()
        let bytes = line
        queue.async { [self] in
            defer { lock.lock(); pendingBytes -= bytes.count; lock.unlock() }
            do { try handles[name]?.write(contentsOf: bytes); dirty = true }
            catch { remember(error) }
        }
    }

    func finish() async throws {
        lock.withLock { closed = true }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                timer?.cancel(); timer = nil
                synchronize()
                for handle in handles.values { do { try handle.close() } catch { remember(error) } }
                handles = [:]
                do { try check(); continuation.resume() } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func synchronize() {
        guard dirty else { return }
        do { for handle in handles.values { try handle.synchronize() }; dirty = false }
        catch { remember(error) }
    }

    private func remember(_ error: Error) {
        lock.lock(); if failure == nil { failure = error }; lock.unlock()
    }
}

private enum RecordingLogFailure: LocalizedError {
    case overloaded
    var errorDescription: String? { "Session log queue unavailable or full; monitoring stopped" }
}
