/// Three bounded rereads let HAL settle after an accessory connection event.
/// Generation tokens prevent a superseded event from consuming another event's
/// retries or clearing its pending work after cancellation.
public struct AudioOutputRetryPlan: Sendable {
    public private(set) var generation: UInt64 = 0
    private var deadlines: [Double] = []

    public init() {}
    public var hasPendingRetries: Bool { !deadlines.isEmpty }

    public mutating func schedule(at time: Double) {
        generation &+= 1
        let time = time.isFinite ? time : 0
        deadlines = [0.15, 0.5, 1.2].map { time + $0 }
    }

    public mutating func cancel() {
        generation &+= 1
        deadlines.removeAll(keepingCapacity: true)
    }

    public mutating func nextDelay(at time: Double, for generation: UInt64) -> Double? {
        guard generation == self.generation, !deadlines.isEmpty else { return nil }
        let deadline = deadlines.removeFirst()
        return max(0, deadline - (time.isFinite ? time : deadline))
    }
}
