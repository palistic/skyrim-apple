import XCTest

final class ResumePolicyTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func assess(_ canLaunch: Bool = true, drops ages: [TimeInterval], at offset: TimeInterval = 0)
        -> ResumePolicy.Assessment {
        ResumePolicy.assess(canLaunch: canLaunch, disconnects: ages.map { now - $0 }, now: now + offset)
    }

    func testCannotResumeWithoutSupportedInput() {
        XCTAssertFalse(assess(false, drops: []).canResume)
        XCTAssertFalse(assess(false, drops: [600]).canResume)
        let unstable = assess(false, drops: [3, 2, 1])
        XCTAssertFalse(unstable.canResume)
        XCTAssertTrue(unstable.isUnstable)
    }

    func testSupportedInputWithNoDropsCanResume() {
        let result = assess(drops: [])
        XCTAssertTrue(result.canResume)
        XCTAssertFalse(result.isUnstable)
    }

    func testSettleIntervalBlocksRightAfterADisconnect() {
        for age in [0, 0.5, 1.999] {
            let result = assess(drops: [age])
            XCTAssertFalse(result.canResume, "\(age) s after a drop")
            XCTAssertFalse(result.isUnstable)
        }
        XCTAssertTrue(assess(drops: [ResumePolicy.settleInterval]).canResume)
        XCTAssertTrue(assess(drops: [60]).canResume)
    }

    func testThreeDropsWithinThirtySecondsNeedTenQuietSeconds() {
        let drops: [TimeInterval] = [20, 12, 4]
        let immediately = assess(drops: drops)
        XCTAssertFalse(immediately.canResume)
        XCTAssertTrue(immediately.isUnstable)
        XCTAssertTrue(immediately.reason.contains("10 seconds"), immediately.reason)

        // 9.9 s after the last drop: past the settle interval but not the unstable quiet period.
        let almost = assess(drops: drops, at: 5.9)
        XCTAssertFalse(almost.canResume)
        XCTAssertTrue(almost.isUnstable)

        let quiet = assess(drops: drops, at: 6)
        XCTAssertTrue(quiet.canResume)
        XCTAssertTrue(quiet.isUnstable, "Still flagged while the drops are inside the window")
    }

    func testDropsOutsideTheWindowDoNotCount() {
        let result = assess(drops: [45, 35, 3])
        XCTAssertFalse(result.isUnstable)
        XCTAssertTrue(result.canResume)
        XCTAssertEqual(ResumePolicy.recentDisconnects([now - 30, now - 30.001, now], now: now), 2)
    }

    func testTwoRecentDropsOnlyNeedTheSettleInterval() {
        let result = assess(drops: [10, 3])
        XCTAssertFalse(result.isUnstable)
        XCTAssertTrue(result.canResume)
    }

    func testFutureDatedDropKeepsResumeLocked() {
        XCTAssertFalse(assess(drops: [-5]).canResume, "A clock change never unlocks resume early")
    }
}
