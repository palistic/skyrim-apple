import XCTest

final class InputLaunchPolicyTests: XCTestCase {
    func testNeitherDeviceAndSingleKeyboardOrMouseAreInsufficient() {
        XCTAssertFalse(InputLaunchPolicy.evaluate(.init()).canLaunch)
        XCTAssertFalse(InputLaunchPolicy.evaluate(.init(hasKeyboard: true)).canLaunch)
        XCTAssertFalse(InputLaunchPolicy.evaluate(.init(hasMouse: true)).canLaunch)
    }

    func testKeyboardAndMouseTogetherPermitPlayWithoutController() {
        let result = InputLaunchPolicy.evaluate(.init(hasKeyboard: true, hasMouse: true))
        XCTAssertTrue(result.canLaunch)
        XCTAssertFalse(result.connectedDualSense)
        XCTAssertEqual(result.activeInputName, "Keyboard + mouse")
    }

    func testOnlyPhysicalDualSensePermitsControllerPlay() {
        XCTAssertTrue(InputLaunchPolicy.evaluate(.init(controllers: [.init(isDualSense: true)])).canLaunch)
        XCTAssertFalse(InputLaunchPolicy.evaluate(.init(controllers: [.init(isDualSense: false)])).canLaunch)
        XCTAssertFalse(InputLaunchPolicy.evaluate(.init(controllers: [.init(isDualSense: true, isSnapshot: true)])).canLaunch)
        XCTAssertFalse(InputLaunchPolicy.evaluate(.init(controllers: [.init(isDualSense: true, isSpatial: true)])).canLaunch)
    }

    func testUnsupportedControllerDoesNotBlockAValidKeyboardAndMouse() {
        XCTAssertTrue(InputLaunchPolicy.evaluate(.init(controllers: [.init(isDualSense: false)],
            hasKeyboard: true, hasMouse: true)).canLaunch)
    }

    func testDisconnectClosesTheLaunchGate() {
        let connected = InputLaunchPolicy.Inventory(controllers: [.init(isDualSense: true)])
        XCTAssertTrue(InputLaunchPolicy.evaluate(connected).canLaunch)
        XCTAssertFalse(InputLaunchPolicy.evaluate(.init()).canLaunch)
        XCTAssertTrue(InputLaunchPolicy.evaluate(.init(hasKeyboard: true, hasMouse: true)).canLaunch)
        XCTAssertFalse(InputLaunchPolicy.evaluate(.init(hasKeyboard: true)).canLaunch)
    }

    func testSpatialControllerRemainsAPlannedFeature() {
        let decision = InputLaunchPolicy.evaluate(.init(controllers: [.init(isDualSense: false, isSpatial: true)]))
        XCTAssertFalse(decision.canLaunch)
        XCTAssertTrue(decision.detail.contains("planned"))
    }
}
