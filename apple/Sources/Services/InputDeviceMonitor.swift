import Combine
import Foundation
import GameController

/// The same hardware requirement is used on every Apple platform. The inventory
/// is a value so the policy can be tested without synthesizing connected devices.
enum InputLaunchPolicy {
    struct Controller: Equatable, Sendable {
        var isDualSense: Bool
        var isSnapshot = false
        var isSpatial = false

        var isSupported: Bool { isDualSense && !isSnapshot && !isSpatial }
    }

    struct Inventory: Equatable, Sendable {
        var controllers: [Controller] = []
        var hasKeyboard = false
        var hasMouse = false
    }

    struct Decision: Equatable, Sendable {
        let canLaunch: Bool
        let activeInputName: String
        let status: String
        let detail: String
        let connectedDualSense: Bool
    }

    static func evaluate(_ inventory: Inventory) -> Decision {
        let dualSense = inventory.controllers.contains(where: \.isSupported)
        if dualSense {
            return Decision(canLaunch: true, activeInputName: "DualSense",
                status: "DualSense connected",
                detail: "Ready for controller play. Disconnecting the controller pauses gameplay.",
                connectedDualSense: true)
        }
        if inventory.hasKeyboard && inventory.hasMouse {
            return Decision(canLaunch: true, activeInputName: "Keyboard + mouse",
                status: "Keyboard + mouse connected",
                detail: "Ready for keyboard and mouse play. Disconnecting either pauses gameplay.",
                connectedDualSense: false)
        }
        let detail: String
        if inventory.hasKeyboard {
            detail = "Connect a mouse, or pair a DualSense controller, to play."
        } else if inventory.hasMouse {
            detail = "Connect a physical keyboard, or pair a DualSense controller, to play."
        } else if inventory.controllers.contains(where: \.isSpatial) {
            detail = "PS VR2 Sense support is planned. Connect a DualSense or a keyboard and mouse for windowed play."
        } else if !inventory.controllers.isEmpty {
            detail = "This controller is not supported. Connect a DualSense or both a keyboard and mouse."
        } else {
            detail = "Connect a DualSense controller or both a physical keyboard and mouse to play."
        }
        return Decision(canLaunch: false, activeInputName: "No supported input",
            status: "Connect your controls", detail: detail, connectedDualSense: false)
    }
}

/// A disconnect always pauses. Resuming needs an explicit request, a supported input that is
/// connected now, and a short settle period; repeated drops require a longer quiet period.
enum ResumePolicy {
    static let settleInterval: TimeInterval = 2
    static let unstableWindow: TimeInterval = 30
    static let unstableCount = 3
    static let unstableQuietInterval: TimeInterval = 10

    struct Assessment: Equatable, Sendable {
        let canResume: Bool
        let isUnstable: Bool
        let reason: String
    }

    static func recentDisconnects(_ dates: [Date], now: Date) -> Int {
        dates.filter { now.timeIntervalSince($0) <= unstableWindow }.count
    }

    static func assess(canLaunch: Bool, disconnects: [Date], now: Date) -> Assessment {
        let unstable = recentDisconnects(disconnects, now: now) >= unstableCount
        guard canLaunch else {
            return Assessment(canResume: false, isUnstable: unstable,
                reason: "Reconnect a DualSense, or both a keyboard and mouse, to resume.")
        }
        let quiet = disconnects.max().map { now.timeIntervalSince($0) } ?? .infinity
        if unstable && quiet < unstableQuietInterval {
            return Assessment(canResume: false, isUnstable: true,
                reason: "The connection dropped several times. Check the battery or cable; Resume unlocks after \(Int(unstableQuietInterval)) seconds without a drop.")
        }
        if quiet < settleInterval {
            return Assessment(canResume: false, isUnstable: unstable, reason: "Waiting for the connection to settle…")
        }
        return Assessment(canResume: true, isUnstable: unstable, reason: "Controls connected. Resume when you're ready.")
    }
}

/// Observes connections only; the game runtime owns button and pointer events.
/// There is no touch, virtual-controller or simulator bypass for the launch gate.
@MainActor
final class InputDeviceMonitor: ObservableObject {
    @Published private(set) var canLaunch = false
    @Published private(set) var status = "Connect your controls"
    @Published private(set) var detail = "Connect a DualSense or a keyboard and mouse to play."
    @Published private(set) var activeInputName = "No supported input"
    @Published private(set) var connectedDualSense = false
    @Published private(set) var hasKeyboard = false
    @Published private(set) var hasMouse = false

    /// Advances when a previously available input route is lost, even if another
    /// valid route remains. A running session should pause on this change and
    /// require an explicit Resume after the player has selected their controls.
    @Published private(set) var disconnectGeneration: UInt64 = 0
    /// Supported-device drops this launch, newest last, for rapid-reconnect monitoring.
    @Published private(set) var disconnectDates: [Date] = []

    private var subscriptions: Set<AnyCancellable> = []

    init() {
        #if os(macOS)
        // The game owns the key window while it runs; keep observing connection changes.
        GCController.shouldMonitorBackgroundEvents = true
        #endif
        for name: Notification.Name in [
            .GCControllerDidConnect, .GCControllerDidDisconnect,
            .GCKeyboardDidConnect, .GCKeyboardDidDisconnect,
            .GCMouseDidConnect, .GCMouseDidDisconnect
        ] {
            NotificationCenter.default.publisher(for: name)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] notification in
                    // receive(on:) schedules this callback on the main queue.
                    MainActor.assumeIsolated { self?.connectionChanged(notification) }
                }
                .store(in: &subscriptions)
        }
        refresh()
    }

    func refresh() {
        let inventory = InputLaunchPolicy.Inventory(
            controllers: GCController.controllers().map(Self.describe),
            hasKeyboard: GCKeyboard.coalesced != nil,
            hasMouse: !GCMouse.mice().isEmpty)
        let decision = InputLaunchPolicy.evaluate(inventory)
        if (connectedDualSense && !decision.connectedDualSense)
            || (hasKeyboard && !inventory.hasKeyboard)
            || (hasMouse && !inventory.hasMouse) {
            recordDisconnect()
        }
        connectedDualSense = decision.connectedDualSense
        hasKeyboard = inventory.hasKeyboard
        hasMouse = inventory.hasMouse
        activeInputName = decision.activeInputName
        status = decision.status
        detail = decision.detail
        canLaunch = decision.canLaunch
    }

    private func connectionChanged(_ notification: Notification) {
        let previousGeneration = disconnectGeneration
        refresh()
        let disconnectedSupportedDevice: Bool
        switch notification.name {
        case .GCControllerDidDisconnect:
            disconnectedSupportedDevice = (notification.object as? GCController)
                .map { Self.describe($0).isSupported } ?? false
        case .GCKeyboardDidDisconnect:
            disconnectedSupportedDevice = notification.object is GCKeyboard
        case .GCMouseDidDisconnect:
            disconnectedSupportedDevice = notification.object is GCMouse
        default:
            disconnectedSupportedDevice = false
        }
        // Preserve the disconnect event even if a rapid reconnect has restored
        // the inventory by the time this callback reaches the main queue.
        if disconnectedSupportedDevice && disconnectGeneration == previousGeneration {
            recordDisconnect()
        }
    }

    func resumeAssessment(now: Date = .now) -> ResumePolicy.Assessment {
        ResumePolicy.assess(canLaunch: canLaunch, disconnects: disconnectDates, now: now)
    }

    private func recordDisconnect() {
        disconnectGeneration &+= 1
        let now = Date.now
        disconnectDates = (disconnectDates + [now]).filter { now.timeIntervalSince($0) <= 120 }
    }

    private static func describe(_ controller: GCController) -> InputLaunchPolicy.Controller {
        var spatial = false
        if #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) {
            spatial = controller.productCategory == GCProductCategorySpatialController
        }
        return InputLaunchPolicy.Controller(
            isDualSense: controller.extendedGamepad is GCDualSenseGamepad,
            isSnapshot: controller.isSnapshot, isSpatial: spatial)
    }
}
