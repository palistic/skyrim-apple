import CryptoKit
import Foundation
import XCTest

/// Synthetic account tokens. Real iCloud tokens are never read by these tests.
enum TestAccounts {
    static let primary = Data("synthetic-account-A".utf8)
    static let other = Data("synthetic-account-B".utf8)
}

enum SyntheticSave {
    /// A tiny original-format save: valid magic followed by a distinguishable body.
    static func bytes(_ tag: String) -> Data {
        SaveHeader.magic + Data("|synthetic-body|\(tag)|".utf8)
    }

    /// Matches the mirror's archive-name digest (lowercase SHA-256 hex).
    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct DeadlineExceeded: Error {}

private final class DeadlineBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<T, any Error>?
    func set(_ value: Result<T, any Error>) { lock.withLock { result = value } }
    func get() throws -> T {
        guard let result = lock.withLock({ result }) else { throw DeadlineExceeded() }
        return try result.get()
    }
}

/// Runs `body` on its own thread, as production runs the mirror off the main actor, so a lock
/// that is re-entered fails this test instead of hanging the whole run.
func runWithDeadline<T: Sendable>(_ seconds: TimeInterval = 30, file: StaticString = #filePath,
                                  line: UInt = #line, _ body: @escaping @Sendable () throws -> T) throws -> T {
    let box = DeadlineBox<T>()
    let finished = DispatchSemaphore(value: 0)
    let worker = Thread {
        box.set(Result(catching: body))
        finished.signal()
    }
    // The waiting test thread is user-interactive; match it to avoid a priority inversion.
    worker.qualityOfService = .userInteractive
    worker.start()
    guard finished.wait(timeout: .now() + seconds) == .success else {
        XCTFail("Did not finish within \(Int(seconds)) s; a lock was probably re-entered.", file: file, line: line)
        throw DeadlineExceeded()
    }
    return try box.get()
}

func assertSameInstant(_ actual: Date?, _ expected: Date, file: StaticString = #filePath, line: UInt = #line) {
    guard let actual else { return XCTFail("Missing modification date", file: file, line: line) }
    XCTAssertEqual(actual.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 0.001,
                   file: file, line: line)
}

/// A throwaway folder tree under the process temporary directory. Removed on deinit.
final class TestSandbox {
    enum Area: String, CaseIterable {
        case local, cloud, localConflicts, cloudConflicts, state, outside
    }

    let root: URL
    let gate = SaveWriteGate()

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SkyrimLauncherTests-\(UUID().uuidString)", isDirectory: true)
        for area in Area.allCases {
            try FileManager.default.createDirectory(at: url(area), withIntermediateDirectories: true)
        }
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func url(_ area: Area) -> URL { root.appendingPathComponent(area.rawValue, isDirectory: true) }
    func url(_ name: String, in area: Area) -> URL { url(area).appendingPathComponent(name) }
    var stateFile: URL { url(SkyrimSaveMirror.stateFileName, in: .state) }

    func folder(_ name: String) throws -> URL {
        let folder = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    func put(_ data: Data, _ name: String, in area: Area, modified: Date? = nil) throws {
        try put(data, at: url(name, in: area), modified: modified)
    }

    func put(_ data: Data, at url: URL, modified: Date? = nil) throws {
        try data.write(to: url)
        if let modified { try setModified(modified, at: url) }
    }

    func setModified(_ date: Date, at url: URL) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    func link(_ name: String, in area: Area, to destination: URL) throws {
        try FileManager.default.createSymbolicLink(at: url(name, in: area), withDestinationURL: destination)
    }

    func remove(_ name: String, in area: Area) throws {
        try FileManager.default.removeItem(at: url(name, in: area))
    }

    /// Bytes of a regular file (nil for anything else, including symlinks).
    func data(_ name: String, in area: Area) -> Data? {
        let path = url(name, in: area).path
        guard (try? FileManager.default.attributesOfItem(atPath: path))?[.type] as? FileAttributeType == .typeRegular
        else { return nil }
        return FileManager.default.contents(atPath: path)
    }

    func modified(_ name: String, in area: Area) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url(name, in: area).path))?[.modificationDate] as? Date
    }

    func symlinkDestination(_ name: String, in area: Area) -> String? {
        try? FileManager.default.destinationOfSymbolicLink(atPath: url(name, in: area).path)
    }

    /// Every directory entry name, hidden ones included.
    func entries(in area: Area) -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: url(area).path)) ?? [])
    }

    /// Regular files only, keyed by name.
    func files(in area: Area) -> [String: Data] {
        var result: [String: Data] = [:]
        for name in entries(in: area) { if let bytes = data(name, in: area) { result[name] = bytes } }
        return result
    }

    /// Every item below the sandbox root: type, content digest and modification date.
    func snapshot() -> [String: String] {
        var result: [String: String] = [:]
        func walk(_ directory: URL, prefix: String) {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [] {
                let item = directory.appendingPathComponent(name)
                let key = prefix + name
                let attributes = (try? FileManager.default.attributesOfItem(atPath: item.path)) ?? [:]
                switch attributes[.type] as? FileAttributeType {
                case .typeDirectory?:
                    result[key] = "dir"
                    walk(item, prefix: key + "/")
                case .typeSymbolicLink?:
                    result[key] = "link:" + ((try? FileManager.default.destinationOfSymbolicLink(atPath: item.path)) ?? "?")
                default:
                    let digest = FileManager.default.contents(atPath: item.path).map(SyntheticSave.digest) ?? "unreadable"
                    let date = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                    result[key] = "file:\(digest)@\(date)"
                }
            }
        }
        walk(root, prefix: "")
        return result
    }

    func mirror(account: Data = TestAccounts.primary, gate: SaveWriteGate? = nil, coordinateCloud: Bool = false,
                currentAccount: (@Sendable () -> Data?)? = nil) -> SkyrimSaveMirror {
        var mirror = SkyrimSaveMirror(localRoot: url(.local), cloudRoot: url(.cloud),
            localConflicts: url(.localConflicts), cloudConflicts: url(.cloudConflicts),
            stateRoot: url(.state), account: account, gate: gate ?? self.gate, coordinateCloud: coordinateCloud)
        // Never consult the real signed-in iCloud account from a test.
        mirror.currentAccount = currentAccount ?? { account }
        return mirror
    }

    func sync(_ mirror: SkyrimSaveMirror? = nil, discovered: [String] = [],
              file: StaticString = #filePath, line: UInt = #line) throws -> SkyrimSaveMirror.Report {
        let mirror = mirror ?? self.mirror()
        return try runWithDeadline(file: file, line: line) {
            try mirror.synchronize(discoveredCloudNames: discovered)
        }
    }
}

extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    /// Skyrim's length-prefixed string: u16 byte count, then the bytes.
    mutating func appendWString(_ string: String, declaredLength: UInt16? = nil) {
        let bytes = Data(string.utf8)
        appendLittleEndian(declaredLength ?? UInt16(bytes.count))
        append(bytes)
    }
}
