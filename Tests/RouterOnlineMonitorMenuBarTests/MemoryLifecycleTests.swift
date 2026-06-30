import AppKit
import SwiftUI
import XCTest
@testable import RouterOnlineMonitorMenuBar

@MainActor
final class MemoryLifecycleTests: XCTestCase {
    func testTemporaryTrafficMonitorIsReleased() {
        let savedValues = preserveDefaults([
            "routerUsername",
            "routerHost",
        ])
        defer { restoreDefaults(savedValues) }
        disableRouterConfiguration()

        weak var releasedMonitor: TrafficMonitor?
        autoreleasepool {
            var monitor: TrafficMonitor? = TrafficMonitor()
            releasedMonitor = monitor
            monitor?.persistSamples()
            monitor = nil
        }

        drainMainRunLoop()
        XCTAssertNil(releasedMonitor, "TrafficMonitor should not be retained by its timer, storage, or transient tasks after external references are released.")
    }

    func testRouterClientIsReleasedAfterInvalidation() {
        weak var releasedClient: RouterClient?
        autoreleasepool {
            var client: RouterClient? = RouterClient(configuration: .init(
                host: "192.0.2.1",
                username: "user",
                password: "password"
            ))
            releasedClient = client
            client?.invalidate()
            client = nil
        }

        drainMainRunLoop()
        XCTAssertNil(releasedClient, "RouterClient should release after invalidating its URLSession.")
    }

    func testPopoverHostingControllerReleasesMonitorAfterControllerRelease() {
        let savedValues = preserveDefaults([
            "configPanelIsExpanded",
            "configPanelUserPreferenceSet",
            "routerUsername",
            "routerHost",
        ])
        defer { restoreDefaults(savedValues) }
        disableRouterConfiguration()
        UserDefaults.standard.set(true, forKey: "configPanelIsExpanded")
        UserDefaults.standard.set(true, forKey: "configPanelUserPreferenceSet")

        weak var releasedMonitor: TrafficMonitor?
        weak var releasedHostingController: NSHostingController<MenuPopoverView>?
        autoreleasepool {
            var monitor: TrafficMonitor? = TrafficMonitor()
            releasedMonitor = monitor

            var hostingController: NSHostingController<MenuPopoverView>? = NSHostingController(
                rootView: MenuPopoverView(
                    monitor: monitor!,
                    onContentSizeChange: { _ in }
                )
            )
            releasedHostingController = hostingController
            _ = hostingController?.view
            hostingController = nil
            monitor = nil
        }

        drainMainRunLoop()
        XCTAssertNil(releasedHostingController, "MenuPopoverView hosting controller should release after external references are released.")
        XCTAssertNil(releasedMonitor, "MenuPopoverView should not retain TrafficMonitor after its hosting controller is released.")
    }

    private func disableRouterConfiguration() {
        UserDefaults.standard.set("", forKey: "routerUsername")
        UserDefaults.standard.set("192.0.2.1", forKey: "routerHost")
    }

    private func drainMainRunLoop() {
        for _ in 0..<5 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
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
