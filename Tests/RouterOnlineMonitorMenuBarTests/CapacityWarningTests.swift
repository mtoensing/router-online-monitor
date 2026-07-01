import XCTest
@testable import RouterOnlineMonitorMenuBar

final class CapacityWarningTests: XCTestCase {
    func testNearCapacityStartsAtNinetyFivePercent() {
        XCTAssertFalse(CapacityWarning.isNearCapacity(94.9, capacityBitsPerSecond: 100))
        XCTAssertTrue(CapacityWarning.isNearCapacity(95, capacityBitsPerSecond: 100))
        XCTAssertTrue(CapacityWarning.isNearCapacity(99, capacityBitsPerSecond: 100))
    }

    func testInvalidCapacityDoesNotWarn() {
        XCTAssertFalse(CapacityWarning.isNearCapacity(100, capacityBitsPerSecond: 0))
        XCTAssertFalse(CapacityWarning.isNearCapacity(100, capacityBitsPerSecond: -1))
    }
}
