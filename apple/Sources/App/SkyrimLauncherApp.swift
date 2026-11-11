import SwiftUI
#if os(visionOS) && SKYRIM_NATIVE_RUNTIME
import CompositorServices
#endif

@main
struct SkyrimLauncherApp: App {
    @StateObject private var model = LauncherModel()

    var body: some Scene {
        #if os(macOS)
        Window("Skyrim", id: "library") {
            LibraryView(model: model)
                .frame(minWidth: 600, minHeight: 680)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 960, height: 820)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appSettings) {
                Button("Check Game Files", action: model.refresh)
                    .keyboardShortcut("r")
                    .disabled(model.isBusy || model.isGameActive)
            }
        }
        #else
        WindowGroup("Skyrim") {
            LibraryView(model: model)
                .environment(\.skyrimGameActive, model.isGameActive)
                #if os(visionOS)
                .frame(minWidth: 640, minHeight: 700)
                #endif
                #if os(visionOS) && SKYRIM_NATIVE_RUNTIME
                // Tells SDL which window scene is the game's, before an ImmersiveSpace adds a second one.
                .background(GameSceneReporter())
                .modifier(ImmersiveGhost())
                #endif
                .preferredColorScheme(.dark)
        }
        #if os(visionOS)
        // A conventional flat window. Immersive spaces stay out until windowed play is accepted.
        .defaultSize(width: 900, height: 840)
        .windowResizability(.contentMinSize)
        #endif
        #if os(visionOS) && SKYRIM_NATIVE_RUNTIME
        // The glass comes from ImmersiveGhost, so it can go away while immersive play runs.
        .windowStyle(.plain)
        #endif
        #if os(visionOS) && SKYRIM_NATIVE_RUNTIME
        ImmersiveSpace(id: ImmersiveScreen.spaceID) {
            CompositorLayer(configuration: ImmersiveScreenConfiguration()) { layer in
                // Which spatial events (trackpad clicks, pinches) reach the layer: counted for the log
                // (docs/VISIONOS_POINTER_PLAN.md step 1).
                layer.onSpatialEvent = { events in
                    for event in events { SpatialEventLog.note(kind: "\(event.kind)", phase: "\(event.phase)") }
                }
                ImmersiveCompositor(layer: layer).start()
            }
        }
        .immersionStyle(selection: .constant(.full), in: .full)
        #endif
        #endif
    }
}

#if os(visionOS) && SKYRIM_NATIVE_RUNTIME
/// While the immersive layer runs, the launcher window (which also holds SDL's game window) turns nearly invisible
/// and loses its glass, so it doesn't cover the immersive picture; it stays in place as the trackpad's pointer
/// surface (docs/VISIONOS_POINTER_PLAN.md).
private struct ImmersiveGhost: ViewModifier {
    @State private var immersive = false
    func body(content: Content) -> some View {
        content
            .opacity(immersive ? 0.02 : 1)
            .glassBackgroundEffect(displayMode: immersive ? .never : .always)
            .onReceive(NotificationCenter.default.publisher(for: .skyrimImmersiveRunning)) { note in
                immersive = (note.object as? Bool) ?? false
            }
    }
}
#endif
