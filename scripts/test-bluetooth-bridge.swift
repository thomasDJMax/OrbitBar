import Combine
import Foundation
import OrbitBarCore

@MainActor
private final class FakePublishedOutput {
    @Published var audio = AudioState()
}

@main
private enum BluetoothBridgeRegressions {
    @MainActor
    static func main() async throws {
        func route(_ id: UInt32, _ name: String) -> AudioState {
            AudioState(outputName: name, outputDeviceID: id, outputUID: "device-\(id)",
                       outputIdentifier: "route-\(id)", outputKind: .bluetoothHeadphones)
        }
        let sender = FakePublishedOutput()
        sender.audio = route(1, "A")
        var received: [AudioState] = []
        let bridge = BluetoothOutputBridge(readCurrentAudio: { sender.audio }, refreshBluetooth: { received.append($0) })
        let subscription = sender.$audio.dropFirst().sink { next in
            // Simulates HAL's callback arriving inside a Bluetooth @Published
            // notification, before that outer sender has stored its next state.
            precondition(sender.audio != next)
            bridge.outputDidChange(next)
        }

        sender.audio = route(2, "B")
        precondition(received.isEmpty, "Cross-monitor refresh must not reenter the sender's willSet.")
        try await Task.sleep(for: .milliseconds(10))
        precondition(received.map(\.outputName) == ["B"], "Refresh must observe the committed new output.")

        received.removeAll()
        sender.audio = route(1, "A")
        sender.audio = route(2, "B")
        sender.audio = route(3, "C")
        try await Task.sleep(for: .milliseconds(10))
        precondition(received.map(\.outputName) == ["C"], "Rapid switches must cancel obsolete callbacks.")

        subscription.cancel()
        received.removeAll()
        bridge.outputDidChange(sender.audio)
        sender.audio = route(3, "Renamed C")
        try await Task.sleep(for: .milliseconds(10))
        precondition(received.map(\.outputName) == ["Renamed C"], "Read current presentation at the same actual route.")

        received.removeAll()
        bridge.outputDidChange(route(4, "D"))
        try await Task.sleep(for: .milliseconds(10))
        precondition(received.isEmpty, "A stale expected route must not refresh the wrong device.")

        bridge.outputDidChange(sender.audio)
        bridge.stop()
        bridge.outputDidChange(sender.audio)
        try await Task.sleep(for: .milliseconds(10))
        precondition(received.isEmpty, "Stopping must cancel pending and reject future callbacks.")

        var reentered = 0
        var reentrantBridge: BluetoothOutputBridge?
        reentrantBridge = BluetoothOutputBridge(readCurrentAudio: { sender.audio }, refreshBluetooth: { audio in
            reentered += 1
            if reentered == 1 { reentrantBridge?.outputDidChange(audio) }
        })
        reentrantBridge?.outputDidChange(sender.audio)
        try await Task.sleep(for: .milliseconds(10))
        precondition(reentered == 2, "A refresh-triggered callback must remain scheduled and finish once.")
        reentrantBridge?.stop()
        reentrantBridge = nil
        print("Bluetooth bridge regressions passed: committed state, rapid switches, current metadata, stale route, stop and reentry.")
    }
}
