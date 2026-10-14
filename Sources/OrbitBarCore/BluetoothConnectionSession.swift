/// Orders Bluetooth connection events and asynchronous registry reads. A
/// disconnect event is stronger evidence than a lagging cached connection flag.
public struct BluetoothConnectionSession: Sendable {
    public struct ReadToken: Equatable, Sendable {
        fileprivate let revision: UInt64
    }
    public typealias ObservationToken = ObserverLifecycle.Token

    private var revision: UInt64 = 0
    private var observationScope = ObserverLifecycle()
    private var blocked = Set<String>()
    private var observedDisconnected = Set<String>()
    private var confirmedClassicConnections = Set<String>()
    private var pendingConnectConfirmation: [String: Double] = [:]
    private var disconnectedServices: [String: Set<UInt64>] = [:]
    private var quarantinedBatteryServices: [String: Set<UInt64>] = [:]
    private var lastEventAt: [String: Double] = [:]
    private var sessionBatteryObservations: [String: [UInt64: BluetoothRegistryBatteryObservation]] = [:]
    private var batteryChangeRevisions: [String: [UInt64: UInt64]] = [:]

    public init() {}

    public var observationToken: ObservationToken { observationScope.token }
    public func acceptsObservation(_ token: ObservationToken) -> Bool { observationScope.accepts(token) }

    /// Event payloads already queued by an old native subscription must not
    /// enter a later wake/power/permission epoch.
    public mutating func invalidateObservations() {
        observationScope.invalidate()
        invalidateReads()
    }

    /// Workspace notifications also hop asynchronously to MainActor. Preserve
    /// their original ordering when an older sleep task executes after wake.
    public mutating func acceptsLifecycleTransition(at time: Double) -> Bool {
        observationScope.acceptsEvent(at: time)
    }

    public var disconnectedDeviceIDs: Set<String> { blocked }
    public var quarantinedServiceIDs: Set<UInt64> {
        quarantinedBatteryServices.values.reduce(into: []) { $0.formUnion($1) }
    }

    /// Starting another read always invalidates an older in-flight result.
    public mutating func beginRead() -> ReadToken {
        invalidateReads()
        return ReadToken(revision: revision)
    }

    public func accepts(_ token: ReadToken) -> Bool { token.revision == revision }

    public mutating func invalidateReads() { revision &+= 1 }

    @discardableResult
    public mutating func didDisconnect(_ id: String, serviceIDs: Set<UInt64> = [],
                                       batteryServiceIDs: Set<UInt64>? = nil, at time: Double? = nil) -> Bool {
        guard acceptsEvent(id, at: time) else { return false }
        blocked.insert(id)
        confirmedClassicConnections.remove(id)
        pendingConnectConfirmation[id] = nil
        observedDisconnected.remove(id)
        disconnectedServices[id, default: []].formUnion(serviceIDs)
        quarantinedBatteryServices[id, default: []].formUnion(batteryServiceIDs ?? serviceIDs)
        sessionBatteryObservations[id] = nil
        batteryChangeRevisions[id] = nil
        invalidateReads()
        return true
    }

    @discardableResult
    public mutating func didConnect(_ id: String, previousServiceIDs: Set<UInt64> = [], at time: Double? = nil) -> Bool {
        guard acceptsEvent(id, at: time) else { return false }
        blocked.remove(id)
        confirmedClassicConnections.remove(id)
        // Only an explicit timestamped connect event can grant this short
        // positive-evidence window. Inferred connections never get a grace.
        pendingConnectConfirmation[id] = time.map { $0 + 5 }
        observedDisconnected.remove(id)
        disconnectedServices[id] = nil
        quarantinedBatteryServices[id, default: []].formUnion(previousServiceIDs)
        sessionBatteryObservations[id] = nil
        batteryChangeRevisions[id] = nil
        invalidateReads()
        return true
    }

    public func isBlocked(_ id: String) -> Bool { blocked.contains(id) }

    /// A stale true after disconnect cannot re-add the device. A later false ->
    /// true transition can recover a missed connect notification.
    public mutating func acceptsClassicConnection(_ id: String, isConnected: Bool, now: Double? = nil,
                                                  serviceIDs: Set<UInt64> = [],
                                                  batteryServiceIDs: Set<UInt64>? = nil) -> Bool {
        guard isConnected else {
            if let deadline = pendingConnectConfirmation[id], let now, now.isFinite {
                if now < deadline, !blocked.contains(id) { return true }
                // Confirmation never arrived. This is an observed false getter
                // for an explicit connect, not a missing item in a device list.
                didDisconnect(id, serviceIDs: serviceIDs, batteryServiceIDs: batteryServiceIDs, at: now)
                return false
            }
            if confirmedClassicConnections.contains(id), !blocked.contains(id) {
                // A false getter after an actual true confirmation is strong
                // disconnect evidence even when the disconnect callback was lost.
                didDisconnect(id, serviceIDs: serviceIDs, batteryServiceIDs: batteryServiceIDs, at: now)
                observedDisconnected.insert(id)
                return false
            }
            if blocked.contains(id) { observedDisconnected.insert(id) }
            return false
        }
        pendingConnectConfirmation[id] = nil
        guard blocked.contains(id) else {
            confirmedClassicConnections.insert(id)
            return true
        }
        guard observedDisconnected.contains(id) else { return false }
        guard recoverConnection(id, observedAt: now) else { return false }
        confirmedClassicConnections.insert(id)
        return true
    }

    /// Old IOHID services can remain in the registry briefly after disconnect.
    /// Only a different known service identity establishes a new HID session.
    public mutating func acceptsRegistryConnection(_ id: String, serviceIDs: Set<UInt64>, now: Double? = nil) -> Bool {
        guard blocked.contains(id) else { return true }
        guard let previous = disconnectedServices[id], !previous.isEmpty,
              !serviceIDs.isEmpty, previous.isDisjoint(with: serviceIDs) else { return false }
        return recoverConnection(id, observedAt: now)
    }

    public func acceptsBattery(_ id: String, serviceIDs: Set<UInt64>) -> Bool {
        guard !blocked.contains(id) else { return false }
        guard let previous = quarantinedBatteryServices[id] else { return true }
        return previous.isDisjoint(with: serviceIDs)
    }

    /// Prefer the most recently changed complete source among currently
    /// available, current-session sources. Unchanged reads do not gain priority.
    public func preferredBatteryServiceIDs(for id: String, available: Set<UInt64>) -> Set<UInt64> {
        let fresh = available.filter { acceptsBattery(id, serviceIDs: [$0]) }
        guard let changes = batteryChangeRevisions[id],
              let latest = fresh.compactMap({ changes[$0] }).max() else { return fresh }
        return fresh.filter { changes[$0] == latest }
    }

    /// General IOKit interest can report any property change, including a name.
    /// Mark the source dirty; the next complete observation must prove a battery
    /// change between accepted current-session reads before old values can be
    /// treated as current-session data.
    public mutating func batteryPropertiesChanged(serviceID: UInt64, at time: Double? = nil) {
        invalidateReads()
    }

    /// Called only for an accepted asynchronous batch. Keeps complete source
    /// observations, so a name-only event cannot validate an old battery value.
    public mutating func observeBattery(_ id: String, serviceID: UInt64,
                                        observation: BluetoothRegistryBatteryObservation) {
        guard !blocked.contains(id) else { return }
        if quarantinedBatteryServices[id]?.contains(serviceID) == true {
            // First read after reconnect establishes a session boundary. A value
            // that changed while disconnected is still only a previous report.
            guard let previous = sessionBatteryObservations[id]?[serviceID] else {
                sessionBatteryObservations[id, default: [:]][serviceID] = observation
                batteryChangeRevisions[id, default: [:]][serviceID] = revision
                return
            }
            guard previous != observation else { return }
            quarantinedBatteryServices[id]?.remove(serviceID)
            if quarantinedBatteryServices[id]?.isEmpty == true { quarantinedBatteryServices[id] = nil }
        }
        if sessionBatteryObservations[id]?[serviceID] != observation {
            batteryChangeRevisions[id, default: [:]][serviceID] = revision
        }
        sessionBatteryObservations[id, default: [:]][serviceID] = observation
    }

    public mutating func suspend(serviceIDsByDevice: [String: Set<UInt64>]) {
        for (id, serviceIDs) in serviceIDsByDevice {
            quarantinedBatteryServices[id, default: []].formUnion(serviceIDs)
        }
        sessionBatteryObservations.removeAll()
        batteryChangeRevisions.removeAll()
        pendingConnectConfirmation.removeAll()
        confirmedClassicConnections.removeAll()
        // The wake boundary is a fresh system observation, unlike the first
        // stale callback immediately after a disconnect.
        observedDisconnected.formUnion(blocked)
        invalidateObservations()
    }

    private mutating func acceptsEvent(_ id: String, at time: Double?) -> Bool {
        guard let time else { return true }
        guard time.isFinite, time >= (lastEventAt[id] ?? -.infinity) else { return false }
        lastEventAt[id] = time
        return true
    }

    /// Only the recovery boundary advances event ordering. A regular true
    /// getter must not hide a genuine disconnect callback still in transit.
    private mutating func recoverConnection(_ id: String, observedAt time: Double?) -> Bool {
        guard didConnect(id, at: time) else { return false }
        // An observed recovery is already confirmed; it grants no optimistic
        // false-getter window even though its observation has a timestamp.
        pendingConnectConfirmation[id] = nil
        return true
    }
}
