#if os(macOS)
import Darwin
import Foundation

/// Runs `macos/launcher/bridge.py` from the local checkout, exactly as the earlier Mac launcher
/// did. The bridge streams a `processStarted` event and then one JSON result line.
enum MacRuntimeBridge {
    struct Response: Decodable, Sendable {
        let success: Bool
        let headline: String
        let detail: String
        let isReady: Bool
        let canPrepare: Bool
        let error: String?
        let logPath: String?
    }

    struct Outcome: Sendable {
        let response: Response?
        let exitCode: Int32
        let fallbackLogPath: String?
    }

    private struct Event: Decodable {
        let event: String
        let processID: Int32?
    }

    static func checkoutDirectory() -> URL? {
        let environmentPath = ProcessInfo.processInfo.environment["SKYRIM_CHECKOUT"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let bundledPath = Bundle.main.url(forResource: "checkout-path", withExtension: "txt")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let path = [environmentPath, bundledPath].compactMap({ $0 }).first(where: { !$0.isEmpty }) else {
            return nil
        }
        let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        let bridge = url.appendingPathComponent("macos/launcher/bridge.py")
        return FileManager.default.fileExists(atPath: bridge.path) ? url : nil
    }

    static func gameExecutable(in checkout: URL) -> URL {
        checkout.appendingPathComponent("macos/build/native/skyrim_macos").resolvingSymlinksInPath()
    }

    static func run(checkout: URL, command: String, game: URL?, saves: URL,
                    onStarted: @escaping @MainActor @Sendable (Int32) -> Void) -> Outcome {
        let process = Process()
        let localPython = checkout.appendingPathComponent("macos/.venv/bin/python")
        process.executableURL = FileManager.default.isExecutableFile(atPath: localPython.path)
            ? localPython : URL(fileURLWithPath: "/usr/bin/python3")
        var arguments = [checkout.appendingPathComponent("macos/launcher/bridge.py").path, command,
                         "--save-dir", saves.path]
        if let game { arguments += ["--game-dir", game.path] }
        process.arguments = arguments
        process.currentDirectoryURL = checkout
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        environment["PYTHONUNBUFFERED"] = "1"
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        var response: Response?
        var buffered = Data()
        let decoder = JSONDecoder()
        let fallbackURL = checkout.appendingPathComponent("macos/build/launcher/bridge-\(UUID().uuidString).log")
        try? FileManager.default.createDirectory(at: fallbackURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: fallbackURL.path, contents: nil)
        let fallbackLog = try? FileHandle(forWritingTo: fallbackURL)
        defer { try? fallbackLog?.close() }
        func consume(_ line: Data) {
            if let event = try? decoder.decode(Event.self, from: line), event.event == "processStarted",
               let pid = event.processID {
                Task { @MainActor in onStarted(pid) }
            } else if let parsed = try? decoder.decode(Response.self, from: line) {
                response = parsed
            }
        }
        do {
            try process.run()
            while true {
                let data = pipe.fileHandleForReading.availableData
                if data.isEmpty { break }
                try? fallbackLog?.write(contentsOf: data)
                buffered.append(data)
                while let end = buffered.firstIndex(of: 10) {
                    consume(buffered.subdata(in: buffered.startIndex..<end))
                    buffered.removeSubrange(buffered.startIndex...end)
                }
            }
            if !buffered.isEmpty { consume(buffered) }
            process.waitUntilExit()
            return Outcome(response: response, exitCode: process.terminationStatus, fallbackLogPath: fallbackURL.path)
        } catch {
            try? fallbackLog?.write(contentsOf: Data(error.localizedDescription.utf8))
            return Outcome(response: nil, exitCode: -1, fallbackLogPath: fallbackURL.path)
        }
    }
}

/// The bridge reports the `run.sh` process ID; `run.sh` later `exec`s the native game in place.
/// Every signal re-checks that the PID currently runs the expected game executable, so a shell
/// still verifying receipts, or a recycled PID after exit, is never signalled.
struct MacGameProcess: Sendable, Equatable {
    let pid: pid_t
    let executable: URL

    var isGame: Bool {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return false }
        let path = String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().path == executable.path
    }

    func suspend() -> Bool { isGame && kill(pid, SIGSTOP) == 0 }
    func resume() -> Bool { isGame && kill(pid, SIGCONT) == 0 }

    /// Asks the game to quit. A suspended process must also be continued to handle SIGTERM.
    func terminate() -> Bool {
        guard isGame else { return false }
        let sent = kill(pid, SIGTERM) == 0
        _ = kill(pid, SIGCONT)
        return sent
    }
}
#endif
