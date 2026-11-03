import SwiftUI
import UniformTypeIdentifiers

/// Dark Eco's Manage Save Files page for Skyrim's `.ess` saves. Nothing here deletes or
/// overwrites a save: imports and restores add copies, exports never replace files.
struct SavedGamesView: View {
    @ObservedObject var model: LauncherModel
    @State private var picker: TransferRequest?
    @State private var restoring: SaveEntry?

    enum TransferRequest { case importSaves, exportSaves }

    var body: some View {
        let library = model.saves
        Form {
            if let message = library.message {
                Section { Text(message).font(.callout) }
            }
            Section {
                if library.saves.isEmpty {
                    Text("No saves on this device yet. Saves you make in Skyrim appear here.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(library.saves) { SaveRow(entry: $0) }
                }
            } header: {
                Text("On This \(LauncherPlatform.name)")
            } footer: {
                #if os(macOS)
                Text(library.saveDirectory.path).textSelection(.enabled)
                #endif
            }
            Section {
                Button("Import Saves…", systemImage: "square.and.arrow.down") { picker = .importSaves }
                    .disabled(library.isWorking || model.isGameActive || model.saveSync.isSyncing)
                Button("Export Saves…", systemImage: "square.and.arrow.up") { picker = .exportSaves }
                    .disabled(library.isWorking || library.saves.isEmpty)
                #if os(macOS)
                Button("Show Saves in Finder", systemImage: "folder") {
                    let folder = FileManager.default.fileExists(atPath: library.saveDirectory.path)
                        ? library.saveDirectory : SkyrimSaveLocations.supportDirectory
                    NSWorkspace.shared.open(FileManager.default.fileExists(atPath: folder.path)
                                            ? folder : FileManager.default.homeDirectoryForCurrentUser)
                }
                #endif
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await library.refresh() } }
                    .disabled(library.isWorking)
            } footer: {
                Text("Import adds original Skyrim .ess saves without replacing any; a differing file with the same name is added as a copy. Export copies this device's saves into a folder you choose.")
            }
            Section {
                if library.preserved.isEmpty {
                    Text("No preserved copies.").foregroundStyle(.secondary)
                } else {
                    ForEach(library.preserved) { entry in
                        Button { restoring = entry } label: { SaveRow(entry: entry) }
                            .buttonStyle(.plain)
                            .disabled(library.isWorking || model.isGameActive)
                    }
                }
            } header: {
                Text("Preserved Saves")
            } footer: {
                Text("When synced copies differ, both are kept here. Restoring adds the copy beside your saves under a new name; nothing is replaced.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Manage Save Files")
        .task { await library.refresh() }
        .fileImporter(isPresented: Binding(get: { picker != nil }, set: { if !$0 { picker = nil } }),
                      allowedContentTypes: picker == .exportSaves ? [.folder] : [.item],
                      allowsMultipleSelection: picker == .importSaves) { result in
            let request = picker
            picker = nil
            switch result {
            case .success(let urls):
                Task {
                    if request == .exportSaves, let folder = urls.first {
                        await library.exportSaves(to: folder)
                    } else if request == .importSaves {
                        await library.importSaves(urls, gameRunning: model.isGameActive)
                    }
                }
            case .failure(let error):
                library.message = error.localizedDescription
            }
        }
        .confirmationDialog("Restore this preserved save?", isPresented: Binding(
            get: { restoring != nil }, set: { if !$0 { restoring = nil } }
        ), titleVisibility: .visible, presenting: restoring) { entry in
            Button("Restore Copy") {
                restoring = nil
                Task { await library.restore(entry, gameRunning: model.isGameActive) }
            }
            Button("Cancel", role: .cancel) { restoring = nil }
        } message: { entry in
            Text("\(entry.title) will be added to your saves as a new file. Your current saves aren't changed.")
        }
    }
}

struct SaveRow: View {
    let entry: SaveEntry

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let image = entry.header?.thumbnail() {
                    Image(decorative: image, scale: 1).resizable().scaledToFill()
                } else {
                    Image(systemName: "doc").font(.system(size: 18)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 72, height: 42)
            .background(.black.opacity(0.3))
            .clipShape(RoundedRectangle(cornerRadius: 5))
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        var parts: [String] = []
        if let source = entry.preservedSource { parts.append(source) }
        if let header = entry.header {
            if !header.location.isEmpty { parts.append(header.location) }
            parts.append("Level \(header.level)")
        }
        if let date = entry.modified { parts.append(date.formatted(date: .abbreviated, time: .shortened)) }
        parts.append(ByteCountFormatter.string(fromByteCount: Int64(entry.size), countStyle: .file))
        return parts.joined(separator: " · ")
    }
}
