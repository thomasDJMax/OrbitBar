import Foundation
import OrbitBarCore

/// Combine's @Published callback runs before the sender stores its new value.
/// Defer the cross-monitor callback so a nested refresh sees committed state.
@MainActor
final class BluetoothOutputBridge {
    private let readCurrentAudio: () -> AudioState
    private let refreshBluetooth: (AudioState) -> Void
    private var pending: Task<Void, Never>?
    private var isStopped = false

    init(readCurrentAudio: @escaping () -> AudioState, refreshBluetooth: @escaping (AudioState) -> Void) {
        self.readCurrentAudio = readCurrentAudio
        self.refreshBluetooth = refreshBluetooth
    }

    func outputDidChange(_ expected: AudioState) {
        guard !isStopped else { return }
        pending?.cancel()
        pending = Task { @MainActor [weak self] in
            guard !Task.isCancelled, let self, !self.isStopped else { return }
            let current = self.readCurrentAudio()
            guard current.outputDeviceID == expected.outputDeviceID,
                  current.outputUID == expected.outputUID,
                  current.outputIdentifier == expected.outputIdentifier else { return }
            self.pending = nil
            self.refreshBluetooth(current)
        }
    }

    func stop() {
        isStopped = true
        pending?.cancel()
        pending = nil
    }
}
