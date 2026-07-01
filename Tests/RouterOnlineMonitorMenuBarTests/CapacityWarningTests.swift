import XCTest
@testable import RouterOnlineMonitorMenuBar

final class CapacityWarningTests: XCTestCase {
    private let visualConsumers = [
        "popover metrics",
        "menu bar minimalist icon",
        "menu bar usage bars",
        "menu bar rate text",
        "menu bar stable text",
        "menu bar percentage text",
    ]

    func testNearCapacityStartsAtNinetyFivePercent() {
        XCTAssertFalse(CapacityWarning.isNearCapacity(94.9, capacityBitsPerSecond: 100))
        XCTAssertTrue(CapacityWarning.isNearCapacity(95, capacityBitsPerSecond: 100))
        XCTAssertTrue(CapacityWarning.isNearCapacity(99, capacityBitsPerSecond: 100))
    }

    func testInvalidCapacityDoesNotWarn() {
        XCTAssertFalse(CapacityWarning.isNearCapacity(100, capacityBitsPerSecond: 0))
        XCTAssertFalse(CapacityWarning.isNearCapacity(100, capacityBitsPerSecond: -1))
    }

    func testSharedWarningStateCoversEveryVisualConsumer() {
        let sample = TrafficSample(
            recordedAt: Date(timeIntervalSince1970: 1),
            uploadBitsPerSecond: 96,
            downloadBitsPerSecond: 99
        )

        let state = CapacityWarning.state(
            for: sample,
            downCapacityBitsPerSecond: 100,
            upCapacityBitsPerSecond: 100,
            isEnabled: true
        )

        for visualConsumer in visualConsumers {
            XCTAssertEqual(
                state,
                CapacityWarningState(downloadNearCapacity: true, uploadNearCapacity: true),
                "\(visualConsumer) should receive the shared 95% warning state."
            )
        }
    }

    func testSharedWarningStateRespectsDisabledHighlighting() {
        let sample = TrafficSample(
            recordedAt: Date(timeIntervalSince1970: 1),
            uploadBitsPerSecond: 100,
            downloadBitsPerSecond: 100
        )

        let state = CapacityWarning.state(
            for: sample,
            downCapacityBitsPerSecond: 100,
            upCapacityBitsPerSecond: 100,
            isEnabled: false
        )

        XCTAssertEqual(state, .inactive)
    }

    func testSharedWarningStateTracksDirectionsIndependently() {
        let sample = TrafficSample(
            recordedAt: Date(timeIntervalSince1970: 1),
            uploadBitsPerSecond: 10,
            downloadBitsPerSecond: 99
        )

        let state = CapacityWarning.state(
            for: sample,
            downCapacityBitsPerSecond: 100,
            upCapacityBitsPerSecond: 100,
            isEnabled: true
        )

        XCTAssertEqual(
            state,
            CapacityWarningState(downloadNearCapacity: true, uploadNearCapacity: false)
        )
    }
}
