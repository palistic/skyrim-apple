import CoreGraphics
import CryptoKit
import Foundation

/// Metadata from the header of an original Skyrim `.ess` save. Parsing is bounds-checked and
/// read-only; a file that does not match yields nil and is still listed by name.
struct SaveHeader: Sendable, Equatable {
    var version: UInt32
    var saveNumber: UInt32
    var playerName: String
    var level: UInt32
    var location: String
    var gameDate: String
    var race: String
    var thumbnailWidth = 0
    var thumbnailHeight = 0
    /// Premultiplied RGBA8, `thumbnailWidth * thumbnailHeight * 4` bytes, when present.
    var thumbnailRGBA = Data()

    static let magic = Data("TESV_SAVEGAME".utf8)

    static func parse(_ data: Data) -> SaveHeader? {
        var reader = ByteReader(data: data)
        guard reader.bytes(magic.count) == magic, let headerSize = reader.u32() else { return nil }
        let headerStart = reader.offset
        guard let version = reader.u32(), let number = reader.u32(), let name = reader.wstring(),
              let level = reader.u32(), let location = reader.wstring(), let date = reader.wstring(),
              let race = reader.wstring(), reader.skip(2 + 4 + 4 + 8),
              let width = reader.u32(), let height = reader.u32() else { return nil }
        var header = SaveHeader(version: version, saveNumber: number, playerName: name, level: level,
                                location: location, gameDate: date, race: race)
        // Original Skyrim (version 9) stores RGB; later formats store RGBA.
        let channels = version >= 11 ? 4 : 3
        // Two absurd u32 dimensions overflow Int; only the accepted range below is multiplied.
        let pixels = width <= 1024 && height <= 1024 ? Int(width) * Int(height) : 0
        let shotStart = headerStart + Int(headerSize)
        if (1...1024).contains(width), (1...1024).contains(height), shotStart >= reader.offset,
           shotStart + pixels * channels <= data.count {
            var rgba = Data(count: pixels * 4)
            rgba.withUnsafeMutableBytes { out in
                data.withUnsafeBytes { raw in
                    for index in 0..<pixels {
                        let source = shotStart + index * channels
                        out[index * 4] = raw[source]
                        out[index * 4 + 1] = raw[source + 1]
                        out[index * 4 + 2] = raw[source + 2]
                        out[index * 4 + 3] = 255
                    }
                }
            }
            header.thumbnailWidth = Int(width)
            header.thumbnailHeight = Int(height)
            header.thumbnailRGBA = rgba
        }
        return header
    }

    func thumbnail() -> CGImage? {
        guard thumbnailWidth > 0, thumbnailHeight > 0,
              let provider = CGDataProvider(data: thumbnailRGBA as CFData) else { return nil }
        return CGImage(width: thumbnailWidth, height: thumbnailHeight, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: thumbnailWidth * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    private struct ByteReader {
        let data: Data
        var offset = 0
        mutating func bytes(_ count: Int) -> Data? {
            guard count >= 0, offset + count <= data.count else { return nil }
            defer { offset += count }
            return data.subdata(in: data.startIndex + offset ..< data.startIndex + offset + count)
        }
        mutating func skip(_ count: Int) -> Bool { bytes(count) != nil }
        mutating func u16() -> UInt16? {
            bytes(2).map { UInt16($0[$0.startIndex]) | UInt16($0[$0.startIndex + 1]) << 8 }
        }
        mutating func u32() -> UInt32? {
            bytes(4).map { $0.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * $1.offset) } }
        }
        mutating func wstring() -> String? {
            guard let length = u16(), length <= 512, let raw = bytes(Int(length)) else { return nil }
            return String(data: raw, encoding: .windowsCP1252) ?? String(decoding: raw, as: UTF8.self)
        }
    }
}

struct SaveEntry: Identifiable, Sendable, Equatable {
    enum Kind: Sendable { case active, preserved }
    var id: URL { url }
    let url: URL
    let kind: Kind
    let modified: Date?
    let size: Int
    let header: SaveHeader?

    var title: String {
        guard let header else { return url.deletingPathExtension().lastPathComponent }
        return header.saveNumber > 0 ? "Save \(header.saveNumber) · \(header.playerName)" : header.playerName
    }

    /// Preserved archives are named `<stem>--<source>-<sha256>.ess`.
    var preservedSource: String? {
        guard kind == .preserved else { return nil }
        let stem = url.deletingPathExtension().lastPathComponent
        guard let range = stem.range(of: "--", options: .backwards) else { return nil }
        switch stem[range.upperBound...].split(separator: "-").first {
        case "device": return "This device"
        case "icloud": return "iCloud"
        case "version": return "iCloud version"
        default: return nil
        }
    }

    var originalStem: String {
        let stem = url.deletingPathExtension().lastPathComponent
        guard kind == .preserved, let range = stem.range(of: "--", options: .backwards) else { return stem }
        return String(stem[..<range.lowerBound])
    }
}

enum SaveLibraryIssue: LocalizedError {
    case gameRunning, notASave(String), busy
    var errorDescription: String? {
        switch self {
        case .gameRunning: return "Close the game before changing saves. Nothing was changed."
        case .notASave(let name): return "\(name) isn't an original Skyrim save, so it was left out."
        case .busy: return "Wait for the current save operation or sync to finish."
        }
    }
}

/// Lists, imports, exports and restores saves without ever overwriting or deleting one.
@MainActor
final class SaveLibrary: ObservableObject {
    @Published private(set) var saves: [SaveEntry] = []
    @Published private(set) var preserved: [SaveEntry] = []
    @Published private(set) var isWorking = false
    @Published var message: String?

    let saveDirectory: URL
    let preservedDirectory: URL

    init(saveDirectory: URL = SkyrimSaveLocations.saveGames,
         preservedDirectory: URL = SkyrimSaveLocations.conflicts) {
        self.saveDirectory = saveDirectory
        self.preservedDirectory = preservedDirectory
    }

    func refresh() async {
        let active = saveDirectory, archive = preservedDirectory
        let (saves, preserved) = await Task.detached(priority: .userInitiated) {
            (Self.scan(active, kind: .active), Self.scan(archive, kind: .preserved))
        }.value
        self.saves = saves
        self.preserved = preserved
    }

    func importSaves(_ urls: [URL], gameRunning: Bool) async {
        await perform(gameRunning: gameRunning) { [saveDirectory] in
            try Self.copy(urls, into: saveDirectory)
        }
    }

    func exportSaves(to folder: URL) async {
        await perform(gameRunning: false) { [saveDirectory] in
            let sources = Self.scan(saveDirectory, kind: .active).map(\.url)
            guard !sources.isEmpty else { return "There are no saves on this device to export." }
            return try Self.copy(sources, into: folder, verb: "Exported")
        }
    }

    /// Copies a preserved save back into the active folder under a new name; nothing is replaced.
    func restore(_ entry: SaveEntry, gameRunning: Bool) async {
        await perform(gameRunning: gameRunning) { [saveDirectory] in
            let data = try Self.readSave(entry.url)
            let name = Self.uniqueName(stem: entry.originalStem + " (restored)", in: saveDirectory)
            try FileManager.default.createDirectory(at: saveDirectory, withIntermediateDirectories: true)
            try data.write(to: saveDirectory.appendingPathComponent(name), options: .withoutOverwriting)
            return "Restored as \(name). Load it from Skyrim's Load menu."
        }
    }

    private func perform(gameRunning: Bool, _ work: @escaping @Sendable () throws -> String) async {
        guard !isWorking else { message = SaveLibraryIssue.busy.localizedDescription; return }
        guard !gameRunning else { message = SaveLibraryIssue.gameRunning.localizedDescription; return }
        isWorking = true
        defer { isWorking = false }
        do {
            message = try await Task.detached(priority: .userInitiated) { try work() }.value
        } catch {
            message = error.localizedDescription
        }
        await refresh()
    }

    nonisolated static func scan(_ directory: URL, kind: SaveEntry.Kind) -> [SaveEntry] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        guard let items = try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return [] }
        return items.compactMap { url -> SaveEntry? in
            guard SkyrimSaveMirror.isEligibleName(url.lastPathComponent),
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
            return SaveEntry(url: url, kind: kind, modified: values.contentModificationDate,
                             size: values.fileSize ?? 0, header: readHeader(url))
        }
        .sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
    }

    nonisolated static func readHeader(_ url: URL) -> SaveHeader? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        // Header plus the largest thumbnail the parser accepts.
        guard let prefix = try? handle.read(upToCount: 4 * 1024 * 1024 + 4096) else { return nil }
        return SaveHeader.parse(prefix)
    }

    nonisolated static func readSave(_ url: URL) throws -> Data {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard SkyrimSaveMirror.isEligibleName(url.lastPathComponent), values.isRegularFile == true,
              values.isSymbolicLink != true, let size = values.fileSize,
              size > 0, size <= SkyrimSaveMirror.maximumSaveBytes else {
            throw SaveLibraryIssue.notASave(url.lastPathComponent)
        }
        let data = try Data(contentsOf: url)
        guard data.starts(with: SaveHeader.magic) else { throw SaveLibraryIssue.notASave(url.lastPathComponent) }
        return data
    }

    nonisolated static func uniqueName(stem: String, in directory: URL) -> String {
        var candidate = stem + ".ess"
        var index = 2
        while FileManager.default.fileExists(atPath: directory.appendingPathComponent(candidate).path) {
            candidate = "\(stem) \(index).ess"
            index += 1
        }
        return candidate
    }

    /// Identical files are skipped, differing names get a numbered copy, nothing is overwritten.
    nonisolated static func copy(_ sources: [URL], into folder: URL, verb: String = "Imported") throws -> String {
        let access = folder.startAccessingSecurityScopedResource()
        defer { if access { folder.stopAccessingSecurityScopedResource() } }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var copied = 0, identical = 0, rejected: [String] = []
        for source in sources {
            let data: Data
            do { data = try readSave(source) } catch { rejected.append(source.lastPathComponent); continue }
            let destination = folder.appendingPathComponent(source.lastPathComponent)
            if let existing = try? Data(contentsOf: destination) {
                if SHA256.hash(data: existing) == SHA256.hash(data: data) { identical += 1; continue }
                let stem = destination.deletingPathExtension().lastPathComponent
                let name = uniqueName(stem: stem + " (copy)", in: folder)
                try data.write(to: folder.appendingPathComponent(name), options: .withoutOverwriting)
            } else {
                try data.write(to: destination, options: .withoutOverwriting)
            }
            copied += 1
        }
        var parts = ["\(verb) \(copied) save(s)."]
        if identical > 0 { parts.append("\(identical) already present.") }
        if !rejected.isEmpty { parts.append("Skipped \(rejected.count) non-save file(s).") }
        return parts.joined(separator: " ")
    }
}
