import SwiftUI
import UniformTypeIdentifiers

/// Settings adapted from Dark Eco's iOS settings: Game, Controls, Graphics, iCloud, Manage Save
/// Files, Appearance and About, each on its own page. Every control here changes something real;
/// unavailable features are described rather than offered as switches.
struct SettingsView: View {
    enum Page: String, Hashable, CaseIterable {
        case files, controls, graphics, icloud, saves, appearance, about
    }

    @ObservedObject var model: LauncherModel
    @Environment(\.dismiss) private var dismiss
    @State private var path: [Page] = []
    @State private var confirmReset = false
    @State private var confirmQuit = false

    private var accent: Color { SmokeTheme.accent(model.preferences.accent) }

    var body: some View {
        NavigationStack(path: $path) {
            Form {
                #if os(macOS)
                if model.isGameActive {
                    Section {
                        Button(role: .destructive) { confirmQuit = true } label: {
                            Label("Quit Game", systemImage: "rectangle.portrait.and.arrow.right")
                        }
                    } footer: {
                        Text("Closes the running game. Progress since your last in-game save will be lost.")
                    }
                }
                #endif
                Section("Game") {
                    NavigationLink(value: Page.files) {
                        SettingsRow("Game Files", symbol: "folder", value: model.folderName ?? "Not selected")
                    }
                    SettingsRow("Runtime", symbol: "cpu", value: model.runtimeSummary)
                }
                Section {
                    NavigationLink(value: Page.controls) {
                        SettingsRow("Controls", symbol: "gamecontroller",
                                    value: model.input.canLaunch ? model.input.activeInputName : "Not connected")
                    }
                    NavigationLink(value: Page.graphics) {
                        SettingsRow("Graphics", symbol: "display", value: "Windowed")
                    }
                }
                Section("iCloud") {
                    Label(model.saveSync.status, systemImage: cloudSymbol)
                    NavigationLink(value: Page.icloud) {
                        SettingsRow("Sync Options", symbol: "icloud", value: nil)
                    }
                }
                Section {
                    NavigationLink(value: Page.saves) {
                        SettingsRow("Manage Save Files", symbol: "externaldrive",
                                    value: model.saves.saves.isEmpty ? "No saves" : "\(model.saves.saves.count)")
                    }
                    NavigationLink(value: Page.appearance) {
                        SettingsRow("Appearance", symbol: "paintbrush", value: model.preferences.accent.title)
                    }
                }
                Section {
                    Button("Reset Appearance to Defaults", role: .destructive) { confirmReset = true }
                }
                Section {
                    NavigationLink(value: Page.about) {
                        SettingsRow("About", symbol: "info.circle", value: nil)
                    }
                } footer: {
                    HStack {
                        Spacer()
                        Text(AboutView.versionText).font(.caption2)
                        Spacer()
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Settings")
            .navigationDestination(for: Page.self) { page in
                switch page {
                case .files: GameFilesSettingsView(model: model)
                case .controls: ControlsSettingsView(model: model)
                case .graphics: GraphicsSettingsView(model: model)
                case .icloud: CloudSettingsView(model: model)
                case .saves: SavedGamesView(model: model)
                case .appearance: AppearanceSettingsView(model: model)
                case .about: AboutView(model: model)
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog("Reset appearance?", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Reset Appearance", role: .destructive) { model.preferences.resetAppearance() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Restores the gold accent and animated smoke. Game files, saves and sync choices aren't changed.")
            }
            .confirmationDialog("Quit Skyrim?", isPresented: $confirmQuit, titleVisibility: .visible) {
                Button("Quit Game", role: .destructive) { model.quitGame() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Progress since your last in-game save will be lost.")
            }
        }
        .tint(accent)
        .preferredColorScheme(.dark)
        #if os(macOS)
        .frame(minWidth: 540, idealWidth: 560, minHeight: 620, idealHeight: 700)
        #elseif os(visionOS)
        .frame(width: 620, height: 720)
        #endif
        .alert("Couldn't Complete That Step", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var cloudSymbol: String {
        if model.saveSync.isSyncing { return "arrow.triangle.2.circlepath.icloud" }
        if !model.preferences.cloudSyncEnabled { return "icloud.slash" }
        if model.saveSync.status.contains("unavailable") || model.saveSync.status.contains("attention")
            || model.saveSync.needsAccountRecovery { return "exclamationmark.icloud" }
        return model.saveSync.lastSyncDate == nil ? "icloud" : "checkmark.icloud"
    }
}

struct SettingsRow: View {
    let title: String
    let symbol: String
    let value: String?
    init(_ title: String, symbol: String, value: String?) {
        self.title = title; self.symbol = symbol; self.value = value
    }
    var body: some View {
        if let value {
            LabeledContent { Text(value).lineLimit(1) } label: { Label(title, systemImage: symbol) }
        } else {
            Label(title, systemImage: symbol)
        }
    }
}

// MARK: Game Files

struct GameFilesSettingsView: View {
    @ObservedObject var model: LauncherModel
    @State private var choosing = false
    @State private var confirmUnlink = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Folder", value: model.folderName ?? "Not selected")
                #if os(macOS)
                if let path = model.folderPath {
                    Text(path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(3)
                }
                #endif
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        if model.isBusy { ProgressView().controlSize(.small) }
                        Text(model.headline)
                    }
                }
                Text(model.detail).font(.callout).foregroundStyle(.secondary)
            }
            Section {
                Button("Choose Game Folder…", systemImage: "folder") { choosing = true }
                    .disabled(model.isBusy || model.isGameActive)
                Button("Check Game Files", systemImage: "arrow.clockwise", action: model.refresh)
                    .disabled(model.isBusy || model.isGameActive || (model.folderName == nil && model.runtime == .notLinked))
                #if os(macOS)
                if model.canPrepare {
                    Button("Prepare Skyrim", systemImage: "hammer", action: model.prepare)
                        .disabled(model.isBusy || model.isGameActive)
                }
                if let log = model.logURL {
                    Button("Show Last Log", systemImage: "doc.text.magnifyingglass") {
                        NSWorkspace.shared.activateFileViewerSelecting([log])
                    }
                }
                #endif
                if model.folderName != nil {
                    Button("Unlink Game Folder", role: .destructive) { confirmUnlink = true }
                        .disabled(model.isBusy || model.isGameActive)
                }
            } footer: {
                Text("Use your original Windows Skyrim 1.9.32.0.8 installation with TESV.exe, binkw32.dll and its complete Data folder. Checking only reads files. Unlinking forgets the selection and never deletes anything.")
            }
            Section("Runtime") {
                LabeledContent("Status", value: model.runtimeSummary)
                Text(runtimeExplanation).font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Game Files")
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url): model.selectFolder(url)
            case .failure(let error): model.errorMessage = error.localizedDescription
            }
        }
        .confirmationDialog("Unlink the game folder?", isPresented: $confirmUnlink, titleVisibility: .visible) {
            Button("Unlink", role: .destructive, action: model.unlinkFolder)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The launcher forgets this folder. Your installation and saves aren't changed.")
        }
    }

    private var runtimeExplanation: String {
        switch model.runtime {
        case .macBridge:
            return "This Mac launcher uses your local Skyrim workspace to prepare a private native ARM64 build from your own files, then starts it. It isn't a standalone game distribution, and gameplay hasn't been accepted yet."
        case .bridgeMissing:
            return "This build can't find the local workspace it was built from, so it can't prepare or start the game."
        case .notLinked:
            return "This \(LauncherPlatform.name) build is the launcher only. The native Skyrim runtime isn't linked into it yet, so Play stays locked even when your files check out."
        case .nativeDevice:
            return "This \(LauncherPlatform.name) build includes the native Skyrim runtime: the original Windows game's code, translated ahead of time to ARM64, runs here without a JIT, from your own files in this app's Skyrim folder. Gameplay on this \(LauncherPlatform.name) hasn't been accepted yet."
        }
    }
}

// MARK: Controls

struct ControlsSettingsView: View {
    @ObservedObject var model: LauncherModel

    var body: some View {
        let input = model.input
        Form {
            Section {
                requirement("DualSense", symbol: "gamecontroller", connected: input.connectedDualSense)
                requirement("Keyboard", symbol: "keyboard", connected: input.hasKeyboard)
                requirement("Mouse", symbol: "computermouse", connected: input.hasMouse)
                LabeledContent("Play", value: input.canLaunch ? "Ready with \(input.activeInputName)" : "Locked")
            } header: {
                Text("Play Requirement")
            } footer: {
                Text("Skyrim starts only with a DualSense controller, or with both a physical keyboard and a mouse. Touch, on-screen controls and other controllers can't start or resume the game.")
            }
            Section {
                LabeledContent("Pause on disconnect", value: "Always on")
                LabeledContent("Resume", value: "Manual only")
                LabeledContent("Drops this launch", value: "\(input.disconnectGeneration)")
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let recent = ResumePolicy.recentDisconnects(input.disconnectDates, now: context.date)
                    LabeledContent("Drops in last 30 seconds", value: "\(recent)")
                }
            } header: {
                Text("Disconnects")
            } footer: {
                Text("Losing the DualSense, keyboard or mouse pauses the game, even if it reconnects right away. Resume unlocks after the connection settles; three drops within 30 seconds require 10 quiet seconds first.")
            }
            Section {
                Text("Key and button bindings are set in Skyrim's own Controls menu and saved with the game, so the launcher doesn't duplicate them.")
                    .foregroundStyle(.secondary)
            } header: {
                Text("Bindings")
            }
            Section {
                LabeledContent("Status", value: "Planned · not enabled")
            } header: {
                Text("PlayStation VR2 Sense")
            } footer: {
                Text("Windowed play with a DualSense or keyboard and mouse comes first. Sense controllers can't start the game in this build.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Controls")
    }

    private func requirement(_ title: String, symbol: String, connected: Bool) -> some View {
        LabeledContent {
            Label(connected ? "Connected" : "Not connected",
                  systemImage: connected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(connected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        } label: {
            Label(title, systemImage: symbol)
        }
    }
}

// MARK: Graphics

struct GraphicsSettingsView: View {
    @ObservedObject var model: LauncherModel

    var body: some View {
        Form {
            Section {
                LabeledContent("Mode", value: "Windowed")
                LabeledContent("Immersive", value: "Not available")
            } header: {
                Text("Presentation")
            } footer: {
                Text("Skyrim runs in a conventional window first. Immersive presentation isn't offered until windowed play has been accepted.")
            }
            #if os(macOS)
            Section {
                LabeledContent("Renderer", value: "DXVK on MoltenVK (Metal)")
                ForEach(runtimeConfig, id: \.0) { entry in
                    LabeledContent(entry.0, value: entry.1)
                }
            } header: {
                Text("This Mac's Runtime")
            } footer: {
                Text("Read from macos/runtime.conf in your workspace. The launcher shows it but doesn't change it.")
            }
            #else
            Section {
                LabeledContent("Game runtime", value: "Not installed")
            } header: {
                Text("This \(LauncherPlatform.name)")
            } footer: {
                Text("No game graphics settings can apply on this device until its runtime is installed, so none are offered here.")
            }
            #endif
            Section {
                Text("Resolution, quality and display options are set in Skyrim's own Options menu and saved in SkyrimPrefs.ini with your profile. The original first-run preset is preserved.")
                    .foregroundStyle(.secondary)
            } header: {
                Text("In-Game Options")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Graphics")
    }

    #if os(macOS)
    private var runtimeConfig: [(String, String)] {
        guard let checkout = MacRuntimeBridge.checkoutDirectory(),
              let text = try? String(contentsOf: checkout.appendingPathComponent("macos/runtime.conf"), encoding: .utf8)
        else { return [("Configuration", "Not found")] }
        return text.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#"), let equals = trimmed.firstIndex(of: "=") else { return nil }
            return (trimmed[..<equals].trimmingCharacters(in: .whitespaces),
                    trimmed[trimmed.index(after: equals)...].trimmingCharacters(in: .whitespaces))
        }
    }
    #endif
}

// MARK: iCloud

struct CloudSettingsView: View {
    @ObservedObject var model: LauncherModel
    @State private var confirmReset = false

    var body: some View {
        let preferences = model.preferences
        let sync = model.saveSync
        let configured = CloudCapability.isConfiguredInBuild
        Form {
            Section {
                HStack(spacing: 10) {
                    if sync.isSyncing { ProgressView().controlSize(.small) }
                    Text(sync.status).font(.headline)
                }
                Text(sync.detail).font(.callout).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Sync Settings", isOn: Binding(get: { preferences.settingsSyncEnabled },
                                                      set: { preferences.settingsSyncEnabled = $0 }))
                    .disabled(!configured)
                LabeledContent("Settings", value: preferences.cloudPreferencesStatus)
                if let date = preferences.lastSettingsSyncDate, preferences.settingsSyncEnabled {
                    LabeledContent("Last settings sync", value: date.formatted(date: .abbreviated, time: .shortened))
                }
                Toggle("Sync Saves", isOn: Binding(get: { preferences.cloudSyncEnabled },
                                                   set: { preferences.cloudSyncEnabled = $0 }))
                    .disabled(!configured || sync.isSyncing)
                LabeledContent("Saves", value: sync.status)
                if let date = sync.lastSyncDate, preferences.cloudSyncEnabled {
                    LabeledContent("Last saves sync", value: date.formatted(date: .abbreviated, time: .shortened))
                }
                Button("Sync Saves Now", systemImage: "arrow.triangle.2.circlepath") {
                    Task {
                        await sync.syncNow(gameIsRunning: model.isGameActive)
                        await model.saves.refresh()
                    }
                }
                .disabled(!configured || !preferences.cloudSyncEnabled || sync.isSyncing || model.isGameActive)
            } header: {
                Text("Sync Options")
            } footer: {
                Text(configured
                     ? "Choose settings and save sync independently on this device."
                     : "This build is signed without iCloud, so sync can't be turned on. Saves and settings stay on this device.")
            }
            if sync.needsAccountRecovery {
                Section {
                    Button("Reset iCloud Pairing", role: .destructive) { confirmReset = true }
                } footer: {
                    Text("Use this only if you meant to change iCloud accounts. Saves on this device stay in place, and any differing copies are preserved on the next sync.")
                }
            }
            Section("How Save Sync Works") {
                bullet("Saves are always written on this device first; iCloud is a mirror.")
                bullet("Only original Skyrim .ess saves sync. Game files, settings files and the runtime never do.")
                bullet("Sync never runs while the game is running or paused.")
                bullet("When copies differ, both are kept in Preserved Saves and the newest becomes active.")
                bullet("Deleting a save doesn't delete it from iCloud; it may return after the next sync.")
            }
            Section("This Build") {
                LabeledContent("iCloud capability", value: configured ? "Included" : "Not included")
                LabeledContent("Container", value: CloudCapability.containerIdentifier ?? "None")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("iCloud")
        .confirmationDialog("Reset iCloud pairing?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset Pairing", role: .destructive, action: sync.resetCloudPairing)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The next sync compares this device with the current iCloud account and preserves both copies of anything that differs.")
        }
    }

    private func bullet(_ text: String) -> some View {
        Label { Text(text).font(.callout) } icon: { Image(systemName: "circle.fill").font(.system(size: 5)) }
            .foregroundStyle(.secondary)
    }
}

// MARK: Appearance

struct AppearanceSettingsView: View {
    @ObservedObject var model: LauncherModel
    @State private var choosing = false

    var body: some View {
        let preferences = model.preferences
        Form {
            Section("Accent") {
                Picker("Accent", selection: Binding(get: { preferences.accent }, set: { preferences.accent = $0 })) {
                    ForEach(LauncherPreferences.Accent.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            Section {
                HStack(spacing: 14) {
                    Group {
                        if let image = model.artworkImage {
                            Image(platformImage: image).resizable().scaledToFill()
                        } else {
                            DefaultCover(accent: SmokeTheme.accent(preferences.accent))
                        }
                    }
                    .frame(width: 60, height: 90)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: 8) {
                        Button("Choose Artwork…", systemImage: "photo") { choosing = true }
                        if model.artworkImage != nil {
                            Button("Use Default Artwork", systemImage: "arrow.uturn.backward", action: model.useDefaultArtwork)
                        }
                    }
                }
            } header: {
                Text("Cover Artwork")
            } footer: {
                Text("Your image is copied into the launcher and the original isn't changed. The default cover is original launcher art, not game artwork.")
            }
            Section {
                Toggle("Reduce Smoke Motion", isOn: Binding(get: { preferences.reduceSmoke },
                                                            set: { preferences.reduceSmoke = $0 }))
            } header: {
                Text("Background")
            } footer: {
                Text("Holds the smoke behind the library still. The system Reduce Motion setting does this too.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Appearance")
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.image]) { result in
            switch result {
            case .success(let url): model.importArtwork(url)
            case .failure(let error): model.errorMessage = error.localizedDescription
            }
        }
    }
}

// MARK: About

struct AboutView: View {
    @ObservedObject var model: LauncherModel

    static var versionText: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "Skyrim Launcher \(version) (\(build)) · \(CloudCapability.isConfiguredInBuild ? "iCloud" : "Local") build"
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image("LauncherArtwork").resizable().scaledToFit().frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Skyrim Launcher").font(.headline)
                        Text(Self.versionText).font(.caption).foregroundStyle(.secondary)
                        Text(Bundle.main.bundleIdentifier ?? "").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            Section("What This Is") {
                Text("A native launcher for your own original Windows copy of The Elder Scrolls V: Skyrim (2011). It contains original launcher artwork and no Skyrim game files, art or code.")
                Text("Gameplay hasn't been accepted on any device yet. On \(LauncherPlatform.name), the runtime status is: \(model.runtimeSummary.lowercased()).")
                    .foregroundStyle(.secondary)
            }
            Section("Credits") {
                Text("Library and settings design adapted from Dark Eco.").foregroundStyle(.secondary)
                Text("Cloud save settings pattern from the titanfall2-apple launcher (MIT).").foregroundStyle(.secondary)
                Text("The Elder Scrolls and Skyrim are trademarks of their owners. This launcher isn't affiliated with or endorsed by them.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("About")
    }
}
