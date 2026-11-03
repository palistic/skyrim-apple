import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

@MainActor
final class LauncherModel: ObservableObject {
    @Published var gameDirectory: URL?
    @Published var artworkURL: URL?
    @Published var headline = "Choose your Skyrim folder"
    @Published var detail = "Select your original Windows Skyrim installation to get started."
    @Published var isBusy = false
    @Published var isReady = false
    @Published var canPrepare = false
    @Published var operation = ""
    @Published var lastError: String?

    private let preferences = UserDefaults.standard
    private let gameKey = "SkyrimJitlessLauncher.gameDirectory"
    private let artworkKey = "SkyrimJitlessLauncher.artworkURL"
    private let logKey = "SkyrimJitlessLauncher.lastLog"
    private let checkoutDirectory: URL?
    private var logURL: URL?

    private var savesDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Skyrim Jitless", isDirectory: true)
            .appendingPathComponent("Saves", isDirectory: true)
    }

    init() {
        let environmentPath = ProcessInfo.processInfo.environment["SKYRIM_CHECKOUT"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let bundledPath = Bundle.main.url(forResource: "checkout-path", withExtension: "txt")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let checkoutPath = [environmentPath, bundledPath].compactMap { $0 }.first { !$0.isEmpty }
        checkoutDirectory = checkoutPath.map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
        if let path = preferences.string(forKey: gameKey) {
            gameDirectory = URL(fileURLWithPath: path, isDirectory: true)
        }
        if let path = preferences.string(forKey: artworkKey), FileManager.default.fileExists(atPath: path) {
            artworkURL = URL(fileURLWithPath: path)
        }
        if let path = preferences.string(forKey: logKey) {
            logURL = URL(fileURLWithPath: path)
        }
        refresh()
    }

    func chooseFolder() {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose Skyrim"
        panel.message = "Select the original Windows Skyrim folder containing TESV.exe and Data."
        panel.prompt = "Choose Skyrim"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = gameDirectory
        guard panel.runModal() == .OK, let selected = panel.url else { return }
        gameDirectory = selected.standardizedFileURL
        preferences.set(gameDirectory?.path, forKey: gameKey)
        refresh()
    }

    func chooseArtwork() {
        let panel = NSOpenPanel()
        panel.title = "Choose Skyrim Artwork"
        panel.prompt = "Choose Artwork"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let selected = panel.url else { return }
        artworkURL = selected.standardizedFileURL
        preferences.set(artworkURL?.path, forKey: artworkKey)
    }

    func resetArtwork() {
        artworkURL = nil
        preferences.removeObject(forKey: artworkKey)
    }

    func refresh() {
        perform("status", label: "Checking", message: "Checking your local Skyrim files…")
    }

    func prepareAndBuild() {
        guard canPrepare else { return }
        perform("prepare", label: "Preparing", message: "Preparing your private macOS copy. This can take a while.")
    }

    func launchGame() {
        guard isReady else { return }
        perform("launch", label: "Launching", message: "Starting Skyrim…")
    }

    func revealSaves() {
        do {
            try FileManager.default.createDirectory(at: savesDirectory, withIntermediateDirectories: true)
            NSWorkspace.shared.open(savesDirectory)
        } catch {
            lastError = "The saves folder could not be opened."
        }
    }

    func revealLog() {
        if let logURL, FileManager.default.fileExists(atPath: logURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([logURL])
        } else if let checkoutDirectory {
            let folder = checkoutDirectory.appendingPathComponent("macos/build/launcher", isDirectory: true)
            if FileManager.default.fileExists(atPath: folder.path) {
                NSWorkspace.shared.open(folder)
            } else {
                lastError = "There is no launcher log yet."
            }
        }
    }

    private func perform(_ command: String, label: String, message: String) {
        guard !isBusy else { return }
        guard let checkoutDirectory,
              FileManager.default.fileExists(atPath: checkoutDirectory.appendingPathComponent("macos/launcher/bridge.py").path) else {
            headline = "Launcher setup is incomplete"
            detail = "The local Skyrim workspace could not be found."
            lastError = "Rebuild this launcher from the Skyrim workspace."
            isReady = false
            canPrepare = false
            return
        }
        isBusy = true
        isReady = false
        canPrepare = false
        operation = label
        lastError = nil
        detail = message
        let game = gameDirectory
        let saves = savesDirectory
        let onStarted: @MainActor @Sendable () -> Void = { [weak self] in
            guard let self, self.isBusy, command == "launch" else { return }
            self.operation = "Running"
            self.headline = "Skyrim is running"
            self.detail = "Your saves are stored in a separate folder."
        }
        Task { [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) {
                Self.runBridge(checkout: checkoutDirectory, command: command, game: game, saves: saves, onStarted: onStarted)
            }.value
            guard let self else { return }
            self.isBusy = false
            self.operation = ""
            if let response = outcome.response {
                self.headline = response.headline
                self.detail = response.detail
                // A game exit error does not invalidate an independently verified build.
                self.isReady = response.isReady
                self.canPrepare = response.canPrepare
                self.lastError = response.error
                if let path = response.logPath {
                    self.logURL = URL(fileURLWithPath: path)
                    self.preferences.set(path, forKey: self.logKey)
                }
                if !response.success || outcome.exitCode != 0 {
                    self.lastError = response.error ?? "The operation could not finish. Open the log for details."
                }
            } else {
                self.headline = "Skyrim needs attention"
                self.detail = "The operation could not finish. Your original game files were preserved."
                self.isReady = false
                self.canPrepare = false
                self.lastError = "The launcher helper could not complete its check. Open the log for details."
                if let path = outcome.fallbackLogPath {
                    self.logURL = URL(fileURLWithPath: path)
                    self.preferences.set(path, forKey: self.logKey)
                }
            }
        }
    }

    private struct BridgeResponse: Decodable, Sendable {
        let success: Bool
        let headline: String
        let detail: String
        let isReady: Bool
        let canPrepare: Bool
        let error: String?
        let logPath: String?
    }

    private struct BridgeEvent: Decodable {
        let event: String
    }

    private struct BridgeOutcome: Sendable {
        let response: BridgeResponse?
        let exitCode: Int32
        let fallbackLogPath: String?
    }

    nonisolated private static func runBridge(checkout: URL, command: String, game: URL?, saves: URL,
                                             onStarted: @escaping @MainActor @Sendable () -> Void) -> BridgeOutcome {
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
        var response: BridgeResponse?
        var buffered = Data()
        let decoder = JSONDecoder()
        let fallbackURL = checkout.appendingPathComponent("macos/build/launcher/bridge-\(UUID().uuidString).log")
        try? FileManager.default.createDirectory(at: fallbackURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: fallbackURL.path, contents: nil)
        let fallbackLog = try? FileHandle(forWritingTo: fallbackURL)
        defer { try? fallbackLog?.close() }
        func consume(_ line: Data) {
            if let event = try? decoder.decode(BridgeEvent.self, from: line), event.event == "processStarted" {
                Task { @MainActor in onStarted() }
            } else if let parsed = try? decoder.decode(BridgeResponse.self, from: line) {
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
            return BridgeOutcome(response: response, exitCode: process.terminationStatus, fallbackLogPath: fallbackURL.path)
        } catch {
            try? fallbackLog?.write(contentsOf: Data(error.localizedDescription.utf8))
            return BridgeOutcome(response: nil, exitCode: -1, fallbackLogPath: fallbackURL.path)
        }
    }
}
