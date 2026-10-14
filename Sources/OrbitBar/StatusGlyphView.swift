import AppKit
import OrbitBarCore
import SwiftUI

/// Uses the same frame and geometry as the menu bar, including its volume pulse.
@MainActor
struct StatusGlyphView: View {
    let snapshot: SystemSnapshot
    @ObservedObject var settings: AppSettings
    let dark: Bool
    let size: CGFloat
    let animator: VolumeAnimator

    var body: some View {
        ZStack(alignment: .topLeading) {
            Image(nsImage: IconRenderer.image(snapshot: snapshot, settings: settings,
                                              dark: dark, canvasSize: size, drawVolumeDots: false))
            AnimatedVolumeDots(animator: animator, dark: dark, size: size)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Keep frame observation in the moving layer so the cached battery/network
/// image is not requested again on every animation tick.
@MainActor
private struct AnimatedVolumeDots: View {
    @ObservedObject var animator: VolumeAnimator
    let dark: Bool
    let size: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(0..<4) { index in
                let point = IconGeometry.dotCenter(index: index)
                let intensity = IconGeometry.dotIntensity(index: index, volume: animator.frame.volume)
                Circle()
                    .fill(dark ? Color.white : Color(white: 0.12))
                    .frame(width: IconGeometry.dotRadius * 2 * size / 32,
                           height: IconGeometry.dotRadius * 2 * size / 32)
                    .opacity(0.22 + intensity * 0.78)
                    .scaleEffect(0.86 + intensity * 0.14 + animator.frame.emphasis * intensity * 0.11)
                    .position(x: point.x * size / 32, y: (32 - point.y) * size / 32)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
