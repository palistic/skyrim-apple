import SwiftUI
import UniformTypeIdentifiers

struct LauncherView: View {
    @ObservedObject var model: VisionLauncherModel
    @AppStorage("skyrim.launcher.accent") private var accentChoice = "gold"
    @State private var showSettings = false
    @State private var chooseFolder = false
    @State private var chooseArtwork = false
    @State private var pickerAfterSettings: PickerRequest?

    private enum PickerRequest { case folder, artwork }

    private var accent: Color { VisionSmokeTheme.accent(accentChoice) }

    var body: some View {
        GeometryReader { proxy in
            let coverWidth = min(280.0, max(220.0, (proxy.size.height - 360) * 2 / 3))
            ZStack {
                VisionSmokeBackground().ignoresSafeArea()
                VStack(spacing: 0) {
                    header
                    Spacer(minLength: 20)
                    VStack(spacing: 18) {
                        card(width: coverWidth)
                        Text(model.detail)
                            .font(.system(size: 13))
                            .foregroundStyle(VisionSmokeTheme.text.opacity(0.7))
                            .multilineTextAlignment(.center)
                            .lineLimit(3)
                            .frame(maxWidth: 420, minHeight: 38)
                    }
                    Spacer(minLength: 22)
                    footer
                }
            }
        }
        .foregroundStyle(VisionSmokeTheme.text)
        .tint(accent)
        .sheet(isPresented: $showSettings, onDismiss: openPendingPicker) { settings }
        .fileImporter(isPresented: $chooseFolder, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url): model.selectFolder(url)
            case .failure(let error): model.errorMessage = error.localizedDescription
            }
        }
        .fileImporter(isPresented: $chooseArtwork, allowedContentTypes: [.image]) { result in
            switch result {
            case .success(let url): model.importArtwork(url)
            case .failure(let error): model.errorMessage = error.localizedDescription
            }
        }
        .alert("Couldn't Complete That Step", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var header: some View {
        ZStack {
            HStack {
                Text("Library")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(VisionSmokeTheme.text.opacity(0.75))
                Spacer()
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 17, weight: .medium))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
                .accessibilityLabel("Settings")
            }
            Menu {
                Button("Settings…", systemImage: "gearshape") { showSettings = true }
                Button("Choose Game Folder…", systemImage: "folder") { chooseFolder = true }
                    .disabled(model.isChecking)
                if model.folderName != nil {
                    Button("Refresh Files", systemImage: "arrow.clockwise", action: model.refresh)
                        .disabled(model.isChecking)
                }
            } label: {
                VisionCapsuleLabel(accent: accent)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Skyrim main menu")
        }
        .padding(.horizontal, 32)
        .padding(.top, 22)
        .padding(.bottom, 8)
    }

    private func card(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomTrailing) {
                Button { chooseFolder = true } label: {
                    Group {
                        if let image = model.artworkImage {
                            Image(uiImage: image).resizable().scaledToFill()
                        } else {
                            VisionDefaultCover(accent: accent)
                        }
                    }
                    .frame(width: width, height: width * 1.5)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12).strokeBorder(accent.opacity(0.25), lineWidth: 1)
                    }
                }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
                .disabled(model.isChecking)
                .accessibilityLabel("Skyrim, \(model.headline)")
                .accessibilityHint("Choose the original game installation in Files")
                Menu {
                    Button("Change Artwork…", systemImage: "photo") { chooseArtwork = true }
                    if model.artworkImage != nil {
                        Button("Use Default Artwork", systemImage: "arrow.uturn.backward", action: model.useDefaultArtwork)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 44, height: 44)
                        .background(.black.opacity(0.45), in: Circle())
                }
                .buttonStyle(.plain)
                .padding(10)
                .accessibilityLabel("Skyrim artwork options")
            }
            VStack(alignment: .leading, spacing: 11) {
                Text("The Elder Scrolls V: Skyrim")
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                HStack(spacing: 6) {
                    if model.isChecking {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: model.coreFilesFound ? "checkmark.circle" : "tray")
                            .font(.system(size: 12))
                    }
                    Text(model.headline).font(.system(size: 12, weight: .medium)).lineLimit(2)
                }
                .foregroundStyle(accent.opacity(0.9))
                if model.coreFilesFound {
                    Button {} label: {
                        Label("Play Skyrim", systemImage: "play.fill")
                            .frame(maxWidth: .infinity, minHeight: 38)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.gameRuntimeLinked)
                    .accessibilityHint("A playable Vision Pro game build isn't installed yet")
                } else {
                    Button { chooseFolder = true } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "plus").font(.system(size: 12, weight: .semibold))
                            Text(model.isChecking ? "Checking…" : "Choose Game Folder")
                                .font(.system(size: 14, weight: .semibold))
                            Spacer()
                            Image(systemName: "arrow.up.right").font(.system(size: 11))
                        }
                        .padding(.horizontal, 13)
                        .frame(height: 40)
                        .foregroundStyle(Color.black.opacity(0.85))
                        .background(accent, in: RoundedRectangle(cornerRadius: 9))
                    }
                    .buttonStyle(.plain)
                    .hoverEffect(.highlight)
                    .disabled(model.isChecking)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 14)
            .padding(.bottom, 14)
        }
        .padding(6)
        .frame(width: width + 12)
        .background(VisionSmokeTheme.surface.opacity(0.92), in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16).strokeBorder(accent.opacity(0.35), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.3), radius: 24, y: 14)
    }

    private var footer: some View {
        HStack {
            Label("Original Windows edition", systemImage: "opticaldisc")
            Spacer()
            Text(model.folderName ?? "Vision Pro launcher")
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.system(size: 11))
        .foregroundStyle(VisionSmokeTheme.text.opacity(0.6))
        .padding(.horizontal, 32)
        .padding(.bottom, 22)
    }

    private var settings: some View {
        NavigationStack {
            Form {
                Section("Appearance") {
                    Picker("Accent", selection: $accentChoice) {
                        Text("Gold").tag("gold")
                        Text("White").tag("white")
                    }
                    .pickerStyle(.segmented)
                    Button("Choose Cover Artwork…", systemImage: "photo") {
                        pickerAfterSettings = .artwork
                        showSettings = false
                    }
                    if model.artworkImage != nil {
                        Button("Use Default Artwork", action: model.useDefaultArtwork)
                    }
                }
                Section {
                    LabeledContent("Folder", value: model.folderName ?? "Not selected")
                    Button("Choose Game Folder…", systemImage: "folder") {
                        pickerAfterSettings = .folder
                        showSettings = false
                    }
                    .disabled(model.isChecking)
                    if model.folderName != nil {
                        Button("Refresh Files", systemImage: "arrow.clockwise", action: model.refresh)
                            .disabled(model.isChecking)
                        Button("Unlink Game Folder", role: .destructive, action: model.unlinkFolder)
                            .disabled(model.isChecking)
                    }
                } header: {
                    Text("Game Files")
                } footer: {
                    Text("Select your original Windows Skyrim installation with TESV.exe, binkw32.dll and its complete Data folder. Unlinking only forgets the selection; it doesn't delete files.")
                }
                Section("About This Build") {
                    Text("This is the native launcher. It contains original launcher artwork and no Skyrim game assets. Playing requires your own game files and a playable game build, which isn't included yet.")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showSettings = false }
                }
            }
        }
        .frame(width: 520, height: 620)
        .tint(accent)
    }

    private func openPendingPicker() {
        let request = pickerAfterSettings
        pickerAfterSettings = nil
        switch request {
        case .folder: chooseFolder = true
        case .artwork: chooseArtwork = true
        case nil: break
        }
    }
}

private struct VisionDefaultCover: View {
    let accent: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                LinearGradient(colors: [Color(white: 0.13), Color(white: 0.035)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                VStack(spacing: 0) {
                    Text("THE ELDER SCROLLS V")
                        .font(.system(size: 9, weight: .medium, design: .serif))
                        .tracking(2)
                        .foregroundStyle(VisionSmokeTheme.text.opacity(0.7))
                        .padding(.top, 27)
                    Spacer(minLength: 8)
                    Image("LauncherArtwork")
                        .resizable()
                        .scaledToFit()
                        .frame(width: proxy.size.width * 0.86, height: proxy.size.width * 0.86)
                        .mask(LinearGradient(stops: [
                            .init(color: .clear, location: 0), .init(color: .white, location: 0.12),
                            .init(color: .white, location: 0.85), .init(color: .clear, location: 1)
                        ], startPoint: .top, endPoint: .bottom))
                    Text("SKYRIM")
                        .font(.system(size: 36, weight: .regular, design: .serif))
                        .tracking(5)
                    Rectangle().fill(accent.opacity(0.45)).frame(width: 30, height: 1).padding(.top, 13)
                    Spacer(minLength: 12)
                    Text("ORIGINAL EDITION")
                        .font(.system(size: 8, weight: .medium))
                        .tracking(2.3)
                        .foregroundStyle(VisionSmokeTheme.text.opacity(0.45))
                        .padding(.bottom, 22)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .accessibilityHidden(true)
    }
}
