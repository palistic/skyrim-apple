import Combine
import CryptoKit
import Foundation
import UIKit

@MainActor
final class VisionLauncherModel: ObservableObject {
    @Published private(set) var folderName: String?
    @Published private(set) var headline = "Game files not added"
    @Published private(set) var detail = "Choose your original Windows Skyrim installation when you're ready."
    @Published private(set) var isChecking = false
    @Published private(set) var coreFilesFound = false
    @Published private(set) var artworkImage: UIImage?
    @Published var errorMessage: String?

    private let preferences = UserDefaults.standard
    private let folderBookmarkKey = "SkyrimVisionLauncher.folderBookmark"
    private let artworkKey = "SkyrimVisionLauncher.artworkFile"
    private var selectedFolder: URL?

    // This app is the native library/launcher only. It deliberately contains
    // neither generated game code nor any owned Skyrim executable or assets.
    let gameRuntimeLinked = false

    init() {
        if let name = preferences.string(forKey: artworkKey) {
            let url = Self.artworkDirectory.appendingPathComponent(name)
            artworkImage = UIImage(contentsOfFile: url.path)
        }
        guard let data = preferences.data(forKey: folderBookmarkKey) else { return }
        do {
            var stale = false
            let url = try URL(resolvingBookmarkData: data, options: .withoutUI,
                              relativeTo: nil, bookmarkDataIsStale: &stale)
            selectedFolder = url
            folderName = url.lastPathComponent
            if stale { try saveBookmark(for: url) }
            refresh()
        } catch {
            headline = "Choose your game folder again"
            detail = "The previous folder is no longer available. Your original files haven't been changed."
        }
    }

    func selectFolder(_ url: URL) {
        guard !isChecking else { return }
        do {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            try saveBookmark(for: url)
            selectedFolder = url
            folderName = url.lastPathComponent
            refresh()
        } catch {
            errorMessage = "This folder couldn't be linked. Choose it again in Files."
        }
    }

    func unlinkFolder() {
        guard !isChecking else { return }
        preferences.removeObject(forKey: folderBookmarkKey)
        selectedFolder = nil
        folderName = nil
        coreFilesFound = false
        headline = "Game files not added"
        detail = "Choose your original Windows Skyrim installation when you're ready."
    }

    func refresh() {
        guard !isChecking, let folder = selectedFolder else { return }
        isChecking = true
        coreFilesFound = false
        headline = "Checking game files"
        detail = "Reading your selected installation."
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Self.validateFolder(folder)
            }.value
            guard let self else { return }
            self.isChecking = false
            self.coreFilesFound = result.coreFilesFound
            self.headline = result.headline
            self.detail = result.detail
        }
    }

    func importArtwork(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            guard (values.fileSize ?? 0) <= 25 * 1024 * 1024,
                  let image = UIImage(contentsOfFile: url.path),
                  let data = image.pngData() else {
                throw LauncherIssue("Choose a readable image smaller than 25 MB.")
            }
            try FileManager.default.createDirectory(at: Self.artworkDirectory, withIntermediateDirectories: true)
            let name = "cover-\(UUID().uuidString).png"
            try data.write(to: Self.artworkDirectory.appendingPathComponent(name), options: .atomic)
            preferences.set(name, forKey: artworkKey)
            artworkImage = image
        } catch {
            errorMessage = (error as? LauncherIssue)?.message ?? "The artwork couldn't be imported. Your source image hasn't been changed."
        }
    }

    func useDefaultArtwork() {
        preferences.removeObject(forKey: artworkKey)
        artworkImage = nil
    }

    private func saveBookmark(for url: URL) throws {
        let data = try url.bookmarkData(options: .minimalBookmark,
                                      includingResourceValuesForKeys: nil, relativeTo: nil)
        preferences.set(data, forKey: folderBookmarkKey)
    }

    nonisolated private static var artworkDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LauncherArtwork", isDirectory: true)
    }

    private struct FolderResult: Sendable {
        let coreFilesFound: Bool
        let headline: String
        let detail: String
    }

    private struct LauncherIssue: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    nonisolated private static func validateFolder(_ folder: URL) -> FolderResult {
        let access = folder.startAccessingSecurityScopedResource()
        defer { if access { folder.stopAccessingSecurityScopedResource() } }
        do {
            let executable = try requiredItem("TESV.exe", in: folder)
            let bink = try requiredItem("binkw32.dll", in: folder)
            let data = try requiredItem("Data", in: folder)
            guard try data.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
                throw LauncherIssue("Choose the installation folder containing TESV.exe and its complete Data folder.")
            }
            try validatePE32(executable)
            try validatePE32(bink)
            for name in ["Skyrim.esm", "Update.esm"] {
                let item = try requiredItem(name, in: data)
                guard try isNonemptyFile(item) else {
                    throw LauncherIssue("The Data folder is missing a readable \(name).")
                }
            }
            let archives = try FileManager.default.contentsOfDirectory(at: data,
                includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            let hasArchive = try archives.contains { item in
                guard item.pathExtension.caseInsensitiveCompare("bsa") == .orderedSame else { return false }
                return try isNonemptyFile(item)
            }
            guard hasArchive else {
                throw LauncherIssue("The Data folder has no Skyrim archives. Choose the complete original installation.")
            }
            let handle = try FileHandle(forReadingFrom: executable)
            defer { try? handle.close() }
            var hash = Insecure.SHA1()
            while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty { hash.update(data: chunk) }
            let prefix = hash.finalize().map { String(format: "%02x", $0) }.joined()
            guard prefix.hasPrefix("f39aeceb") else {
                throw LauncherIssue("Use the original Windows Skyrim 1.9.32.0.8 installation. This executable doesn't match that version.")
            }
            return FolderResult(coreFilesFound: true, headline: "Core game files found",
                detail: "Your original files are linked. A playable Vision Pro game build isn't installed yet.")
        } catch {
            return FolderResult(coreFilesFound: false, headline: "Game files need attention",
                detail: (error as? LauncherIssue)?.message ?? "This folder couldn't be read. Check that its files are downloaded in Files, then choose it again.")
        }
    }

    nonisolated private static func requiredItem(_ name: String, in directory: URL) throws -> URL {
        let matches = try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: nil, options: []).filter { $0.lastPathComponent.caseInsensitiveCompare(name) == .orderedSame }
        guard matches.count == 1, let item = matches.first else {
            throw LauncherIssue(matches.isEmpty ? "This folder is missing \(name). Choose the complete original Windows installation." :
                "More than one \(name) was found. Choose an unambiguous installation.")
        }
        return item
    }

    nonisolated private static func isNonemptyFile(_ url: URL) throws -> Bool {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        return values.isDirectory != true && (values.fileSize ?? 0) > 0
    }

    nonisolated private static func validatePE32(_ url: URL) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let dos = try handle.read(upToCount: 64), dos.count == 64,
              dos[0] == 0x4D, dos[1] == 0x5A else {
            throw LauncherIssue("\(url.lastPathComponent) isn't a supported original Windows file.")
        }
        let offset = dos[60..<64].enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << (8 * $1.offset) }
        try handle.seek(toOffset: offset)
        guard let pe = try handle.read(upToCount: 26), pe.count == 26,
              Array(pe.prefix(6)) == [0x50, 0x45, 0, 0, 0x4C, 0x01],
              pe[24] == 0x0B, pe[25] == 0x01 else {
            throw LauncherIssue("\(url.lastPathComponent) must come from the original 32-bit Windows Skyrim installation.")
        }
    }
}
