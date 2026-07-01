import XCTest
@testable import RouterOnlineMonitorMenuBar

final class MenuBarDisplayStyleTests: XCTestCase {
    func testPickerOrderStartsWithMinimalistThenRectangles() {
        XCTAssertEqual(
            MenuBarDisplayStyle.allCases.map(\.rawValue),
            ["minimalist", "rectangles", "rate", "stableText", "percentage"]
        )
    }

    func testRawValuesStayCompatibleWithStoredPreferences() {
        XCTAssertEqual(MenuBarDisplayStyle.minimalist.rawValue, "minimalist")
        XCTAssertEqual(MenuBarDisplayStyle.rectangles.rawValue, "rectangles")
        XCTAssertEqual(MenuBarDisplayStyle.rate.rawValue, "rate")
        XCTAssertEqual(MenuBarDisplayStyle.stableText.rawValue, "stableText")
        XCTAssertEqual(MenuBarDisplayStyle.percentage.rawValue, "percentage")
    }

    func testTrafficRateIsDefaultDisplayStyle() {
        XCTAssertEqual(MenuBarDisplayStyle.defaultStyle, .rate)
    }

    func testOnlyRateShowsDecimalPrecisionToggle() {
        let stylesWithDecimalPrecisionToggle = MenuBarDisplayStyle.allCases
            .filter(\.showsDecimalPrecisionToggle)

        XCTAssertEqual(stylesWithDecimalPrecisionToggle, [.rate])
    }

    func testOnlyMinimalistHidesMenuBarLabelPicker() {
        let stylesHidingMenuBarLabelPicker = MenuBarDisplayStyle.allCases
            .filter { !$0.showsMenuBarLabelPicker }

        XCTAssertEqual(stylesHidingMenuBarLabelPicker, [.minimalist])
    }
}
