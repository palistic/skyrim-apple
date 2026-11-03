import AppKit
import SwiftUI

private enum SmokeTheme {
    static let background = Color(red: 0.035, green: 0.041, blue: 0.049)
    static let surface = Color(red: 0.10, green: 0.112, blue: 0.128)
    static let text = Color(red: 0.94, green: 0.93, blue: 0.90)
    static let gold = Color(red: 0.80, green: 0.70, blue: 0.48)
    static func accent(_ choice: String) -> Color { choice == "white" ? text : gold }
}

@main
struct SkyrimLauncherApp: App {
    @StateObject private var model = LauncherModel()

    var body: some Scene {
        Window("Skyrim", id: "library") {
            LibraryView(model: model)
                .frame(minWidth: 580, minHeight: 650)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 960, height: 800)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appSettings) {
                Button("Choose Game Folder…", action: model.chooseFolder)
                    .keyboardShortcut("o")
                    .disabled(model.isBusy)
                Button("Refresh Status", action: model.refresh)
                    .keyboardShortcut("r")
                    .disabled(model.isBusy)
            }
        }
    }
}

private struct SmokeBackground: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date.now

    var body: some View {
        GeometryReader { proxy in
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { timeline in
                Rectangle()
                    .fill(SmokeTheme.background)
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

private struct LibraryView: View {
    @ObservedObject var model: LauncherModel
    @AppStorage("skyrim.launcher.accent") private var accentChoice = "gold"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showSettings = false
    @State private var hovering = false

    private var accent: Color { SmokeTheme.accent(accentChoice) }

    var body: some View {
        GeometryReader { proxy in
            let coverWidth = min(276.0, max(202.0, (proxy.size.height - 335) * 2 / 3))
            ZStack {
                SmokeBackground().ignoresSafeArea()
                VStack(spacing: 0) {
                    header
                    Spacer(minLength: 20)
                    VStack(spacing: 18) {
                        gameCard(coverWidth: coverWidth)
                            .scaleEffect(hovering && !reduceMotion && !model.isBusy ? 1.012 : 1)
                            .animation(.easeOut(duration: 0.2), value: hovering)
                            .onHover { hovering = $0 }
                        Text(model.isBusy ? model.operation : model.detail)
                            .font(.system(size: 12))
                            .foregroundStyle(SmokeTheme.text.opacity(0.62))
                            .multilineTextAlignment(.center)
                            .lineLimit(3)
                            .frame(maxWidth: 390, minHeight: 32)
                            .padding(.horizontal, 20)
                    }
                    Spacer(minLength: 28)
                    footer
                }
            }
        }
        .tint(accent)
        .foregroundStyle(SmokeTheme.text)
        .sheet(isPresented: $showSettings) { settings }
        .alert("Couldn't Complete That Step", isPresented: Binding(
            get: { model.lastError != nil },
            set: { if !$0 { model.lastError = nil } }
        )) {
            Button("View Log", action: model.revealLog)
            Button("OK", role: .cancel) { model.lastError = nil }
        } message: {
            Text(model.lastError ?? "")
        }
    }

    private var header: some View {
        ZStack {
            HStack {
                Text("Library")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(SmokeTheme.text.opacity(0.72))
                Spacer()
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 16, weight: .medium))
                        .frame(width: 34, height: 34)
                        .background(.white.opacity(0.035), in: Circle())
                }
                .buttonStyle(.plain)
                .help("Settings")
                .accessibilityLabel("Settings")
            }
            Menu {
                Button("Settings…") { showSettings = true }
                Button("Choose Game Folder…", action: model.chooseFolder).disabled(model.isBusy)
                Button("Open Saves", action: model.revealSaves)
                Divider()
                Button("Refresh Status", action: model.refresh).disabled(model.isBusy)
            } label: {
                CapsuleLabel(accent: accent)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Skyrim main menu")
        }
        .padding(.horizontal, 30)
        .padding(.top, 34)
        .padding(.bottom, 8)
    }

    private func gameCard(coverWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomTrailing) {
                Button(action: activate) {
                    Group {
                        if let url = model.artworkURL, let image = NSImage(contentsOf: url) {
                            Image(nsImage: image).resizable().scaledToFill()
                        } else {
                            SkyrimCover(accent: accent)
                        }
                    }
                    .frame(width: coverWidth, height: coverWidth * 1.5)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(accent.opacity(0.26), lineWidth: 1)
                    }
                }
                .buttonStyle(.plain)
                .disabled(model.isBusy)
                .accessibilityLabel("Skyrim, \(model.headline)")
                .accessibilityHint(model.isReady ? "Starts Skyrim" :
                    (model.canPrepare ? "Prepares and builds Skyrim" : "Choose the original game folder"))
                Menu {
                    Button("Change Artwork…", action: model.chooseArtwork)
                    if model.artworkURL != nil {
                        Button("Use Default Artwork", action: model.resetArtwork)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 30, height: 30)
                        .background(.black.opacity(0.48), in: Circle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .padding(10)
                .accessibilityLabel("Skyrim artwork options")
            }
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("The Elder Scrolls V: Skyrim")
                            .font(.system(size: 14, weight: .semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                        HStack(spacing: 5) {
                            if model.isBusy {
                                ProgressView().controlSize(.mini)
                            } else {
                                Image(systemName: model.isReady ? "checkmark.circle" : "tray")
                                    .font(.system(size: 10))
                            }
                            Text(model.headline).font(.system(size: 11, weight: .medium))
                        }
                        .foregroundStyle(accent.opacity(0.85))
                    }
                    Spacer(minLength: 0)
                }
                Button(action: activate) {
                    HStack(spacing: 7) {
                        Image(systemName: model.isReady ? "play.fill" : "plus")
                            .font(.system(size: 10, weight: .semibold))
                        Text(actionTitle).font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Image(systemName: "arrow.up.right").font(.system(size: 10))
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    .foregroundStyle(Color.black.opacity(0.82))
                    .background(accent, in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .disabled(model.isBusy)
                .opacity(model.isBusy ? 0.6 : 1)
            }
            .padding(.horizontal, 10)
            .padding(.top, 13)
            .padding(.bottom, 12)
        }
        .padding(6)
        .frame(width: coverWidth + 12)
        .background(SmokeTheme.surface.opacity(0.94), in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16).strokeBorder(accent.opacity(0.32), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.32), radius: 28, y: 16)
    }

    private var actionTitle: String {
        if model.isBusy { return model.operation == "Running" ? "Running…" : "Please Wait…" }
        if model.isReady { return "Play Skyrim" }
        return model.canPrepare ? "Prepare Skyrim" : "Choose Game Folder"
    }

    private func activate() {
        guard !model.isBusy else { return }
        if model.isReady { model.launchGame() }
        else if model.canPrepare { model.prepareAndBuild() }
        else { model.chooseFolder() }
    }

    private var footer: some View {
        HStack {
            Label("Original Windows edition", systemImage: "opticaldisc")
            Spacer()
            if let directory = model.gameDirectory {
                Button {
                    NSWorkspace.shared.open(directory)
                } label: {
                    Label(directory.lastPathComponent, systemImage: "folder")
                }
                .buttonStyle(.plain)
                .lineLimit(1)
                .help(directory.path)
            } else {
                Text("macOS")
            }
        }
        .font(.system(size: 10))
        .foregroundStyle(SmokeTheme.text.opacity(0.6))
        .padding(.horizontal, 30)
        .padding(.bottom, 22)
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                Text("Settings").font(.system(size: 22, weight: .semibold))
                Spacer()
                Button("Done") { showSettings = false }.keyboardShortcut(.defaultAction)
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("Appearance").font(.headline)
                Picker("Accent", selection: $accentChoice) {
                    Text("Gold").tag("gold")
                    Text("White").tag("white")
                }.pickerStyle(.segmented)
            }
            Divider().overlay(.white.opacity(0.06))
            VStack(alignment: .leading, spacing: 12) {
                Text("Game Files").font(.headline)
                Text(model.gameDirectory?.path ?? "No game folder selected")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .textSelection(.enabled).lineLimit(3)
                Button("Choose Game Folder…", action: model.chooseFolder).disabled(model.isBusy)
                Text("Use your original 2011 Skyrim installation, including TESV.exe, binkw32.dll and the complete Data folder.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Divider().overlay(.white.opacity(0.06))
            HStack {
                Button("Open Saves", action: model.revealSaves)
                Button("View Log", action: model.revealLog)
                Spacer()
                Button("Refresh Status", action: model.refresh).disabled(model.isBusy)
            }
        }
        .padding(28)
        .frame(width: 440)
        .background(SmokeTheme.background)
        .preferredColorScheme(.dark)
        .tint(accent)
    }
}

private struct CapsuleLabel: View {
    let accent: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { timeline in
            let phase = reduceMotion ? 1 : timeline.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: 3.6) / 3.6 * 4 - 2
            HStack(spacing: 7) {
                Image(systemName: "mountain.2").font(.system(size: 10, weight: .medium))
                Text("SKYRIM").font(.system(size: 10, weight: .semibold)).tracking(2)
            }
            .foregroundStyle(LinearGradient(
                colors: [accent, accent, .white, accent, accent],
                startPoint: UnitPoint(x: phase - 1, y: 0.5),
                endPoint: UnitPoint(x: phase + 1, y: 0.5)))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(SmokeTheme.surface.opacity(0.9), in: Capsule())
            .overlay { Capsule().strokeBorder(accent.opacity(0.22), lineWidth: 1) }
            .shadow(color: accent.opacity(0.08), radius: 10)
        }
    }
}

private struct SkyrimCover: View {
    let accent: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                LinearGradient(colors: [Color(white: 0.20), Color(white: 0.095), .black],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                MountainRange()
                    .fill(LinearGradient(colors: [Color(white: 0.34), Color(white: 0.10)],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(height: proxy.size.height * 0.36)
                    .offset(y: proxy.size.height * 0.32)
                MountainRange()
                    .fill(Color.black.opacity(0.7))
                    .frame(height: proxy.size.height * 0.24)
                    .scaleEffect(x: -1, y: 1)
                    .offset(y: proxy.size.height * 0.43)
                VStack(spacing: 0) {
                    Text("THE ELDER SCROLLS V")
                        .font(.system(size: 8, weight: .medium, design: .serif))
                        .tracking(2.1)
                        .foregroundStyle(SmokeTheme.text.opacity(0.7))
                        .padding(.top, 42)
                    Spacer()
                    NordicMark()
                        .stroke(LinearGradient(colors: [.white.opacity(0.88), accent.opacity(0.7), .white.opacity(0.35)],
                                               startPoint: .topLeading, endPoint: .bottomTrailing),
                                style: StrokeStyle(lineWidth: 2, lineCap: .square, lineJoin: .miter))
                        .frame(width: 84, height: 146)
                        .shadow(color: .white.opacity(0.12), radius: 16)
                    Spacer().frame(height: 24)
                    Text("SKYRIM")
                        .font(.system(size: 36, weight: .regular, design: .serif))
                        .tracking(5)
                        .foregroundStyle(SmokeTheme.text)
                    Rectangle().fill(accent.opacity(0.5)).frame(width: 28, height: 1).padding(.top, 15)
                    Spacer()
                    Text("ORIGINAL EDITION")
                        .font(.system(size: 7, weight: .medium))
                        .tracking(2.4)
                        .foregroundStyle(SmokeTheme.text.opacity(0.4))
                        .padding(.bottom, 24)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .accessibilityHidden(true)
    }
}

private struct MountainRange: Shape {
    func path(in rect: CGRect) -> Path {
        let points: [(CGFloat, CGFloat)] = [(0,0.7),(0.11,0.56),(0.19,0.64),(0.39,0.16),(0.48,0.42),
                                           (0.59,0.29),(0.72,0.62),(0.83,0.48),(1,0.78),(1,1),(0,1)]
        return Path { p in
            p.move(to: CGPoint(x: rect.width * points[0].0, y: rect.height * points[0].1))
            for point in points.dropFirst() { p.addLine(to: CGPoint(x: rect.width * point.0, y: rect.height * point.1)) }
            p.closeSubpath()
        }
    }
}

private struct NordicMark: Shape {
    func path(in r: CGRect) -> Path {
        // Authored Nordic motif, separate from the game's owned artwork.
        let lines: [[(CGFloat,CGFloat)]] = [
            [(0.5,0.02),(0.8,0.28),(0.66,0.49),(0.77,0.68),(0.5,0.98),(0.23,0.68),(0.34,0.49),(0.2,0.28),(0.5,0.02)],
            [(0.5,0.12),(0.5,0.88)], [(0.5,0.34),(0.29,0.23)],[(0.5,0.34),(0.71,0.23)],
            [(0.5,0.55),(0.35,0.7),(0.5,0.82),(0.65,0.7),(0.5,0.55)],
            [(0.24,0.42),(0.08,0.32),(0.16,0.56),(0.32,0.62)],
            [(0.76,0.42),(0.92,0.32),(0.84,0.56),(0.68,0.62)]
        ]
        return Path { path in
            for line in lines {
                path.move(to: CGPoint(x: line[0].0*r.width, y: line[0].1*r.height))
                for point in line.dropFirst() { path.addLine(to: CGPoint(x: point.0*r.width, y: point.1*r.height)) }
            }
        }
    }
}
