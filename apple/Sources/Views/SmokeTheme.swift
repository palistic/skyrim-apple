import SwiftUI

enum SmokeTheme {
    static let background = Color(red: 0.035, green: 0.041, blue: 0.049)
    static let surface = Color(red: 0.10, green: 0.112, blue: 0.128)
    static let text = Color(red: 0.94, green: 0.93, blue: 0.90)
    static let gold = Color(red: 0.80, green: 0.70, blue: 0.48)
    static func accent(_ choice: LauncherPreferences.Accent) -> Color { choice == .white ? text : gold }
}

extension EnvironmentValues {
    /// A game is running or paused. On iPad it runs in this app's own process, so the launcher's
    /// animations stop to leave the main thread and GPU to the game.
    @Entry var skyrimGameActive = false
}

/// The Dark Eco smoke shader recoloured gray. It stops animating for Reduce Motion, the
/// launcher's own Reduce Smoke Motion setting, an inactive scene or a running game.
struct SmokeBackground: View {
    let reduceSmoke: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.skyrimGameActive) private var gameActive
    @State private var start = Date.now

    var body: some View {
        let still = reduceMotion || reduceSmoke || scenePhase != .active || gameActive
        GeometryReader { proxy in
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: still)) { timeline in
                Rectangle()
                    .fill(SmokeTheme.background)
                    .colorEffect(ShaderLibrary.default.smokeLauncherBackground(
                        .float2(proxy.size),
                        .float(still ? 0 : Float(timeline.date.timeIntervalSince(start)))
                    ))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct CapsuleLabel: View {
    let accent: Color
    var large = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.skyrimGameActive) private var gameActive

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0,
                                paused: reduceMotion || scenePhase != .active || gameActive)) { timeline in
            let phase = reduceMotion ? 1 : timeline.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: 3.6) / 3.6 * 4 - 2
            HStack(spacing: large ? 8 : 7) {
                Image(systemName: "mountain.2").font(.system(size: large ? 12 : 10, weight: .medium))
                Text("SKYRIM").font(.system(size: large ? 12 : 10, weight: .semibold)).tracking(large ? 2.4 : 2)
            }
            .foregroundStyle(LinearGradient(colors: [accent, accent, .white, accent, accent],
                                            startPoint: UnitPoint(x: phase - 1, y: 0.5),
                                            endPoint: UnitPoint(x: phase + 1, y: 0.5)))
            .padding(.horizontal, large ? 18 : 14)
            .padding(.vertical, large ? 11 : 8)
            .background(SmokeTheme.surface.opacity(0.9), in: Capsule())
            .overlay { Capsule().strokeBorder(accent.opacity(0.22), lineWidth: 1) }
            .shadow(color: accent.opacity(0.08), radius: 10)
        }
    }
}

/// Original launcher cover: the custom silver and gold crest, never retail game artwork.
struct DefaultCover: View {
    let accent: Color

    var body: some View {
        GeometryReader { proxy in
            let scale = proxy.size.width / 280
            ZStack {
                LinearGradient(colors: [Color(white: 0.13), Color(white: 0.035)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                VStack(spacing: 0) {
                    Text("THE ELDER SCROLLS V")
                        .font(.system(size: max(7, 9 * scale), weight: .medium, design: .serif))
                        .tracking(2 * scale)
                        .foregroundStyle(SmokeTheme.text.opacity(0.7))
                        .padding(.top, 27 * scale)
                    Spacer(minLength: 4)
                    Image("LauncherArtwork")
                        .resizable()
                        .scaledToFit()
                        .frame(width: proxy.size.width * 0.86, height: proxy.size.width * 0.86)
                        .mask(LinearGradient(stops: [
                            .init(color: .clear, location: 0), .init(color: .white, location: 0.12),
                            .init(color: .white, location: 0.85), .init(color: .clear, location: 1)
                        ], startPoint: .top, endPoint: .bottom))
                    Text("SKYRIM")
                        .font(.system(size: 36 * scale, weight: .regular, design: .serif))
                        .tracking(5 * scale)
                        .foregroundStyle(SmokeTheme.text)
                    Rectangle().fill(accent.opacity(0.45)).frame(width: 30 * scale, height: 1).padding(.top, 13 * scale)
                    Spacer(minLength: 6)
                    Text("ORIGINAL EDITION")
                        .font(.system(size: max(6, 8 * scale), weight: .medium))
                        .tracking(2.3 * scale)
                        .foregroundStyle(SmokeTheme.text.opacity(0.45))
                        .padding(.bottom, 22 * scale)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .accessibilityHidden(true)
    }
}

extension View {
    /// Highlight on pointer and gaze hover where the platform supports it.
    @ViewBuilder func launcherHover() -> some View {
        #if os(macOS)
        self
        #else
        self.hoverEffect(.highlight)
        #endif
    }
}
