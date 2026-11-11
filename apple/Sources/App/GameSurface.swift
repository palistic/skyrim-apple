#if os(visionOS) && SKYRIM_NATIVE_RUNTIME
import SwiftUI

/// The game's own window (LB_GAME_SCENE=1, docs/VISIONOS_POINTER_PLAN.md). SDL's game window attaches to this
/// scene. The window is also the trackpad's pointer surface: visionOS only delivers trackpad motion while the
/// pointer is over one of the app's windows, and on the headset (Minecraft port) the surface that worked was a
/// plain window about 2400x1300 filled with near-invisible black and a content shape. Fully clear windows,
/// hidden window controls and much larger windows got no input at all. During immersive play SDL's own view is
/// hidden, and this view's hover position feeds the edge turn.
struct GameSurfaceView: View {
    static let windowID = "game"
    @ObservedObject var model: LauncherModel

    var body: some View {
        GeometryReader { geometry in
            Color.black.opacity(0.001)
                .contentShape(Rectangle())
                .onContinuousHover(coordinateSpace: .local) { phase in
                    switch phase {
                    case .active(let point):
                        let width = max(geometry.size.width, 1)
                        skyrim_xr_hover(Float(point.x / width * 2 - 1))
                    case .ended:
                        skyrim_xr_hover_left()
                    }
                }
                .pointerStyle(.shape(Circle(), size: CGSize(width: 0.01, height: 0.01)))
        }
        .background(GameSceneReporter())
        .onAppear {
            guard model.playWhenGameWindowReady else { return }
            model.playWhenGameWindowReady = false
            // The reporter registered this scene in didMoveToWindow; start on the next turn so SDL sees it.
            DispatchQueue.main.async { model.play() }
        }
    }
}
#endif
