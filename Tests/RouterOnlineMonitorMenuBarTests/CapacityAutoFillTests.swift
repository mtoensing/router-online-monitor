import XCTest
@testable import RouterOnlineMonitorMenuBar

final class CapacityAutoFillTests: XCTestCase {
    func testAppliesWhenMissingValueIsStillUnchanged() {
        XCTAssertTrue(CapacityAutoFill.shouldApply(startingValue: 0, currentValue: 0))
        XCTAssertTrue(CapacityAutoFill.shouldApply(startingValue: -1, currentValue: -1))
    }

    func testDoesNotApplyOverExistingManualValue() {
        XCTAssertFalse(CapacityAutoFill.shouldApply(startingValue: 100, currentValue: 100))
    }

    func testDoesNotApplyWhenUserEnteredManualValueDuringDetection() {
        XCTAssertFalse(CapacityAutoFill.shouldApply(startingValue: 0, currentValue: 100))
        XCTAssertFalse(CapacityAutoFill.shouldApply(startingValue: -1, currentValue: 20))
    }

    func testDoesNotApplyNonFiniteValues() {
        XCTAssertFalse(CapacityAutoFill.shouldApply(startingValue: .nan, currentValue: .nan))
        XCTAssertFalse(CapacityAutoFill.shouldApply(startingValue: 0, currentValue: .infinity))
    }
}
