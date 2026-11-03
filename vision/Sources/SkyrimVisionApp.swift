import SwiftUI

@main
struct SkyrimVisionApp: App {
    @StateObject private var model = VisionLauncherModel()

    var body: some Scene {
        WindowGroup("Skyrim") {
            LauncherView(model: model)
                .frame(minWidth: 640, minHeight: 700)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 880, height: 820)
        .windowResizability(.contentMinSize)
    }
}
