/// Only volume changes on an uninterrupted actual output animate. Initial
/// readings, reconnects and unavailable outputs settle without an old pulse.
public struct VolumeAnimationPolicy: Sendable {
    private var previous: AudioState?

    public init() {}

    public mutating func shouldAnimate(_ audio: AudioState) -> Bool {
        defer { previous = audio }
        guard audio.outputKind != .unavailable, let previous,
              previous.outputKind != .unavailable,
              let deviceID = audio.outputDeviceID, deviceID != 0,
              audio.outputIdentifier != nil else { return false }
        return audio.outputDeviceID == previous.outputDeviceID
            && audio.outputUID == previous.outputUID
            && audio.outputIdentifier == previous.outputIdentifier
    }
}
