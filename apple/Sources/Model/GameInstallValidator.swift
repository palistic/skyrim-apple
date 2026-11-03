import CryptoKit
import Foundation

/// Read-only check of a user-selected original Windows installation (Skyrim 1.9.32.0.8).
/// It opens TESV.exe, binkw32.dll and the Data folder listing; nothing is copied or changed.
enum GameInstallValidator {
    struct Result: Sendable, Equatable {
        let coreFilesFound: Bool
        let headline: String
        let detail: String
    }

    struct Issue: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    static let executableSHA1Prefix = "f39aeceb"

    static func validate(_ folder: URL, runtimeNote: String) -> Result {
        let access = folder.startAccessingSecurityScopedResource()
        defer { if access { folder.stopAccessingSecurityScopedResource() } }
        do {
            let executable = try requiredItem("TESV.exe", in: folder)
            let bink = try requiredItem("binkw32.dll", in: folder)
            let data = try requiredItem("Data", in: folder)
            guard try data.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
                throw Issue("Choose the installation folder containing TESV.exe and its complete Data folder.")
            }
            try validatePE32(executable)
            try validatePE32(bink)
            for name in ["Skyrim.esm", "Update.esm"] {
                guard try isNonemptyFile(try requiredItem(name, in: data)) else {
                    throw Issue("The Data folder is missing a readable \(name).")
                }
            }
            let archives = try FileManager.default.contentsOfDirectory(at: data,
                includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            let hasArchive = try archives.contains { item in
                guard item.pathExtension.caseInsensitiveCompare("bsa") == .orderedSame else { return false }
                return try isNonemptyFile(item)
            }
            guard hasArchive else {
                throw Issue("The Data folder has no Skyrim archives. Choose the complete original installation.")
            }
            guard try sha1(of: executable).hasPrefix(executableSHA1Prefix) else {
                throw Issue("Use the original Windows Skyrim 1.9.32.0.8 installation. This executable doesn't match that version.")
            }
            return Result(coreFilesFound: true, headline: "Core game files found", detail: runtimeNote)
        } catch {
            return Result(coreFilesFound: false, headline: "Game files need attention",
                detail: (error as? Issue)?.message
                    ?? "This folder couldn't be read. Check that its files are downloaded in Files, then choose it again.")
        }
    }

    static func sha1(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = Insecure.SHA1()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func requiredItem(_ name: String, in directory: URL) throws -> URL {
        let matches = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.caseInsensitiveCompare(name) == .orderedSame }
        guard matches.count == 1, let item = matches.first else {
            throw Issue(matches.isEmpty ? "This folder is missing \(name). Choose the complete original Windows installation."
                : "More than one \(name) was found. Choose an unambiguous installation.")
        }
        return item
    }

    static func isNonemptyFile(_ url: URL) throws -> Bool {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        return values.isDirectory != true && (values.fileSize ?? 0) > 0
    }

    static func validatePE32(_ url: URL) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let dos = try handle.read(upToCount: 64), dos.count == 64, dos[0] == 0x4D, dos[1] == 0x5A else {
            throw Issue("\(url.lastPathComponent) isn't a supported original Windows file.")
        }
        let offset = dos[60..<64].enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << (8 * $1.offset) }
        try handle.seek(toOffset: offset)
        guard let pe = try handle.read(upToCount: 26), pe.count == 26,
              Array(pe.prefix(6)) == [0x50, 0x45, 0, 0, 0x4C, 0x01],
              pe[24] == 0x0B, pe[25] == 0x01 else {
            throw Issue("\(url.lastPathComponent) must come from the original 32-bit Windows Skyrim installation.")
        }
    }
}
