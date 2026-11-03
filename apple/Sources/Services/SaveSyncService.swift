import Combine
import CryptoKit
import Foundation

/// Where this launcher keeps the runtime's private Windows profile and saves on every platform.
/// The macOS runtime maps `C:\Users\Player\` to `runtimeRoot`, so the original game writes its
/// saves to `Documents/My Games/Skyrim/Saves` inside it.
enum SkyrimSaveLocations {
    static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Skyrim Jitless", isDirectory: true)
    }
    /// Passed to the runtime unchanged; this is the folder the existing Mac launcher used.
    static var runtimeRoot: URL { supportDirectory.appendingPathComponent("Saves", isDirectory: true) }
    static var saveGames: URL { resolve(["Documents", "My Games", "Skyrim", "Saves"], in: runtimeRoot) }
    static var conflicts: URL { supportDirectory.appendingPathComponent("SaveConflicts", isDirectory: true) }
    static var syncState: URL { supportDirectory.appendingPathComponent("SaveSync", isDirectory: true) }

    /// The runtime resolves Windows paths case-insensitively; follow an existing spelling if any.
    static func resolve(_ components: [String], in root: URL) -> URL {
        var url = root
        for component in components {
            let existing = (try? FileManager.default.contentsOfDirectory(atPath: url.path))?
                .first { $0.caseInsensitiveCompare(component) == .orderedSame }
            url = url.appendingPathComponent(existing ?? component, isDirectory: true)
        }
        return url
    }
}

enum CloudCapability {
    /// The signed configuration, not the account, decides whether iCloud code may run at all.
    static var isConfiguredInBuild: Bool {
        let value = Bundle.main.object(forInfoDictionaryKey: "SkyrimCloudSyncConfigured")
        return (value as? String) == "YES" || (value as? Bool) == true
    }
    static var containerIdentifier: String? {
        Bundle.main.object(forInfoDictionaryKey: "SkyrimICloudContainerIdentifier") as? String
    }
}

/// A local-save-first iCloud mirror inspired by Dark Eco and Titanfall's Apple launcher.
/// The game never opens cloud documents. Only original Skyrim .ess saves are eligible.
@MainActor
final class SaveSyncService: ObservableObject {
    @Published private(set) var status = "Cloud saves off"
    @Published private(set) var detail = "Saves stay on this device."
    @Published private(set) var isSyncing = false
    @Published private(set) var lastSyncDate: Date?
    @Published private(set) var needsAccountRecovery = false

    let localSaveDirectory: URL
    let conflictsDirectory: URL
    private let preferences: LauncherPreferences
    private let stateDirectory: URL
    private let gate = SaveWriteGate()
    private var subscription: AnyCancellable?

    init(preferences: LauncherPreferences) {
        self.preferences = preferences
        localSaveDirectory = SkyrimSaveLocations.saveGames
        conflictsDirectory = SkyrimSaveLocations.conflicts
        stateDirectory = SkyrimSaveLocations.syncState
        lastSyncDate = UserDefaults.standard.object(forKey: "SkyrimApple.lastSaveSyncDate") as? Date
        // @Published emits before the stored value changes, so act on the delivered value.
        subscription = preferences.$cloudSyncEnabled.dropFirst().removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                MainActor.assumeIsolated {
                    if !enabled { self?.gate.cancel() }
                    self?.refreshAvailability()
                }
            }
        refreshAvailability()
    }

    /// Must be sealed before a runtime starts, and remain sealed while it is paused. A worker
    /// that was awaiting iCloud cannot write the live directory after this method returns.
    func setGameRunning(_ running: Bool) { gate.setGameRunning(running) }

    func refreshAvailability() {
        guard !isSyncing else { return }
        guard preferences.cloudSyncEnabled else {
            status = "Cloud saves off"; detail = "Saves stay on this device."; return
        }
        guard CloudCapability.isConfiguredInBuild else {
            status = "iCloud unavailable in this build"
            detail = "This build is signed without iCloud. Local saves remain available."
            return
        }
        guard FileManager.default.ubiquityIdentityToken != nil else {
            status = "iCloud unavailable"
            detail = "Sign in to iCloud and turn on iCloud Drive in system settings, or keep playing locally."
            return
        }
        if needsAccountRecovery { return }
        status = "Ready to sync"
        detail = "Sync runs while the game is closed. iCloud manages upload and download delivery."
    }

    func syncNow(gameIsRunning: Bool) async {
        guard !isSyncing else { return }
        guard preferences.cloudSyncEnabled, CloudCapability.isConfiguredInBuild else { refreshAvailability(); return }
        guard !gameIsRunning, !gate.isGameRunning else {
            status = "Sync waits for the game to close"
            detail = "The running game's saves are protected, including while paused."
            return
        }
        isSyncing = true
        gate.begin()
        status = "Checking iCloud saves"
        detail = "Your original installation and game assets are never synced."
        defer { isSyncing = false }
        do {
            let identifier = CloudCapability.containerIdentifier
            let location = try await Task.detached(priority: .utility) {
                try SaveCloudLocation.resolve(identifier: identifier)
            }.value
            let savesRoot = location.root.appendingPathComponent("Documents/Skyrim/Saves", isDirectory: true)
            let cloudConflicts = location.root.appendingPathComponent("Documents/Skyrim/SaveConflicts", isDirectory: true)
            // A bounded metadata gather avoids treating an incomplete FileProvider directory
            // listing as an authoritative empty cloud folder.
            let cloudNames = try await SaveCloudDiscovery(root: savesRoot).gather()
            guard preferences.cloudSyncEnabled else { throw SaveSyncIssue.disabled }
            let engine = SkyrimSaveMirror(localRoot: localSaveDirectory, cloudRoot: savesRoot,
                localConflicts: conflictsDirectory, cloudConflicts: cloudConflicts,
                stateRoot: stateDirectory, account: location.account, gate: gate, coordinateCloud: true)
            let report = try await Task.detached(priority: .utility) {
                try engine.synchronize(discoveredCloudNames: cloudNames)
            }.value
            needsAccountRecovery = false
            lastSyncDate = .now
            UserDefaults.standard.set(lastSyncDate, forKey: "SkyrimApple.lastSaveSyncDate")
            (status, detail) = Self.describe(report)
        } catch SaveSyncIssue.accountChanged {
            needsAccountRecovery = true
            status = "iCloud account changed"
            detail = SaveSyncIssue.accountChanged.localizedDescription
        } catch {
            status = "Cloud saves need attention"
            detail = error.localizedDescription
        }
    }

    /// Forgets which iCloud account this device last mirrored. Saves and archives stay in
    /// place; the next sync treats every differing save as a conflict and preserves both.
    func resetCloudPairing() {
        guard !isSyncing else { return }
        let state = stateDirectory.appendingPathComponent(SkyrimSaveMirror.stateFileName)
        if FileManager.default.fileExists(atPath: state.path) {
            let stamp = ISO8601DateFormatter().string(from: .now).replacingOccurrences(of: ":", with: "-")
            try? FileManager.default.moveItem(at: state,
                to: stateDirectory.appendingPathComponent("mirror-v1-retired-\(stamp).json"))
        }
        needsAccountRecovery = false
        refreshAvailability()
    }

    nonisolated static func describe(_ report: SkyrimSaveMirror.Report) -> (String, String) {
        var notes: [String] = []
        if report.conflicts > 0 {
            notes.append("\(report.conflicts) differing save(s) preserved in Preserved Saves on this device and in iCloud.")
        }
        if report.pendingDownloads > 0 {
            notes.append("\(report.pendingDownloads) save(s) are still downloading from iCloud; sync again shortly.")
        }
        if report.skipped > 0 {
            notes.append("\(report.skipped) unreadable or oversized file(s) were left untouched.")
        }
        if report.fileCount == 0 && notes.isEmpty {
            return ("No saves to sync yet", "Saves you make in Skyrim appear here after the next sync.")
        }
        let summary = "\(report.fileCount) save(s) checked: \(report.uploaded) sent, \(report.downloaded) received."
        return (report.pendingDownloads > 0 ? "Partly synced" : "Saves checked · iCloud delivery pending",
                ([summary] + notes).joined(separator: " "))
    }
}

private struct SaveCloudLocation: Sendable {
    let root: URL
    let account: Data

    static func resolve(identifier: String?) throws -> SaveCloudLocation {
        let manager = FileManager.default
        guard let token = manager.ubiquityIdentityToken else { throw SaveSyncIssue.noAccount }
        guard let root = manager.url(forUbiquityContainerIdentifier: identifier) else {
            throw SaveSyncIssue.noContainer
        }
        return SaveCloudLocation(root: root,
            account: try NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: false))
    }
}

enum SaveSyncIssue: LocalizedError, Equatable {
    case noAccount, noContainer, accountChanged, gameRunning, disabled
    case unsafeFile(String), changedFile(String), downloading(String), discoveryTimedOut, discoveryFailed
    var errorDescription: String? {
        switch self {
        case .noAccount: return "iCloud is unavailable. Local saves are safe; check iCloud Drive in system settings."
        case .noContainer: return "This app's iCloud container is unavailable. Check its signing capability and iCloud Drive. Local saves are safe."
        case .accountChanged: return "The iCloud account changed. Sync stopped to keep each account's saves separate. Switch back, or reset the pairing to start over with both copies preserved."
        case .gameRunning: return "Sync waits until the game closes. No live save was replaced."
        case .disabled: return "Cloud saves were turned off. Local saves remain available."
        case .unsafeFile(let name): return "Sync skipped an unsafe or oversized save: \(name)."
        case .changedFile(let name): return "A save changed while syncing: \(name). Close the game and retry."
        case .downloading(let name): return "iCloud is downloading \(name). Wait for the download, then sync again."
        case .discoveryTimedOut: return "iCloud did not finish checking for saves. Check your connection and retry."
        case .discoveryFailed: return "iCloud could not start checking for saves. Local saves remain available."
        }
    }
}

/// A launch seal and cancellation flag, shared by the main actor and the background file
/// worker. The lock is held only through a local mutation; a stalled cloud read never blocks
/// launch on this lock.
final class SaveWriteGate: @unchecked Sendable {
    /// Recursive: a `withLocalWrite` body re-checks the gate inside `SkyrimSaveMirror.write`.
    private let lock = NSRecursiveLock()
    private var running = false
    private var cancelled = false
    var isGameRunning: Bool { lock.withLock { running } }
    func setGameRunning(_ value: Bool) { lock.withLock { running = value } }
    func begin() { lock.withLock { cancelled = false } }
    func cancel() { lock.withLock { cancelled = true } }
    func checkActive() throws {
        try lock.withLock {
            if running { throw SaveSyncIssue.gameRunning }
            if cancelled { throw SaveSyncIssue.disabled }
        }
    }
    func withLocalWrite<T>(_ body: () throws -> T) throws -> T {
        try lock.withLock {
            if running { throw SaveSyncIssue.gameRunning }
            if cancelled { throw SaveSyncIssue.disabled }
            return try body()
        }
    }
}

/// Pure directory-mirror core. Tests inject ordinary directories instead of a real account.
/// No deletion propagates, no symlink is followed, and every replacement checks the old bytes.
struct SkyrimSaveMirror: Sendable {
    static let stateFileName = "mirror-v1.json"
    static let maximumSaveBytes = 128 * 1024 * 1024

    let localRoot: URL
    let cloudRoot: URL
    let localConflicts: URL
    let cloudConflicts: URL
    let stateRoot: URL
    let account: Data
    let gate: SaveWriteGate
    let coordinateCloud: Bool
    /// Tests substitute the signed-in account check; production compares the live iCloud token.
    var currentAccount: @Sendable () -> Data? = SkyrimSaveMirror.liveAccount

    struct Report: Sendable, Equatable {
        var fileCount = 0, conflicts = 0, uploaded = 0, downloaded = 0, skipped = 0, pendingDownloads = 0
    }
    private struct State: Codable { let account: Data; var baselines: [String: String] }
    private struct File: Sendable {
        let bytes: Data
        let date: Date?
        var digest: String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    }

    static func isEligibleName(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix(".") && !name.contains("/") && !name.contains("\\")
            && !name.contains("\0") && name.utf8.count <= 255
            && URL(fileURLWithPath: name).pathExtension.lowercased() == "ess"
    }

    static func liveAccount() -> Data? {
        guard let token = FileManager.default.ubiquityIdentityToken else { return nil }
        return try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: false)
    }

    static func accountsMatch(_ first: Data, _ second: Data) -> Bool {
        if first == second { return true }
        func decode(_ data: Data) -> NSObject? {
            guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
            unarchiver.requiresSecureCoding = false
            defer { unarchiver.finishDecoding() }
            return unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey) as? NSObject
        }
        guard let left = decode(first), let right = decode(second) else { return false }
        return left.isEqual(right)
    }

    func synchronize(discoveredCloudNames: [String] = []) throws -> Report {
        try gate.checkActive()
        try gate.withLocalWrite { try directory(localRoot, cloud: false) }
        try directory(stateRoot, cloud: false)
        let stateURL = stateRoot.appendingPathComponent(Self.stateFileName)
        var state = State(account: account, baselines: [:])
        if FileManager.default.fileExists(atPath: stateURL.path) {
            state = try JSONDecoder().decode(State.self, from: Data(contentsOf: stateURL))
            guard Self.accountsMatch(state.account, account) else { throw SaveSyncIssue.accountChanged }
        }
        try checkAccount()
        try directory(cloudRoot, cloud: coordinateCloud)
        let discovered = Set(discoveredCloudNames.filter(Self.isEligibleName))
        let localNames = try names(in: localRoot)
        let cloudNames = try names(in: cloudRoot).union(discovered)
        var report = Report()
        for name in localNames.union(cloudNames).sorted() {
            try gate.checkActive()
            try checkAccount()
            do {
                try synchronizeFile(name, discovered: discovered.contains(name), state: &state, report: &report)
            } catch SaveSyncIssue.unsafeFile {
                report.skipped += 1
            } catch SaveSyncIssue.downloading {
                report.pendingDownloads += 1
            }
            try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
        }
        // Persist the account even when there are no saves, before a later account can merge.
        try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
        return report
    }

    private func synchronizeFile(_ name: String, discovered: Bool, state: inout State, report: inout Report) throws {
        let localURL = localRoot.appendingPathComponent(name)
        let cloudURL = cloudRoot.appendingPathComponent(name)
        let local = try read(localURL, cloud: false)
        let cloud = try read(cloudURL, cloud: coordinateCloud)
        if cloud == nil && (discovered || hasLegacyPlaceholder(for: cloudURL)) {
            // iCloud knows about this save but has not materialized it here. Never upload over
            // a copy we have not read.
            try? FileManager.default.startDownloadingUbiquitousItem(at: cloudURL)
            throw SaveSyncIssue.downloading(name)
        }
        if local == nil && cloud == nil { return }
        report.fileCount += 1
        switch (local, cloud) {
        case (let local?, nil):
            try write(local, to: cloudURL, expected: nil, cloud: coordinateCloud)
            state.baselines[name] = local.digest
            report.uploaded += 1
        case (nil, let cloud?):
            try gate.withLocalWrite { try write(cloud, to: localURL, expected: nil, cloud: false) }
            state.baselines[name] = cloud.digest
            report.downloaded += 1
        case (let local?, let cloud?):
            if local.digest == cloud.digest { state.baselines[name] = local.digest; break }
            let baseline = state.baselines[name]
            if baseline == local.digest {
                try gate.withLocalWrite { try write(cloud, to: localURL, expected: local.digest, cloud: false) }
                state.baselines[name] = cloud.digest
                report.downloaded += 1
            } else if baseline == cloud.digest {
                try write(local, to: cloudURL, expected: cloud.digest, cloud: coordinateCloud)
                state.baselines[name] = local.digest
                report.uploaded += 1
            } else {
                // Preserve both originals before choosing a winner. Missing/equal dates keep
                // this device's copy. Hash-named archives are stable across retries.
                try archive(local, name: name, source: "device")
                try archive(cloud, name: name, source: "icloud")
                report.conflicts += 1
                if let cloudDate = cloud.date, let localDate = local.date, cloudDate > localDate {
                    try gate.withLocalWrite { try write(cloud, to: localURL, expected: local.digest, cloud: false) }
                    state.baselines[name] = cloud.digest
                    report.downloaded += 1
                } else {
                    try write(local, to: cloudURL, expected: cloud.digest, cloud: coordinateCloud)
                    state.baselines[name] = local.digest
                    report.uploaded += 1
                }
            }
        case (nil, nil): break
        }
        try preserveCloudVersions(at: cloudURL, name: name)
    }

    private func checkAccount() throws {
        guard coordinateCloud else { return }
        guard let current = currentAccount() else { throw SaveSyncIssue.noAccount }
        guard Self.accountsMatch(account, current) else { throw SaveSyncIssue.accountChanged }
    }

    private func names(in root: URL) throws -> Set<String> {
        let items = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        return Set(items.map(\.lastPathComponent).filter(Self.isEligibleName))
    }

    /// Before FileProvider-backed iCloud Drive, undownloaded items were `.name.icloud` stubs.
    private func hasLegacyPlaceholder(for url: URL) -> Bool {
        guard coordinateCloud else { return false }
        let stub = url.deletingLastPathComponent().appendingPathComponent("." + url.lastPathComponent + ".icloud")
        return FileManager.default.fileExists(atPath: stub.path)
    }

    private func directory(_ url: URL, cloud: Bool) throws {
        try access(url, cloud: cloud, writing: true) { target in
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            let values = try target.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            guard values.isSymbolicLink != true, values.isDirectory == true else {
                throw SaveSyncIssue.unsafeFile(target.lastPathComponent)
            }
        }
    }

    private func read(_ url: URL, cloud: Bool) throws -> File? {
        try access(url, cloud: cloud, writing: false) { target in
            // lstat semantics: a symlink is reported as present even when its target is not.
            guard (try? FileManager.default.attributesOfItem(atPath: target.path)) != nil else { return nil }
            let values = try target.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey,
                .fileSizeKey, .contentModificationDateKey, .ubiquitousItemDownloadingStatusKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  let size = values.fileSize, size > 0, size <= Self.maximumSaveBytes else {
                throw SaveSyncIssue.unsafeFile(target.lastPathComponent)
            }
            if cloud, let download = values.ubiquitousItemDownloadingStatus,
               download != .current && download != .downloaded {
                try FileManager.default.startDownloadingUbiquitousItem(at: target)
                throw SaveSyncIssue.downloading(target.lastPathComponent)
            }
            let first = try Data(contentsOf: target)
            guard first.count == size, first == (try Data(contentsOf: target)) else {
                throw SaveSyncIssue.changedFile(target.lastPathComponent)
            }
            return File(bytes: first, date: values.contentModificationDate)
        }
    }

    private func write(_ file: File, to url: URL, expected: String?, cloud: Bool) throws {
        try gate.checkActive()
        try checkAccount()
        try access(url, cloud: cloud, writing: true) { target in
            // Already in a coordination accessor: avoid nesting a coordinator for the CAS read.
            let current: File?
            do { current = try read(target, cloud: false) } catch SaveSyncIssue.unsafeFile {
                // An unreadable destination (symlink, empty, oversized) is never replaced.
                throw SaveSyncIssue.changedFile(target.lastPathComponent)
            }
            guard current?.digest == expected else {
                throw SaveSyncIssue.changedFile(target.lastPathComponent)
            }
            try file.bytes.write(to: target, options: .atomic)
            if let date = file.date {
                try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: target.path)
            }
        }
    }

    static func archiveName(for name: String, source: String, digest: String) -> String {
        let stem = URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
        // The original basename is bounded; truncate only the archive basename if necessary.
        return String(stem.prefix(75)) + "--" + source + "-" + digest + ".ess"
    }

    private func archive(_ file: File, name: String, source: String) throws {
        let archiveName = Self.archiveName(for: name, source: source, digest: file.digest)
        for (root, cloud) in [(localConflicts, false), (cloudConflicts, coordinateCloud)] {
            try directory(root, cloud: cloud)
            let destination = root.appendingPathComponent(archiveName)
            if let existing = try read(destination, cloud: cloud) {
                guard existing.digest == file.digest else { throw SaveSyncIssue.changedFile(archiveName) }
            } else {
                try write(file, to: destination, expected: nil, cloud: cloud)
            }
        }
    }

    private func preserveCloudVersions(at url: URL, name: String) throws {
        guard coordinateCloud,
              (try? url.resourceValues(forKeys: [.ubiquitousItemHasUnresolvedConflictsKey]))?
                .ubiquitousItemHasUnresolvedConflicts == true else { return }
        // A reading coordinator: inspecting versions must not mark the cloud item as modified.
        try access(url, cloud: true, writing: false) { target in
            let versions = NSFileVersion.unresolvedConflictVersionsOfItem(at: target) ?? []
            for version in versions {
                guard let file = try read(version.url, cloud: false) else {
                    throw SaveSyncIssue.changedFile(name)
                }
                try directory(localConflicts, cloud: false)
                let destination = localConflicts.appendingPathComponent(
                    Self.archiveName(for: name, source: "version", digest: file.digest))
                if let existing = try read(destination, cloud: false) {
                    guard existing.digest == file.digest else { throw SaveSyncIssue.changedFile(name) }
                } else { try write(file, to: destination, expected: nil, cloud: false) }
                // Leave the provider's unresolved versions intact. They must not be discarded
                // until the player explicitly chooses a copy.
            }
        }
    }

    private func access<T>(_ url: URL, cloud: Bool, writing: Bool, body: (URL) throws -> T) throws -> T {
        guard cloud else { return try body(url) }
        var coordinationError: NSError?
        var result: Result<T, Error>?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        if writing {
            coordinator.coordinate(writingItemAt: url, options: [], error: &coordinationError) { coordinatedURL in
                result = Result { try body(coordinatedURL) }
            }
        } else {
            coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinatedURL in
                result = Result { try body(coordinatedURL) }
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw SaveSyncIssue.discoveryFailed }
        return try result.get()
    }
}

@MainActor
private final class SaveCloudDiscovery {
    let root: URL
    let query = NSMetadataQuery()
    var continuation: CheckedContinuation<[String], Error>?
    var observer: NSObjectProtocol?
    var timeout: Task<Void, Never>?

    init(root: URL) { self.root = root.standardizedFileURL }

    func gather() async throws -> [String] {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
                query.predicate = NSPredicate(value: true)
                query.operationQueue = .main
                observer = NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering,
                    object: query, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.didGather() }
                }
                timeout = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(12))
                    guard !Task.isCancelled else { return }
                    self?.finish(.failure(SaveSyncIssue.discoveryTimedOut))
                }
                if !query.start() { finish(.failure(SaveSyncIssue.discoveryFailed)) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(.failure(CancellationError())) }
        }
    }

    private func didGather() {
        query.disableUpdates()
        let names = query.results.compactMap { result -> String? in
            guard let item = result as? NSMetadataItem,
                  let url = item.value(forAttribute: NSMetadataItemURLKey) as? URL,
                  url.deletingLastPathComponent().standardizedFileURL == root,
                  SkyrimSaveMirror.isEligibleName(url.lastPathComponent) else { return nil }
            return url.lastPathComponent
        }
        finish(.success(names))
    }

    private func finish(_ result: Result<[String], Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timeout?.cancel(); timeout = nil
        query.stop()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        continuation.resume(with: result)
    }
}
