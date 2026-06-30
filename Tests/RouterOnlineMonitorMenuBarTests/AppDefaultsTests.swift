import XCTest
@testable import RouterOnlineMonitorMenuBar

final class AppDefaultsTests: XCTestCase {
    func testNearCapacityHighlightDefaultsToEnabled() {
        let defaults = UserDefaults.standard
        let previousValue = defaults.object(forKey: AppDefaults.highlightNearCapacityMenuBarItemsKey)
        defaults.removeObject(forKey: AppDefaults.highlightNearCapacityMenuBarItemsKey)
        defer {
            if let previousValue {
                defaults.set(previousValue, forKey: AppDefaults.highlightNearCapacityMenuBarItemsKey)
            } else {
                defaults.removeObject(forKey: AppDefaults.highlightNearCapacityMenuBarItemsKey)
            }
        }

        XCTAssertTrue(AppDefaults.highlightNearCapacityMenuBarItems)
    }
}
