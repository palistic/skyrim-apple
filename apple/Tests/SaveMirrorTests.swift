import XCTest

/// The pure directory mirror on synthetic saves in throwaway temp folders. `coordinateCloud` is
/// false, so no account, iCloud container or real save directory is involved.
final class SaveMirrorTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private let save = "Save 1.ess"

    private func expectIssue(_ issue: SaveSyncIssue, file: StaticString = #filePath, line: UInt = #line,
                             _ body: () throws -> Void) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            XCTAssertEqual(error as? SaveSyncIssue, issue, "\(error)", file: file, line: line)
        }
    }

    // MARK: One-sided changes

    func testLocalOnlySaveUploads() throws {
        let box = try TestSandbox()
        let bytes = SyntheticSave.bytes("local")
        try box.put(bytes, save, in: .local, modified: t0)

        XCTAssertEqual(try box.sync(), .init(fileCount: 1, uploaded: 1))
        XCTAssertEqual(box.data(save, in: .cloud), bytes)
        XCTAssertEqual(box.data(save, in: .local), bytes)
        assertSameInstant(box.modified(save, in: .cloud), t0)
        XCTAssertTrue(box.entries(in: .localConflicts).isEmpty)
        XCTAssertTrue(box.entries(in: .cloudConflicts).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: box.stateFile.path))

        XCTAssertEqual(try box.sync(), .init(fileCount: 1), "A second pass has nothing to do")
    }

    func testCloudOnlySaveDownloads() throws {
        let box = try TestSandbox()
        let bytes = SyntheticSave.bytes("cloud")
        try box.put(bytes, save, in: .cloud, modified: t0)

        XCTAssertEqual(try box.sync(), .init(fileCount: 1, downloaded: 1))
        XCTAssertEqual(box.data(save, in: .local), bytes)
        XCTAssertEqual(box.data(save, in: .cloud), bytes)
        assertSameInstant(box.modified(save, in: .local), t0)
        XCTAssertTrue(box.entries(in: .localConflicts).isEmpty)

        XCTAssertEqual(try box.sync(), .init(fileCount: 1))
    }

    func testIdenticalCopiesAreLeftAlone() throws {
        let box = try TestSandbox()
        let bytes = SyntheticSave.bytes("same")
        try box.put(bytes, save, in: .local, modified: t0)
        try box.put(bytes, save, in: .cloud, modified: t0 + 50)
        let before = box.snapshot().filter { !$0.key.hasPrefix("state/") }

        XCTAssertEqual(try box.sync(), .init(fileCount: 1))
        XCTAssertEqual(box.snapshot().filter { !$0.key.hasPrefix("state/") }, before,
                       "Equal bytes must not be rewritten, even with different dates")
        XCTAssertEqual(try box.sync(), .init(fileCount: 1))
    }

    /// After a shared baseline, only one side changed: that side wins regardless of dates.
    func testBaselineDecidesDirectionNotModificationDate() throws {
        let box = try TestSandbox()
        let v1 = SyntheticSave.bytes("v1"), v2 = SyntheticSave.bytes("v2"), v3 = SyntheticSave.bytes("v3")
        try box.put(v1, save, in: .local, modified: t0)
        try box.put(v1, save, in: .cloud, modified: t0)
        XCTAssertEqual(try box.sync(), .init(fileCount: 1))

        // Local edit carries an older date than the untouched cloud copy; it must still upload.
        try box.put(v2, save, in: .local, modified: t0 - 500)
        XCTAssertEqual(try box.sync(), .init(fileCount: 1, uploaded: 1))
        XCTAssertEqual(box.data(save, in: .cloud), v2)
        XCTAssertEqual(box.data(save, in: .local), v2)

        // Cloud edit carries an older date than the untouched local copy; it must still download.
        try box.put(v3, save, in: .cloud, modified: t0 - 1_000)
        XCTAssertEqual(try box.sync(), .init(fileCount: 1, downloaded: 1))
        XCTAssertEqual(box.data(save, in: .local), v3)
        XCTAssertEqual(box.data(save, in: .cloud), v3)

        XCTAssertTrue(box.entries(in: .localConflicts).isEmpty, "One-sided edits are not conflicts")
        XCTAssertTrue(box.entries(in: .cloudConflicts).isEmpty)
        XCTAssertEqual(try box.sync(), .init(fileCount: 1))
    }

    // MARK: Conflicts

    private func archives(device: Data, icloud: Data, stem: String = "Save 1") -> [String: Data] {
        ["\(stem)--device-\(SyntheticSave.digest(device)).ess": device,
         "\(stem)--icloud-\(SyntheticSave.digest(icloud)).ess": icloud]
    }

    func testEditsOnBothSidesPreserveBothOriginalsAndNewestWins() throws {
        let box = try TestSandbox()
        let base = SyntheticSave.bytes("base")
        try box.put(base, save, in: .local, modified: t0)
        try box.put(base, save, in: .cloud, modified: t0)
        XCTAssertEqual(try box.sync(), .init(fileCount: 1))

        let deviceEdit = SyntheticSave.bytes("device-edit"), cloudEdit = SyntheticSave.bytes("cloud-edit")
        try box.put(deviceEdit, save, in: .local, modified: t0 + 100)
        try box.put(cloudEdit, save, in: .cloud, modified: t0 + 200)

        XCTAssertEqual(try box.sync(), .init(fileCount: 1, conflicts: 1, downloaded: 1))
        XCTAssertEqual(box.data(save, in: .local), cloudEdit, "The newer iCloud copy becomes the live save")
        XCTAssertEqual(box.data(save, in: .cloud), cloudEdit)
        assertSameInstant(box.modified(save, in: .local), t0 + 200)
        let expected = archives(device: deviceEdit, icloud: cloudEdit)
        XCTAssertEqual(box.files(in: .localConflicts), expected)
        XCTAssertEqual(box.files(in: .cloudConflicts), expected)

        // Rerun is stable: no new conflict, no duplicate archives, no error.
        XCTAssertEqual(try box.sync(), .init(fileCount: 1))
        XCTAssertEqual(box.files(in: .localConflicts), expected)
        XCTAssertEqual(box.files(in: .cloudConflicts), expected)
        XCTAssertEqual(box.entries(in: .localConflicts).count, 2)
        XCTAssertEqual(box.entries(in: .cloudConflicts).count, 2)
    }

    func testFirstSyncWithDifferentContentIsAConflictAndNewerDeviceCopyWins() throws {
        let box = try TestSandbox()
        let device = SyntheticSave.bytes("device"), icloud = SyntheticSave.bytes("icloud")
        try box.put(device, save, in: .local, modified: t0 + 300)
        try box.put(icloud, save, in: .cloud, modified: t0)

        XCTAssertEqual(try box.sync(), .init(fileCount: 1, conflicts: 1, uploaded: 1))
        XCTAssertEqual(box.data(save, in: .local), device)
        XCTAssertEqual(box.data(save, in: .cloud), device)
        XCTAssertEqual(box.files(in: .localConflicts), archives(device: device, icloud: icloud))
        XCTAssertEqual(box.files(in: .cloudConflicts), archives(device: device, icloud: icloud))

        XCTAssertEqual(try box.sync(), .init(fileCount: 1))
        XCTAssertEqual(box.entries(in: .localConflicts).count, 2)
        XCTAssertEqual(box.entries(in: .cloudConflicts).count, 2)
    }

    func testEqualDatesKeepThisDevicesCopy() throws {
        let box = try TestSandbox()
        let device = SyntheticSave.bytes("device"), icloud = SyntheticSave.bytes("icloud")
        try box.put(device, save, in: .local, modified: t0)
        try box.put(icloud, save, in: .cloud, modified: t0)

        XCTAssertEqual(try box.sync(), .init(fileCount: 1, conflicts: 1, uploaded: 1))
        XCTAssertEqual(box.data(save, in: .local), device)
        XCTAssertEqual(box.data(save, in: .cloud), device)
        XCTAssertEqual(box.files(in: .cloudConflicts)["Save 1--icloud-\(SyntheticSave.digest(icloud)).ess"], icloud)
    }

    /// A run interrupted after archiving leaves archives behind; the retry reuses them.
    func testConflictRetryAfterInterruptionDoesNotDuplicateArchives() throws {
        let box = try TestSandbox()
        let device = SyntheticSave.bytes("device"), icloud = SyntheticSave.bytes("icloud")
        try box.put(device, save, in: .local, modified: t0)
        try box.put(icloud, save, in: .cloud, modified: t0 + 10)
        XCTAssertEqual(try box.sync(), .init(fileCount: 1, conflicts: 1, downloaded: 1))

        // Recreate the pre-resolution state with the archives already present.
        try box.put(device, save, in: .local, modified: t0)
        try FileManager.default.removeItem(at: box.stateFile)
        XCTAssertEqual(try box.sync(), .init(fileCount: 1, conflicts: 1, downloaded: 1))
        XCTAssertEqual(box.files(in: .localConflicts), archives(device: device, icloud: icloud))
        XCTAssertEqual(box.files(in: .cloudConflicts), archives(device: device, icloud: icloud))
    }

    func testTamperedArchiveWithTheSameNameIsNeverReplaced() throws {
        let box = try TestSandbox()
        let device = SyntheticSave.bytes("device"), icloud = SyntheticSave.bytes("icloud")
        try box.put(device, save, in: .local, modified: t0)
        try box.put(icloud, save, in: .cloud, modified: t0 + 10)
        let archiveName = "Save 1--device-\(SyntheticSave.digest(device)).ess"
        let impostor = SyntheticSave.bytes("impostor")
        try box.put(impostor, archiveName, in: .localConflicts)

        expectIssue(.changedFile(archiveName)) { _ = try box.sync() }
        XCTAssertEqual(box.data(archiveName, in: .localConflicts), impostor)
        XCTAssertEqual(box.data(save, in: .local), device, "No winner is chosen before both originals are kept")
        XCTAssertEqual(box.data(save, in: .cloud), icloud)
    }

    func testArchiveNamesRoundTripThroughPreservedEntries() throws {
        let box = try TestSandbox()
        let device = SyntheticSave.bytes("device"), icloud = SyntheticSave.bytes("icloud")
        try box.put(device, "Quick--Save.ess", in: .local, modified: t0)
        try box.put(icloud, "Quick--Save.ess", in: .cloud, modified: t0 + 1)
        XCTAssertEqual(try box.sync(), .init(fileCount: 1, conflicts: 1, downloaded: 1))

        let entries = SaveLibrary.scan(box.url(.localConflicts), kind: .preserved)
        XCTAssertEqual(Set(entries.compactMap(\.preservedSource)), ["This device", "iCloud"])
        XCTAssertEqual(Set(entries.map(\.originalStem)), ["Quick--Save"])
    }

    // MARK: Game-running guard and cancellation

    func testRunningGameBlocksSyncBeforeAnythingIsTouched() throws {
        let box = try TestSandbox()
        try box.put(SyntheticSave.bytes("local"), "a.ess", in: .local, modified: t0)
        try box.put(SyntheticSave.bytes("cloud"), "b.ess", in: .cloud, modified: t0)
        let before = box.snapshot()

        box.gate.setGameRunning(true)
        expectIssue(.gameRunning) { _ = try box.sync() }
        XCTAssertEqual(box.snapshot(), before, "No live save, cloud copy or state file may change")
        XCTAssertFalse(FileManager.default.fileExists(atPath: box.stateFile.path))

        box.gate.setGameRunning(false)
        XCTAssertEqual(try box.sync(), .init(fileCount: 2, uploaded: 1, downloaded: 1))
    }

    func testCancelledSyncThrowsDisabledAndChangesNothing() throws {
        let box = try TestSandbox()
        try box.put(SyntheticSave.bytes("local"), "a.ess", in: .local, modified: t0)
        try box.put(SyntheticSave.bytes("cloud"), "b.ess", in: .cloud, modified: t0)
        let before = box.snapshot()

        box.gate.begin()
        box.gate.cancel()
        expectIssue(.disabled) { _ = try box.sync() }
        XCTAssertEqual(box.snapshot(), before)

        box.gate.begin()
        XCTAssertEqual(try box.sync(), .init(fileCount: 2, uploaded: 1, downloaded: 1))
    }

    func testGateRefusesLocalWritesWhileRunningOrCancelled() throws {
        let gate = SaveWriteGate()
        var ran = 0
        XCTAssertNoThrow(try gate.withLocalWrite { ran += 1 })
        gate.setGameRunning(true)
        XCTAssertTrue(gate.isGameRunning)
        expectIssue(.gameRunning) { try gate.withLocalWrite { ran += 1 } }
        gate.cancel()
        expectIssue(.gameRunning) { try gate.checkActive() }  // running takes precedence
        gate.setGameRunning(false)
        expectIssue(.disabled) { try gate.withLocalWrite { ran += 1 } }
        gate.begin()
        XCTAssertNoThrow(try gate.checkActive())
        XCTAssertEqual(ran, 1, "A refused write section never runs its body")
    }

    /// Every download writes inside `withLocalWrite`, and the writer re-checks the gate.
    func testLocalWriteSectionCanRecheckTheGate() throws {
        let gate = SaveWriteGate()
        let value = try runWithDeadline(5) {
            try gate.withLocalWrite { () throws -> Int in
                try gate.checkActive()
                return try gate.withLocalWrite { 42 }
            }
        }
        XCTAssertEqual(value, 42)
    }

    // MARK: Account binding

    func testDifferentAccountIsRefusedWithoutChangingFiles() throws {
        let box = try TestSandbox()
        try box.put(SyntheticSave.bytes("a"), "a.ess", in: .local, modified: t0)
        XCTAssertEqual(try box.sync(box.mirror(account: TestAccounts.primary)), .init(fileCount: 1, uploaded: 1))

        try box.put(SyntheticSave.bytes("local-new"), "b.ess", in: .local, modified: t0)
        try box.put(SyntheticSave.bytes("cloud-new"), "c.ess", in: .cloud, modified: t0)
        let before = box.snapshot()
        expectIssue(.accountChanged) { _ = try box.sync(box.mirror(account: TestAccounts.other)) }
        XCTAssertEqual(box.snapshot(), before, "Files and the bound account stay as they were")

        XCTAssertEqual(try box.sync(box.mirror(account: TestAccounts.primary)),
                       .init(fileCount: 3, uploaded: 1, downloaded: 1))
    }

    func testAccountIsBoundEvenWhenThereAreNoSaves() throws {
        let box = try TestSandbox()
        XCTAssertEqual(try box.sync(box.mirror(account: TestAccounts.primary)), .init())
        XCTAssertTrue(FileManager.default.fileExists(atPath: box.stateFile.path))

        try box.put(SyntheticSave.bytes("a"), "a.ess", in: .local)
        expectIssue(.accountChanged) { _ = try box.sync(box.mirror(account: TestAccounts.other)) }
        XCTAssertTrue(box.entries(in: .cloud).isEmpty)
    }

    func testAccountsMatchComparesDecodedTokens() throws {
        let immutable = try NSKeyedArchiver.archivedData(withRootObject: NSString(string: "token-1"),
                                                         requiringSecureCoding: false)
        let mutable = try NSKeyedArchiver.archivedData(withRootObject: NSMutableString(string: "token-1"),
                                                       requiringSecureCoding: false)
        let different = try NSKeyedArchiver.archivedData(withRootObject: NSString(string: "token-2"),
                                                         requiringSecureCoding: false)
        XCTAssertNotEqual(immutable, mutable, "Precondition: equal tokens, different archive bytes")
        XCTAssertTrue(SkyrimSaveMirror.accountsMatch(immutable, mutable))
        XCTAssertFalse(SkyrimSaveMirror.accountsMatch(immutable, different))
        XCTAssertTrue(SkyrimSaveMirror.accountsMatch(TestAccounts.primary, TestAccounts.primary))
        XCTAssertFalse(SkyrimSaveMirror.accountsMatch(TestAccounts.primary, TestAccounts.other))
        XCTAssertFalse(SkyrimSaveMirror.accountsMatch(Data(), TestAccounts.other))
    }

    // MARK: Unsafe and ineligible files

    func testUnsafeFilesAreSkippedAndIneligibleFilesIgnored() throws {
        let box = try TestSandbox()
        let good = SyntheticSave.bytes("good")
        let secret = SyntheticSave.bytes("outside-secret"), cloudSecret = SyntheticSave.bytes("outside-cloud")
        let cloudCopy = SyntheticSave.bytes("cloud-linked")
        let secretURL = box.url("secret.ess", in: .outside), cloudSecretURL = box.url("cloud-secret.ess", in: .outside)
        try box.put(secret, at: secretURL)
        try box.put(cloudSecret, at: cloudSecretURL)
        // Unreadable targets: any attempt to follow a link would fail the sync rather than skip.
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: secretURL.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: cloudSecretURL.path)

        try box.put(good, "good.ess", in: .local, modified: t0)
        try box.link("linked.ess", in: .local, to: secretURL)          // local symlink; real file in iCloud
        try box.put(cloudCopy, "linked.ess", in: .cloud, modified: t0 + 999)
        try box.put(SyntheticSave.bytes("upload-me"), "cloudlink.ess", in: .local, modified: t0 + 999)
        try box.link("cloudlink.ess", in: .cloud, to: cloudSecretURL)  // iCloud symlink; real file locally
        try box.put(Data(), "empty.ess", in: .local)
        try FileManager.default.createDirectory(at: box.url("folder.ess", in: .local), withIntermediateDirectories: false)
        try box.put(SyntheticSave.bytes("txt"), "notes.txt", in: .local)
        try box.put(SyntheticSave.bytes("hidden"), ".hidden.ess", in: .local)
        try box.put(Data("ds".utf8), ".DS_Store", in: .local)
        try box.put(SyntheticSave.bytes("hidden-cloud"), ".cloud-hidden.ess", in: .cloud)
        try box.put(SyntheticSave.bytes("cloud-txt"), "readme.txt", in: .cloud)

        let expected = SkyrimSaveMirror.Report(fileCount: 1, uploaded: 1, skipped: 4)
        XCTAssertEqual(try box.sync(), expected)
        XCTAssertEqual(try box.sync(), .init(fileCount: 1, skipped: 4), "Skips are stable and not fatal")

        XCTAssertEqual(box.data("good.ess", in: .cloud), good)
        XCTAssertEqual(box.symlinkDestination("linked.ess", in: .local), secretURL.path)
        XCTAssertEqual(box.data("linked.ess", in: .cloud), cloudCopy)
        XCTAssertEqual(box.symlinkDestination("cloudlink.ess", in: .cloud), cloudSecretURL.path)
        XCTAssertEqual(box.entries(in: .cloud),
                       ["good.ess", "linked.ess", "cloudlink.ess", ".cloud-hidden.ess", "readme.txt"])
        XCTAssertEqual(box.entries(in: .local),
                       ["good.ess", "linked.ess", "cloudlink.ess", "empty.ess", "folder.ess",
                        "notes.txt", ".hidden.ess", ".DS_Store"])
        XCTAssertTrue(box.entries(in: .localConflicts).isEmpty)
        XCTAssertTrue(box.entries(in: .cloudConflicts).isEmpty)

        for url in [secretURL, cloudSecretURL] {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        XCTAssertEqual(box.data("secret.ess", in: .outside), secret)
        XCTAssertEqual(box.data("cloud-secret.ess", in: .outside), cloudSecret)
        XCTAssertEqual(box.entries(in: .outside), ["secret.ess", "cloud-secret.ess"])
    }

    func testSymlinkedSaveFolderIsRefused() throws {
        let box = try TestSandbox()
        let realFolder = try box.folder("real-saves")
        try box.put(SyntheticSave.bytes("a"), at: realFolder.appendingPathComponent("a.ess"))
        try FileManager.default.removeItem(at: box.url(.local))
        try FileManager.default.createSymbolicLink(at: box.url(.local), withDestinationURL: realFolder)

        XCTAssertThrowsError(try box.sync(), "A symlinked live save folder must not be mirrored")
        XCTAssertTrue(box.entries(in: .cloud).isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: realFolder.path), ["a.ess"])
    }

    // MARK: Deletion and pending downloads

    func testDeletionIsNeverPropagated() throws {
        let box = try TestSandbox()
        let bytes = SyntheticSave.bytes("keep")
        try box.put(bytes, save, in: .local, modified: t0)
        XCTAssertEqual(try box.sync(), .init(fileCount: 1, uploaded: 1))

        // Documented behaviour: a save deleted on this device comes back from iCloud.
        try box.remove(save, in: .local)
        XCTAssertEqual(try box.sync(), .init(fileCount: 1, downloaded: 1))
        XCTAssertEqual(box.data(save, in: .local), bytes)
        XCTAssertEqual(box.data(save, in: .cloud), bytes)

        // And a copy removed from iCloud is sent again rather than deleted here.
        try box.remove(save, in: .cloud)
        XCTAssertEqual(try box.sync(), .init(fileCount: 1, uploaded: 1))
        XCTAssertEqual(box.data(save, in: .cloud), bytes)
        XCTAssertEqual(box.data(save, in: .local), bytes)
    }

    func testDiscoveredButUndownloadedCloudSaveIsNeverOverwritten() throws {
        let box = try TestSandbox()
        let local = SyntheticSave.bytes("local")
        try box.put(local, save, in: .local, modified: t0)

        let report = try box.sync(discovered: [save])
        XCTAssertEqual(report, .init(pendingDownloads: 1))
        XCTAssertFalse(box.entries(in: .cloud).contains(save), "Never upload over a copy that was not read")
        XCTAssertEqual(box.data(save, in: .local), local)
        XCTAssertEqual(SaveSyncService.describe(report).0, "Partly synced")
    }

    func testIneligibleDiscoveredNamesAreIgnored() throws {
        let box = try TestSandbox()
        let before = box.snapshot()
        let names = ["../escape.ess", "nested/inner.ess", ".hidden.ess", "notes.txt", "", "back\\slash.ess"]
        XCTAssertEqual(try box.sync(discovered: names), .init())
        XCTAssertEqual(box.snapshot().filter { !$0.key.hasPrefix("state/") }, before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: box.root.appendingPathComponent("escape.ess").path))
    }

    // MARK: Status text

    func testDescribeSummarisesReports() {
        XCTAssertEqual(SaveSyncService.describe(.init()).0, "No saves to sync yet")

        let mixed = SaveSyncService.describe(.init(fileCount: 3, conflicts: 1, uploaded: 1, downloaded: 1))
        XCTAssertEqual(mixed.0, "Saves checked · iCloud delivery pending")
        XCTAssertTrue(mixed.1.hasPrefix("3 save(s) checked: 1 sent, 1 received."), mixed.1)
        XCTAssertTrue(mixed.1.contains("1 differing save(s) preserved"), mixed.1)

        let pending = SaveSyncService.describe(.init(fileCount: 1, pendingDownloads: 2))
        XCTAssertEqual(pending.0, "Partly synced")
        XCTAssertTrue(pending.1.contains("2 save(s) are still downloading"), pending.1)

        let skippedOnly = SaveSyncService.describe(.init(skipped: 2))
        XCTAssertNotEqual(skippedOnly.0, "No saves to sync yet", "Skipped files must be reported")
        XCTAssertTrue(skippedOnly.1.contains("2 unreadable or oversized file(s) were left untouched."), skippedOnly.1)
    }
}

/// The coordinated (iCloud) code path against plain temp folders: NSFileCoordinator works on any
/// local URL, and `currentAccount` is the injected signed-in-account check, so it doubles as a
/// hook that runs at each per-file safety check.
final class SaveMirrorCoordinatedTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    func testCoordinatedPathUploadsAndDownloads() throws {
        let box = try TestSandbox()
        let a = SyntheticSave.bytes("a"), b = SyntheticSave.bytes("b")
        try box.put(a, "a.ess", in: .local, modified: t0)
        try box.put(b, "b.ess", in: .cloud, modified: t0)

        XCTAssertEqual(try box.sync(box.mirror(coordinateCloud: true)), .init(fileCount: 2, uploaded: 1, downloaded: 1))
        XCTAssertEqual(box.data("a.ess", in: .cloud), a)
        XCTAssertEqual(box.data("b.ess", in: .local), b)
    }

    func testGameLaunchDuringSyncSealsTheLiveFolder() throws {
        let box = try TestSandbox()
        try box.put(SyntheticSave.bytes("a"), "a.ess", in: .local, modified: t0)
        try box.put(SyntheticSave.bytes("b"), "b.ess", in: .cloud, modified: t0)
        let gate = box.gate, uploaded = box.url("a.ess", in: .cloud).path
        // The game starts as soon as the first save has been sent, before b.ess is downloaded.
        let mirror = box.mirror(coordinateCloud: true) {
            if FileManager.default.fileExists(atPath: uploaded) { gate.setGameRunning(true) }
            return TestAccounts.primary
        }

        XCTAssertThrowsError(try box.sync(mirror)) { XCTAssertEqual($0 as? SaveSyncIssue, .gameRunning, "\($0)") }
        XCTAssertNotNil(box.data("a.ess", in: .cloud))
        XCTAssertFalse(box.entries(in: .local).contains("b.ess"), "No live-folder write after the game starts")
    }

    func testAccountSwitchDuringSyncStopsBeforeTheNextSave() throws {
        let box = try TestSandbox()
        try box.put(SyntheticSave.bytes("a"), "a.ess", in: .local, modified: t0)
        try box.put(SyntheticSave.bytes("b"), "b.ess", in: .local, modified: t0)
        let uploaded = box.url("a.ess", in: .cloud).path
        let switching = box.mirror(coordinateCloud: true) {
            FileManager.default.fileExists(atPath: uploaded) ? TestAccounts.other : TestAccounts.primary
        }

        XCTAssertThrowsError(try box.sync(switching)) { XCTAssertEqual($0 as? SaveSyncIssue, .accountChanged, "\($0)") }
        XCTAssertEqual(box.entries(in: .cloud), ["a.ess"], "Nothing is sent once the account differs")

        // The bound account is unchanged, so switching back resumes normally.
        XCTAssertEqual(try box.sync(box.mirror(coordinateCloud: true)), .init(fileCount: 2, uploaded: 1))
    }

    func testSignedOutAccountStopsBeforeAnyFileIsTouched() throws {
        let box = try TestSandbox()
        try box.put(SyntheticSave.bytes("a"), "a.ess", in: .local, modified: t0)
        try box.put(SyntheticSave.bytes("b"), "b.ess", in: .cloud, modified: t0)
        let before = box.snapshot()

        XCTAssertThrowsError(try box.sync(box.mirror(coordinateCloud: true) { nil })) {
            XCTAssertEqual($0 as? SaveSyncIssue, .noAccount, "\($0)")
        }
        XCTAssertEqual(box.snapshot(), before)
    }
}
