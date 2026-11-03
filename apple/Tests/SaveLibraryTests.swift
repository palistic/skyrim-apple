import XCTest

/// Import/export/restore helpers: nothing is ever overwritten and only real saves are accepted.
final class SaveLibraryTests: XCTestCase {
    func testCopyNeverOverwritesAndRejectsNonSaves() throws {
        let box = try TestSandbox()
        let source = try box.folder("source"), destination = try box.folder("destination")
        let same = SyntheticSave.bytes("same"), incoming = SyntheticSave.bytes("incoming")
        let resident = SyntheticSave.bytes("resident"), fresh = SyntheticSave.bytes("fresh")

        try box.put(same, at: source.appendingPathComponent("Save 1.ess"))
        try box.put(same, at: destination.appendingPathComponent("Save 1.ess"))
        try box.put(incoming, at: source.appendingPathComponent("Save 2.ess"))
        try box.put(resident, at: destination.appendingPathComponent("Save 2.ess"))
        try box.put(fresh, at: source.appendingPathComponent("Save 3.ess"))
        try box.put(Data("not a save at all".utf8), at: source.appendingPathComponent("fake.ess"))
        try box.put(SyntheticSave.bytes("txt"), at: source.appendingPathComponent("notes.txt"))
        try box.put(Data(), at: source.appendingPathComponent("empty.ess"))
        try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("link.ess"),
            withDestinationURL: source.appendingPathComponent("Save 3.ess"))
        let names = ["Save 1.ess", "Save 2.ess", "Save 3.ess", "fake.ess", "notes.txt", "empty.ess", "link.ess"]

        let message = try SaveLibrary.copy(names.map { source.appendingPathComponent($0) }, into: destination)
        XCTAssertEqual(message, "Imported 2 save(s). 1 already present. Skipped 4 non-save file(s).")

        func contents(_ name: String) -> Data? { FileManager.default.contents(atPath: destination.appendingPathComponent(name).path) }
        XCTAssertEqual(contents("Save 1.ess"), same)
        XCTAssertEqual(contents("Save 2.ess"), resident, "An existing differing save is never replaced")
        XCTAssertEqual(contents("Save 2 (copy).ess"), incoming)
        XCTAssertEqual(contents("Save 3.ess"), fresh)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: destination.path)),
                       ["Save 1.ess", "Save 2.ess", "Save 2 (copy).ess", "Save 3.ess"])
    }

    func testRepeatedImportOfADifferingSaveAddsANumberedCopy() throws {
        let box = try TestSandbox()
        let source = try box.folder("source"), destination = try box.folder("destination")
        let incoming = SyntheticSave.bytes("incoming"), resident = SyntheticSave.bytes("resident")
        try box.put(incoming, at: source.appendingPathComponent("Save 2.ess"))
        try box.put(resident, at: destination.appendingPathComponent("Save 2.ess"))
        let url = source.appendingPathComponent("Save 2.ess")

        XCTAssertEqual(try SaveLibrary.copy([url], into: destination, verb: "Exported"), "Exported 1 save(s).")
        XCTAssertEqual(try SaveLibrary.copy([url], into: destination, verb: "Exported"), "Exported 1 save(s).")
        func contents(_ name: String) -> Data? { FileManager.default.contents(atPath: destination.appendingPathComponent(name).path) }
        XCTAssertEqual(contents("Save 2.ess"), resident)
        XCTAssertEqual(contents("Save 2 (copy).ess"), incoming)
        XCTAssertEqual(contents("Save 2 (copy) 2.ess"), incoming)
    }

    func testUniqueNameSkipsExistingFiles() throws {
        let box = try TestSandbox()
        let folder = try box.folder("names")
        XCTAssertEqual(SaveLibrary.uniqueName(stem: "Quick (restored)", in: folder), "Quick (restored).ess")
        try box.put(Data("x".utf8), at: folder.appendingPathComponent("Quick (restored).ess"))
        XCTAssertEqual(SaveLibrary.uniqueName(stem: "Quick (restored)", in: folder), "Quick (restored) 2.ess")
        try box.put(Data("x".utf8), at: folder.appendingPathComponent("Quick (restored) 2.ess"))
        XCTAssertEqual(SaveLibrary.uniqueName(stem: "Quick (restored)", in: folder), "Quick (restored) 3.ess")
    }

    func testReadSaveAcceptsOnlyRegularOriginalSaves() throws {
        let box = try TestSandbox()
        let folder = try box.folder("read")
        let good = SyntheticSave.bytes("good")
        try box.put(good, at: folder.appendingPathComponent("good.ess"))
        XCTAssertEqual(try SaveLibrary.readSave(folder.appendingPathComponent("good.ess")), good)

        try box.put(good, at: folder.appendingPathComponent("good.sav"))
        try box.put(Data("plain".utf8), at: folder.appendingPathComponent("plain.ess"))
        try box.put(Data(), at: folder.appendingPathComponent("empty.ess"))
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("dir.ess"), withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("link.ess"),
            withDestinationURL: folder.appendingPathComponent("good.ess"))
        for name in ["good.sav", "plain.ess", "empty.ess", "dir.ess", "link.ess"] {
            XCTAssertThrowsError(try SaveLibrary.readSave(folder.appendingPathComponent(name)), name)
        }
    }

    func testScanListsOnlyRegularEligibleSavesNewestFirst() throws {
        let box = try TestSandbox()
        let folder = try box.folder("scan")
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        try box.put(SyntheticSaveHeader().build(), at: folder.appendingPathComponent("new.ess"), modified: t0 + 60)
        try box.put(SyntheticSave.bytes("old"), at: folder.appendingPathComponent("old.ess"), modified: t0)
        try box.put(SyntheticSave.bytes("hidden"), at: folder.appendingPathComponent(".hidden.ess"))
        try box.put(SyntheticSave.bytes("txt"), at: folder.appendingPathComponent("notes.txt"))
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("dir.ess"), withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("link.ess"),
            withDestinationURL: folder.appendingPathComponent("new.ess"))

        let entries = SaveLibrary.scan(folder, kind: .active)
        XCTAssertEqual(entries.map { $0.url.lastPathComponent }, ["new.ess", "old.ess"])
        XCTAssertEqual(entries.first?.header?.playerName, "Lydia")
        XCTAssertEqual(entries.first?.title, "Save 7 · Lydia")
        XCTAssertNil(entries.last?.header)
        XCTAssertEqual(entries.last?.title, "old")
        XCTAssertTrue(SaveLibrary.scan(box.root.appendingPathComponent("missing"), kind: .active).isEmpty)
    }

    func testPreservedEntryNamingMatchesMirrorArchives() {
        func preserved(_ name: String) -> SaveEntry {
            SaveEntry(url: URL(fileURLWithPath: "/tmp/\(name)"), kind: .preserved, modified: nil, size: 1, header: nil)
        }
        let digest = String(repeating: "ab", count: 32)
        for (source, label) in [("device", "This device"), ("icloud", "iCloud"), ("version", "iCloud version")] {
            let name = SkyrimSaveMirror.archiveName(for: "Save 3.ess", source: source, digest: digest)
            XCTAssertEqual(name, "Save 3--\(source)-\(digest).ess")
            XCTAssertEqual(preserved(name).preservedSource, label)
            XCTAssertEqual(preserved(name).originalStem, "Save 3")
        }
        let dashed = SkyrimSaveMirror.archiveName(for: "my--save.ess", source: "icloud", digest: digest)
        XCTAssertEqual(preserved(dashed).originalStem, "my--save")
        XCTAssertEqual(preserved(dashed).preservedSource, "iCloud")

        let longStem = String(repeating: "x", count: 200)
        let truncated = SkyrimSaveMirror.archiveName(for: longStem + ".ess", source: "device", digest: digest)
        XCTAssertEqual(truncated, String(repeating: "x", count: 75) + "--device-\(digest).ess")
        XCTAssertLessThanOrEqual(truncated.utf8.count, 255)

        let active = SaveEntry(url: URL(fileURLWithPath: "/tmp/Save 3--device-\(digest).ess"), kind: .active,
                               modified: nil, size: 1, header: nil)
        XCTAssertNil(active.preservedSource)
        XCTAssertEqual(active.originalStem, "Save 3--device-\(digest)")
        XCTAssertNil(preserved("Unrelated.ess").preservedSource)
    }

    func testEligibleNames() {
        for name in ["Save 1.ess", "quick.ESS", "Autosave1.Ess"] {
            XCTAssertTrue(SkyrimSaveMirror.isEligibleName(name), name)
        }
        for name in ["", ".ess", ".hidden.ess", "a/b.ess", "a\\b.ess", "nul\0.ess", "save.ess.tmp", "save.txt",
                     String(repeating: "x", count: 252) + ".ess"] {
            XCTAssertFalse(SkyrimSaveMirror.isEligibleName(name), name)
        }
    }
}
