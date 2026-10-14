/// Orders asynchronously delivered lifecycle events and isolates payloads from
/// old native subscriptions. The owner calls invalidate at its actual boundary.
public struct ObserverLifecycle: Sendable {
    public struct Token: Equatable, Sendable {
        fileprivate let epoch: UInt64
    }

    private var epoch: UInt64 = 0
    private var latestEventAt = -Double.infinity

    public init() {}
    public var token: Token { Token(epoch: epoch) }
    public func accepts(_ token: Token) -> Bool { token.epoch == epoch }
    public mutating func invalidate() { epoch &+= 1 }

    /// Capture the time when the native notification arrives, before dispatching
    /// an actor task. Older tasks cannot override an already handled newer event.
    public mutating func acceptsEvent(at time: Double) -> Bool {
        guard time.isFinite, time >= latestEventAt else { return false }
        latestEventAt = time
        return true
    }
}
