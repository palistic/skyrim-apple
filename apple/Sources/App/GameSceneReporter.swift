#if os(visionOS) && SKYRIM_NATIVE_RUNTIME
import SwiftUI
import UIKit

/// Registers the UIWindowScene this view lives in as the game's scene for SDL's visionOS overlay
/// (skyrim_sdl_set_game_scene). SDL attaches its game window there and sizes its display from it, so a
/// second scene (the M2 ImmersiveSpace) can never capture the game window. Re-registers whenever the view
/// moves to a window, which covers the scene being recreated.
struct GameSceneReporter: UIViewRepresentable {
    func makeUIView(context: Context) -> ReporterView { ReporterView() }
    func updateUIView(_ view: ReporterView, context: Context) {}

    final class ReporterView: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let scene = window?.windowScene else { return }
            skyrim_sdl_set_game_scene(Unmanaged.passUnretained(scene).toOpaque())
        }
    }
}
#endif
