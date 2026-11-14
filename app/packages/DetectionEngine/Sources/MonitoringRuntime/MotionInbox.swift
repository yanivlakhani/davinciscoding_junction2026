import Foundation

public struct ReceivedMotionPacket: Sendable {
    public let data: Data
    public let receiptUptimeNs: UInt64
    public init(data: Data, receiptUptimeNs: UInt64) {
        self.data = data; self.receiptUptimeNs = receiptUptimeNs
    }
}

/// One producer, one consumer. Acquisition never awaits inference or storage.
/// Overflow is an explicit monitoring failure, never a silent sample drop.
public final class MotionInbox: Sendable {
    public let packets: AsyncStream<ReceivedMotionPacket>
    private let continuation: AsyncStream<ReceivedMotionPacket>.Continuation

    public init(capacity: Int = 512) {
        precondition(capacity > 0)
        let channel = AsyncStream<ReceivedMotionPacket>.makeStream(bufferingPolicy: .bufferingOldest(capacity))
        packets = channel.stream; continuation = channel.continuation
    }

    @discardableResult public func offer(_ packet: ReceivedMotionPacket) -> Bool {
        switch continuation.yield(packet) {
        case .enqueued: return true
        case .dropped, .terminated: return false
        @unknown default: return false
        }
    }

    public func finish() { continuation.finish() }
}
