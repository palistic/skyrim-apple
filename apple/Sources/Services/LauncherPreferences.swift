import Combine
import Foundation

/// Device-local launcher preferences with an opt-in iCloud mirror for appearance only. Folder
/// bookmarks, save data and game options never enter the key-value store. Graphics options
/// the runtime does not read are intentionally absent: nothing here pretends to tune the game.
@MainActor
final class LauncherPreferences: ObservableObject {
    enum Accent: String, CaseIterable, Identifiable, Sendable {
        case gold, white
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    @Published var accent: Accent { didSet { save() } }
    @Published var reduceSmoke: Bool { didSet { save() } }
    @Published var cloudSyncEnabled: Bool { didSet { save() } }
    @Published var settingsSyncEnabled: Bool { didSet { save(); connectCloudPreferences() } }
    @Published private(set) var cloudPreferencesStatus = "Local preferences"
    @Published private(set) var lastSettingsSyncDate: Date?

    private let defaults: UserDefaults
    private let cloudConfigured: Bool
    private var applyingCloudValues = false
    private var observer: NSObjectProtocol?
    private let prefix = "SkyrimApple."
    /// The earlier Mac and Vision launchers stored their accent under this key; keep it.
    static let legacyAccentKey = "skyrim.launcher.accent"

    init(defaults: UserDefaults = .standard, cloudConfigured: Bool = CloudCapability.isConfiguredInBuild) {
        self.defaults = defaults
        self.cloudConfigured = cloudConfigured
        accent = Accent(rawValue: defaults.string(forKey: Self.legacyAccentKey) ?? "") ?? .gold
        reduceSmoke = defaults.bool(forKey: "SkyrimApple.reduceSmoke")
        cloudSyncEnabled = defaults.bool(forKey: "SkyrimApple.cloudSyncEnabled")
        settingsSyncEnabled = defaults.bool(forKey: "SkyrimApple.settingsSyncEnabled")
        lastSettingsSyncDate = defaults.object(forKey: "SkyrimApple.lastSettingsSyncDate") as? Date
        connectCloudPreferences()
    }

    func refreshCloudPreferences() { connectCloudPreferences() }

    /// Restores appearance defaults. Sync choices, game folders and saves are left alone.
    func resetAppearance() {
        accent = .gold
        reduceSmoke = false
    }

    private func save() {
        defaults.set(accent.rawValue, forKey: Self.legacyAccentKey)
        defaults.set(reduceSmoke, forKey: prefix + "reduceSmoke")
        defaults.set(cloudSyncEnabled, forKey: prefix + "cloudSyncEnabled")
        defaults.set(settingsSyncEnabled, forKey: prefix + "settingsSyncEnabled")
        guard !applyingCloudValues, canUseCloudPreferences else { return }
        let store = NSUbiquitousKeyValueStore.default
        store.set(accent.rawValue, forKey: prefix + "accent")
        store.set(reduceSmoke, forKey: prefix + "reduceSmoke")
        // iCloud schedules delivery; synchronize() is not a server-upload acknowledgement.
        store.synchronize()
        lastSettingsSyncDate = .now
        defaults.set(lastSettingsSyncDate, forKey: prefix + "lastSettingsSyncDate")
    }

    var isCloudConfigured: Bool { cloudConfigured }

    private var canUseCloudPreferences: Bool {
        settingsSyncEnabled && cloudConfigured && FileManager.default.ubiquityIdentityToken != nil
    }

    private func connectCloudPreferences() {
        guard canUseCloudPreferences else {
            if !settingsSyncEnabled { cloudPreferencesStatus = "Off · settings stay on this device" }
            else if !cloudConfigured { cloudPreferencesStatus = "Unavailable in this build" }
            else { cloudPreferencesStatus = "iCloud unavailable" }
            return
        }
        if observer == nil {
            observer = NotificationCenter.default.addObserver(
                forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
                object: NSUbiquitousKeyValueStore.default, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.applyCloudPreferences() }
            }
        }
        NSUbiquitousKeyValueStore.default.synchronize()
        applyCloudPreferences()
        cloudPreferencesStatus = "On · accent and smoke follow iCloud"
        save()
    }

    private func applyCloudPreferences() {
        guard canUseCloudPreferences else { return }
        applyingCloudValues = true
        defer { applyingCloudValues = false }
        let store = NSUbiquitousKeyValueStore.default
        if let value = store.string(forKey: prefix + "accent").flatMap(Accent.init(rawValue:)) {
            accent = value
        }
        if store.object(forKey: prefix + "reduceSmoke") != nil {
            reduceSmoke = store.bool(forKey: prefix + "reduceSmoke")
        }
    }
}
