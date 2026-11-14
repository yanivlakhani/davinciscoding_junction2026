/// Notify once per interruption, after a successful connection. Intentional
/// stops and an accessory that has never connected do not produce alerts.
public struct ConnectionAlertGate: Sendable {
    private var established = false
    private var interrupted = false
    public init() {}
    public mutating func connected() { established = true; interrupted = false }
    public mutating func stoppedByUser() { established = false; interrupted = false }
    public mutating func interruption() -> Bool {
        guard established, !interrupted else { return false }
        interrupted = true
        return true
    }
}
