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
                #endif
                .preferredColorScheme(.dark)
        }
        #if os(visionOS)
        // A conventional flat window. Immersive spaces stay out until windowed play is accepted.
        .defaultSize(width: 900, height: 840)
        .windowResizability(.contentMinSize)
        #endif
        #if os(visionOS) && SKYRIM_NATIVE_RUNTIME
        ImmersiveSpace(id: ImmersiveScreen.spaceID) {
            CompositorLayer(configuration: ImmersiveScreenConfiguration()) { layer in
                ImmersiveCompositor(layer: layer).start()
            }
        }
        .immersionStyle(selection: .constant(.full), in: .full)
        #endif
        #endif
    }
}
