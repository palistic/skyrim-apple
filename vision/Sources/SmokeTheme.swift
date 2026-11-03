import SwiftUI

enum VisionSmokeTheme {
    static let background = Color(red: 0.035, green: 0.041, blue: 0.049)
    static let surface = Color(red: 0.10, green: 0.112, blue: 0.128)
    static let text = Color(red: 0.94, green: 0.93, blue: 0.90)
    static let gold = Color(red: 0.80, green: 0.70, blue: 0.48)
    static func accent(_ choice: String) -> Color { choice == "white" ? text : gold }
}

struct VisionSmokeBackground: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var start = Date.now

    var body: some View {
        GeometryReader { proxy in
            TimelineView(.animation(minimumInterval: 1.0 / 30.0,
                                    paused: reduceMotion || scenePhase != .active)) { timeline in
                Rectangle()
                    .fill(VisionSmokeTheme.background)
                    .colorEffect(ShaderLibrary.default.smokeLauncherBackground(
                        .float2(proxy.size),
                        .float(reduceMotion ? 0 : Float(timeline.date.timeIntervalSince(start)))
                    ))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct VisionCapsuleLabel: View {
    let accent: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0,
                                paused: reduceMotion || scenePhase != .active)) { timeline in
            let phase = reduceMotion ? 1 : timeline.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: 3.6) / 3.6 * 4 - 2
            HStack(spacing: 8) {
                Image(systemName: "mountain.2").font(.system(size: 12, weight: .medium))
                Text("SKYRIM").font(.system(size: 12, weight: .semibold)).tracking(2.4)
            }
            .foregroundStyle(LinearGradient(colors: [accent, accent, .white, accent, accent],
                startPoint: UnitPoint(x: phase - 1, y: 0.5),
                endPoint: UnitPoint(x: phase + 1, y: 0.5)))
            .padding(.horizontal, 18)
            .padding(.vertical, 11)
            .background(VisionSmokeTheme.surface.opacity(0.9), in: Capsule())
            .overlay { Capsule().strokeBorder(accent.opacity(0.24), lineWidth: 1) }
        }
    }
}
