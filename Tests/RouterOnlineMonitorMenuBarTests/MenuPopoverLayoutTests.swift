import AppKit
import SwiftUI
import XCTest
@testable import RouterOnlineMonitorMenuBar

@MainActor
final class MenuPopoverLayoutTests: XCTestCase {
    func testExpandedPopoverKeepsQuitButtonVisible() {
        let defaults = UserDefaults.standard
        let savedValues = preserveDefaults([
            "configPanelIsExpanded",
            "configPanelUserPreferenceSet",
            "menuBarDisplayStyle",
            "routerUsername",
            "routerHost",
        ])
        defer { restoreDefaults(savedValues) }

        defaults.set(true, forKey: "configPanelIsExpanded")
        defaults.set(true, forKey: "configPanelUserPreferenceSet")
        defaults.set("minimalist", forKey: "menuBarDisplayStyle")
        defaults.set("", forKey: "routerUsername")
        defaults.set("192.0.2.1", forKey: "routerHost")

        let monitor = TrafficMonitor()
        var publishedSize = CGSize.zero
        var quitButtonFrame = CGRect.null
        let rootView = MenuPopoverView(
            monitor: monitor,
            onContentSizeChange: { size in
                publishedSize = size
            },
            onQuitButtonFrameChange: { frame in
                quitButtonFrame = frame
            }
        )

        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 540, height: 760),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hostingController
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }

        hostingController.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        hostingController.view.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(publishedSize.height, 0)
        window.setContentSize(publishedSize)
        hostingController.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        XCTAssertFalse(quitButtonFrame.isNull, "Expected the Quit button to report its layout frame.")
        XCTAssertGreaterThanOrEqual(quitButtonFrame.minX, 0)
        XCTAssertGreaterThanOrEqual(quitButtonFrame.minY, 0)
        XCTAssertLessThanOrEqual(
            quitButtonFrame.maxX,
            publishedSize.width + 1,
            "Expected Quit button x-frame \(quitButtonFrame) to fit inside popover width \(publishedSize.width)."
        )
        XCTAssertLessThanOrEqual(
            quitButtonFrame.maxY,
            publishedSize.height + 1,
            "Expected Quit button y-frame \(quitButtonFrame) to fit inside popover height \(publishedSize.height)."
        )
    }

    private func preserveDefaults(_ keys: [String]) -> [String: Any?] {
        let defaults = UserDefaults.standard
        return Dictionary(uniqueKeysWithValues: keys.map { ($0, defaults.object(forKey: $0)) })
    }

    private func restoreDefaults(_ values: [String: Any?]) {
        let defaults = UserDefaults.standard
        for (key, value) in values {
            if let value {
                defaults.set(value, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
    }

}
