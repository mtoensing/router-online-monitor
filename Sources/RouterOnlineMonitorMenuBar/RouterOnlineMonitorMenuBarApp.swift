import AppKit
import Combine
import Foundation
import Security
import SwiftUI

enum L10n {
    static func string(_ key: String) -> String {
        NSLocalizedString(key, bundle: bundle, comment: "")
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: string(key), locale: .current, arguments: arguments)
    }

    private static let bundleName = "RouterOnlineMonitor_RouterOnlineMonitorMenuBar.bundle"

    private static var bundle: Bundle {
        if let resourceURL = Bundle.main.resourceURL?.appendingPathComponent(bundleName),
           let bundle = Bundle(url: resourceURL) {
            return bundle
        }
        if let bundle = Bundle(path: Bundle.main.bundleURL.appendingPathComponent(bundleName).path) {
            return bundle
        }
        return .module
    }
}

enum MenuBarDisplayStyle: String, CaseIterable, Identifiable {
    case minimalist
    case rectangles
    case rate
    case stableText
    case percentage

    static let defaultStyle: Self = .rate

    var id: String { rawValue }

    var pickerLocalizationKey: String {
        "picker.menuBarDisplay.\(rawValue)"
    }

    var helpLocalizationKey: String {
        "help.menuBarDisplay.\(rawValue)"
    }

    var showsDecimalPrecisionToggle: Bool {
        self == .rate
    }

    var showsMenuBarLabelPicker: Bool {
        self != .minimalist
    }
}

enum AppDefaults {
    static let highlightNearCapacityMenuBarItemsKey = "highlightNearCapacityMenuBarItems"

    static func register() {
        UserDefaults.standard.register(defaults: [
            highlightNearCapacityMenuBarItemsKey: true
        ])
    }

    static var highlightNearCapacityMenuBarItems: Bool {
        UserDefaults.standard.object(forKey: highlightNearCapacityMenuBarItemsKey) as? Bool ?? true
    }
}

enum CapacityWarning {
    static func isNearCapacity(_ bitsPerSecond: Double, capacityBitsPerSecond: Double) -> Bool {
        capacityBitsPerSecond > 0 && bitsPerSecond >= capacityBitsPerSecond * 0.95
    }

    static func state(
        for sample: TrafficSample,
        downCapacityBitsPerSecond: Double,
        upCapacityBitsPerSecond: Double,
        isEnabled: Bool
    ) -> CapacityWarningState {
        guard isEnabled else { return .inactive }
        return CapacityWarningState(
            downloadNearCapacity: isNearCapacity(
                sample.downloadBitsPerSecond,
                capacityBitsPerSecond: downCapacityBitsPerSecond
            ),
            uploadNearCapacity: isNearCapacity(
                sample.uploadBitsPerSecond,
                capacityBitsPerSecond: upCapacityBitsPerSecond
            )
        )
    }
}

struct CapacityWarningState: Equatable {
    let downloadNearCapacity: Bool
    let uploadNearCapacity: Bool

    static let inactive = CapacityWarningState(downloadNearCapacity: false, uploadNearCapacity: false)
}

@main
enum RouterOnlineMonitorMenuBarApp {
    @MainActor private static var menuBarController: MenuBarController?

    @MainActor static func main() {
        AppDefaults.register()
        let app = NSApplication.shared
        let controller = MenuBarController()
        menuBarController = controller
        app.delegate = controller
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class MenuBarController: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var samplesSubscription: AnyCancellable?
    private var preferencesSubscription: AnyCancellable?
    private var connectionSubscription: AnyCancellable?
    private var connectingSubscription: AnyCancellable?
    private var connectingAnimationTimer: Timer?
    private var connectingAnimationStep = 0
    private var currentPopoverContentSize = CGSize.zero
    private static let defaultMenuBarArrowsImage = menuBarArrowsImage()

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = Self.defaultMenuBarArrowsImage
            button.imagePosition = .imageOnly
            button.toolTip = L10n.string("menubar.tooltip.waitingForFirstSample")
        }
        statusItem = item

        Task { @MainActor in
            let monitor = TrafficMonitor.shared
            popover.behavior = .transient
            popover.delegate = self
            item.button?.target = self
            item.button?.action = #selector(togglePopover)
            samplesSubscription = monitor.$samples.sink { [weak self] _ in self?.updateMenuBar() }
            preferencesSubscription = monitor.$preferencesVersion.sink { [weak self] _ in self?.updateMenuBar() }
            connectionSubscription = monitor.$isConnected.sink { [weak self] _ in self?.updateMenuBar() }
            connectingSubscription = monitor.$isConnecting.sink { [weak self] _ in self?.updateMenuBar() }
            updateMenuBar()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        TrafficMonitor.shared.persistSamples()
    }

    func popoverDidClose(_ notification: Notification) {
        popover.contentViewController = nil
        currentPopoverContentSize = .zero
    }

    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(
            title: L10n.string("button.quit"),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: L10n.string("menu.edit"))
        editMenu.addItem(NSMenuItem(title: L10n.string("menu.undo"), action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: L10n.string("menu.redo"), action: Selector(("redo:")), keyEquivalent: "Z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redo)
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: L10n.string("menu.cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: L10n.string("menu.copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: L10n.string("menu.paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: L10n.string("menu.selectAll"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }

    private func updateMenuBar() {
        let monitor = TrafficMonitor.shared
        guard monitor.isConnected else {
            stopConnectingAnimation()
            setMenuBarIcon()
            statusItem?.button?.toolTip = monitor.status
            return
        }
        stopConnectingAnimation()
        guard let latestSample = monitor.samples.last else {
            setMenuBarIcon()
            statusItem?.button?.toolTip = monitor.status
            return
        }
        let sample = latestSample
        let downCapacity = UserDefaults.standard.double(forKey: "downstreamCapacityMbit") * 1_000_000
        let upCapacity = UserDefaults.standard.double(forKey: "upstreamCapacityMbit") * 1_000_000
        let warningState = CapacityWarning.state(
            for: sample,
            downCapacityBitsPerSecond: downCapacity,
            upCapacityBitsPerSecond: upCapacity,
            isEnabled: AppDefaults.highlightNearCapacityMenuBarItems
        )
        let labels = menuBarLabels()
        switch UserDefaults.standard.string(forKey: "menuBarDisplayStyle") ?? MenuBarDisplayStyle.defaultStyle.rawValue {
        case "minimalist":
            setMenuBarIcon(
                downloadNearCapacity: warningState.downloadNearCapacity,
                uploadNearCapacity: warningState.uploadNearCapacity
            )
        case "rate":
            setMenuBarRateTitle(
                sample: sample,
                downCapacity: downCapacity,
                upCapacity: upCapacity,
                labels: labels,
                warningState: warningState
            )
        case "stableText":
            setMenuBarStableTextTitle(
                sample: sample,
                downCapacity: downCapacity,
                upCapacity: upCapacity,
                labels: labels,
                warningState: warningState
            )
        case "percentage":
            setMenuBarPercentageTitle(
                sample: sample,
                downCapacity: downCapacity,
                upCapacity: upCapacity,
                labels: labels,
                warningState: warningState
            )
        default:
            setMenuBarUsageBars(
                sample: sample,
                downCapacity: downCapacity,
                upCapacity: upCapacity,
                labels: labels,
                warningState: warningState
            )
        }
        statusItem?.button?.toolTip = menuBarTooltip(sample: sample, downCapacity: downCapacity, upCapacity: upCapacity)
    }

    private func setMenuBarUsageBars(
        sample: TrafficSample,
        downCapacity: Double,
        upCapacity: Double,
        labels: (download: String, upload: String),
        warningState: CapacityWarningState
    ) {
        guard let button = statusItem?.button else { return }
        let isAlerting = warningState.downloadNearCapacity || warningState.uploadNearCapacity
        let image = Self.menuBarUsageImage(
            downloadFraction: usageFraction(sample.downloadBitsPerSecond, capacity: downCapacity),
            uploadFraction: usageFraction(sample.uploadBitsPerSecond, capacity: upCapacity),
            downloadLabel: labels.download,
            uploadLabel: labels.upload,
            downloadColor: warningState.downloadNearCapacity ? .systemRed : .labelColor,
            uploadColor: warningState.uploadNearCapacity ? .systemRed : .labelColor,
            isTemplate: !isAlerting
        )
        statusItem?.length = image.size.width + 8
        button.title = ""
        button.attributedTitle = NSAttributedString()
        button.image = image
        button.contentTintColor = nil
        button.imagePosition = .imageOnly
    }

    private func setMenuBarIcon(downloadNearCapacity: Bool = false, uploadNearCapacity: Bool = false) {
        guard let button = statusItem?.button else { return }
        let isAlerting = downloadNearCapacity || uploadNearCapacity
        statusItem?.length = NSStatusItem.squareLength
        button.title = ""
        button.attributedTitle = NSAttributedString()
        button.image = isAlerting
            ? Self.menuBarArrowsImage(
                downloadColor: downloadNearCapacity ? .systemRed : .labelColor,
                uploadColor: uploadNearCapacity ? .systemRed : .labelColor,
                isTemplate: false
            )
            : Self.defaultMenuBarArrowsImage
        button.contentTintColor = nil
        button.imagePosition = .imageOnly
    }

    private func menuBarLabels() -> (download: String, upload: String) {
        switch UserDefaults.standard.string(forKey: "menuBarLabelStyle") ?? "arrows" {
        case "arrows": return ("↓", "↑")
        case "short": return ("D", "U")
        case "words": return ("↓ \(L10n.string("traffic.download"))", "↑ \(L10n.string("traffic.upload"))")
        case "network": return ("Rx", "Tx")
        case "direction": return (L10n.string("traffic.in"), L10n.string("traffic.out"))
        default: return ("D:", "U:")
        }
    }

    private func setMenuBarRateTitle(
        sample: TrafficSample,
        downCapacity: Double,
        upCapacity: Double,
        labels: (download: String, upload: String),
        warningState: CapacityWarningState
    ) {
        setMenuBarDirectionalTitle(
            downloadLabel: labels.download,
            downloadValue: TrafficFormatting.compactMbit(sample.downloadBitsPerSecond),
            uploadLabel: labels.upload,
            uploadValue: TrafficFormatting.compactMbit(sample.uploadBitsPerSecond),
            font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
            downloadNearCapacity: warningState.downloadNearCapacity,
            uploadNearCapacity: warningState.uploadNearCapacity
        )
    }

    private func setMenuBarStableTextTitle(
        sample: TrafficSample,
        downCapacity: Double,
        upCapacity: Double,
        labels: (download: String, upload: String),
        warningState: CapacityWarningState
    ) {
        let downloadValue = TrafficFormatting.fixedWidthMbit(sample.downloadBitsPerSecond)
        let uploadValue = TrafficFormatting.fixedWidthMbit(sample.uploadBitsPerSecond)
        setMenuBarDirectionalTitle(
            downloadLabel: labels.download,
            downloadValue: downloadValue,
            uploadLabel: labels.upload,
            uploadValue: uploadValue,
            font: NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
            downloadNearCapacity: warningState.downloadNearCapacity,
            uploadNearCapacity: warningState.uploadNearCapacity
        )
    }

    private func setMenuBarPercentageTitle(
        sample: TrafficSample,
        downCapacity: Double,
        upCapacity: Double,
        labels: (download: String, upload: String),
        warningState: CapacityWarningState
    ) {
        setMenuBarDirectionalTitle(
            downloadLabel: labels.download,
            downloadValue: menuBarPercentage(sample.downloadBitsPerSecond, capacity: downCapacity),
            uploadLabel: labels.upload,
            uploadValue: menuBarPercentage(sample.uploadBitsPerSecond, capacity: upCapacity),
            font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
            downloadNearCapacity: warningState.downloadNearCapacity,
            uploadNearCapacity: warningState.uploadNearCapacity
        )
    }

    private func menuBarPercentage(_ bitsPerSecond: Double, capacity: Double) -> String {
        guard capacity > 0 else { return "--%" }
        return String(format: "%.0f%%", usageFraction(bitsPerSecond, capacity: capacity) * 100)
    }

    private func setMenuBarTitle(_ title: String) {
        setMenuBarPlainTitle(
            title,
            font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        )
    }

    private func setMenuBarDirectionalTitle(
        downloadLabel: String,
        downloadValue: String,
        uploadLabel: String,
        uploadValue: String,
        font: NSFont,
        downloadNearCapacity: Bool,
        uploadNearCapacity: Bool
    ) {
        let downloadPart = "\(downloadLabel) \(downloadValue)"
        let uploadPart = "\(uploadLabel) \(uploadValue)"
        let title = "\(downloadPart)  \(uploadPart)"
        guard downloadNearCapacity || uploadNearCapacity else {
            setMenuBarPlainTitle(title, font: font)
            return
        }

        let attributedTitle = NSMutableAttributedString(
            string: title,
            attributes: [
                .font: font,
                .foregroundColor: NSColor.labelColor,
            ]
        )
        if downloadNearCapacity {
            attributedTitle.addAttribute(
                .foregroundColor,
                value: NSColor.systemRed,
                range: NSRange(location: 0, length: (downloadPart as NSString).length)
            )
        }
        if uploadNearCapacity {
            attributedTitle.addAttribute(
                .foregroundColor,
                value: NSColor.systemRed,
                range: NSRange(
                    location: (downloadPart as NSString).length + 2,
                    length: (uploadPart as NSString).length
                )
            )
        }
        setMenuBarAttributedTitle(attributedTitle)
    }

    private func setMenuBarPlainTitle(_ title: String, font: NSFont) {
        guard let button = statusItem?.button else { return }
        statusItem?.length = NSStatusItem.variableLength
        button.image = nil
        button.contentTintColor = nil
        button.imagePosition = .noImage
        button.attributedTitle = NSAttributedString()
        button.font = font
        button.title = title
    }

    private func setMenuBarAttributedTitle(_ title: NSAttributedString) {
        guard let button = statusItem?.button else { return }
        statusItem?.length = NSStatusItem.variableLength
        button.title = ""
        button.image = nil
        button.contentTintColor = nil
        button.imagePosition = .noImage
        button.attributedTitle = title
    }

    private static func menuBarArrowsImage(
        downloadColor: NSColor = .black,
        uploadColor: NSColor = .black,
        isTemplate: Bool = true
    ) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            let strokeWidth: CGFloat = 2.2

            let down = NSBezierPath()
            down.lineWidth = strokeWidth
            down.lineCapStyle = .round
            down.lineJoinStyle = .round
            down.move(to: NSPoint(x: 6, y: 14.5))
            down.line(to: NSPoint(x: 6, y: 3.5))
            down.move(to: NSPoint(x: 2.5, y: 7))
            down.line(to: NSPoint(x: 6, y: 3.5))
            down.line(to: NSPoint(x: 9.5, y: 7))
            downloadColor.setStroke()
            down.stroke()

            let up = NSBezierPath()
            up.lineWidth = strokeWidth
            up.lineCapStyle = .round
            up.lineJoinStyle = .round
            up.move(to: NSPoint(x: 12, y: 3.5))
            up.line(to: NSPoint(x: 12, y: 14.5))
            up.move(to: NSPoint(x: 8.5, y: 11))
            up.line(to: NSPoint(x: 12, y: 14.5))
            up.line(to: NSPoint(x: 15.5, y: 11))
            uploadColor.setStroke()
            up.stroke()

            return true
        }
        image.isTemplate = isTemplate
        return image
    }

    private static func menuBarUsageImage(
        downloadFraction: Double,
        uploadFraction: Double,
        downloadLabel: String,
        uploadLabel: String,
        downloadColor: NSColor = .black,
        uploadColor: NSColor = .black,
        isTemplate: Bool = true
    ) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let measuringAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
        ]
        let labelGap: CGFloat = 2
        let groupGap: CGFloat = 5
        let barSize = NSSize(width: 5.5, height: 11.5)
        let imageHeight: CGFloat = 18
        let downloadSize = (downloadLabel as NSString).size(withAttributes: measuringAttributes)
        let uploadSize = (uploadLabel as NSString).size(withAttributes: measuringAttributes)
        let imageWidth = ceil(downloadSize.width + labelGap + barSize.width + groupGap + uploadSize.width + labelGap + barSize.width)

        let image = NSImage(size: NSSize(width: imageWidth, height: imageHeight), flipped: false) { _ in
            let baselineY = floor((imageHeight - max(downloadSize.height, uploadSize.height)) / 2)
            let barY = floor((imageHeight - barSize.height) / 2)
            var x: CGFloat = 0

            drawMenuBarUsageGroup(
                label: downloadLabel,
                labelSize: downloadSize,
                fraction: downloadFraction,
                x: &x,
                baselineY: baselineY,
                barY: barY,
                barSize: barSize,
                labelGap: labelGap,
                color: downloadColor,
                font: font
            )
            x += groupGap
            drawMenuBarUsageGroup(
                label: uploadLabel,
                labelSize: uploadSize,
                fraction: uploadFraction,
                x: &x,
                baselineY: baselineY,
                barY: barY,
                barSize: barSize,
                labelGap: labelGap,
                color: uploadColor,
                font: font
            )
            return true
        }
        image.isTemplate = isTemplate
        return image
    }

    private static func drawMenuBarUsageGroup(
        label: String,
        labelSize: NSSize,
        fraction: Double,
        x: inout CGFloat,
        baselineY: CGFloat,
        barY: CGFloat,
        barSize: NSSize,
        labelGap: CGFloat,
        color: NSColor,
        font: NSFont
    ) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
        ]
        color.set()
        (label as NSString).draw(at: NSPoint(x: x, y: baselineY), withAttributes: attributes)
        x += labelSize.width + labelGap

        let stroke = NSBezierPath(rect: NSRect(x: x, y: barY, width: barSize.width, height: barSize.height))
        stroke.lineWidth = 1
        stroke.stroke()

        let inset: CGFloat = 1.4
        let fillHeight = max(0, (barSize.height - inset * 2) * CGFloat(min(max(fraction, 0), 1)))
        if fillHeight > 0 {
            let visibleFillHeight = max(fillHeight, 1)
            NSBezierPath(rect: NSRect(
                x: x + inset,
                y: barY + inset,
                width: barSize.width - inset * 2,
                height: min(visibleFillHeight, barSize.height - inset * 2)
            )).fill()
        }

        x += barSize.width
    }

    private func startConnectingAnimation() {
        guard connectingAnimationTimer == nil else { return }
        updateConnectingTitle()
        connectingAnimationTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.connectingAnimationStep = (self.connectingAnimationStep + 1) % 4
                self.updateConnectingTitle()
            }
        }
    }

    private func stopConnectingAnimation() {
        connectingAnimationTimer?.invalidate()
        connectingAnimationTimer = nil
        connectingAnimationStep = 0
    }

    private func updateConnectingTitle() {
        setMenuBarTitle(L10n.string("status.connecting") + String(repeating: ".", count: connectingAnimationStep))
    }

    private func usageFraction(_ bitsPerSecond: Double, capacity: Double) -> Double {
        guard capacity.isFinite, capacity > 0, bitsPerSecond.isFinite else { return 0 }
        return min(max(bitsPerSecond / capacity, 0), 1)
    }

    private func isNearCapacity(_ bitsPerSecond: Double, capacity: Double) -> Bool {
        CapacityWarning.isNearCapacity(bitsPerSecond, capacityBitsPerSecond: capacity)
    }

    private func menuBarTooltip(sample: TrafficSample, downCapacity: Double, upCapacity: Double) -> String {
        let download = menuBarTooltipLine(
            label: L10n.string("traffic.download"),
            bitsPerSecond: sample.downloadBitsPerSecond,
            capacity: downCapacity
        )
        let upload = menuBarTooltipLine(
            label: L10n.string("traffic.upload"),
            bitsPerSecond: sample.uploadBitsPerSecond,
            capacity: upCapacity
        )
        return "\(download)\n\(upload)"
    }

    private func menuBarTooltipLine(label: String, bitsPerSecond: Double, capacity: Double) -> String {
        guard capacity > 0 else {
            return "\(label): \(TrafficFormatting.compactMbit(bitsPerSecond))"
        }
        return "\(label): \(TrafficFormatting.compactMbit(bitsPerSecond)) (\(String(format: "%.0f%%", usageFraction(bitsPerSecond, capacity: capacity) * 100)))"
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            ensurePopoverContent()
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            Task { @MainActor [weak self, weak button] in
                guard let self, let button else { return }
                self.constrainPopover(to: button)
            }
        }
    }

    private func ensurePopoverContent() {
        guard popover.contentViewController == nil else { return }
        let monitor = TrafficMonitor.shared
        popover.contentViewController = NSHostingController(
            rootView: MenuPopoverView(monitor: monitor) { [weak self] size in
                self?.updatePopoverContentSize(size)
            }
        )
    }

    private func constrainPopover(to button: NSStatusBarButton) {
        guard let window = popover.contentViewController?.view.window,
              let screen = button.window?.screen ?? NSScreen.main else { return }
        let visibleFrame = screen.visibleFrame
        let margin: CGFloat = 8
        var frame = window.frame
        let minimumX = visibleFrame.minX + margin
        let maximumX = max(minimumX, visibleFrame.maxX - frame.width - margin)
        frame.origin.x = min(max(frame.origin.x, minimumX), maximumX)
        window.setFrame(frame, display: true)
    }

    private func updatePopoverContentSize(_ contentSize: CGSize) {
        guard contentSize.width > 0, contentSize.height > 0,
              abs(contentSize.width - currentPopoverContentSize.width) > 0.5 ||
              abs(contentSize.height - currentPopoverContentSize.height) > 0.5 else { return }
        currentPopoverContentSize = contentSize
        popover.contentSize = contentSize
        if let button = statusItem?.button, popover.isShown {
            constrainPopover(to: button)
        }
    }
}

enum TrafficFormatting {
    static func compactMbit(_ bitsPerSecond: Double) -> String {
        let mbitPerSecond = bitsPerSecond / 1_000_000
        if UserDefaults.standard.bool(forKey: "showOneDecimalMbit") {
            if mbitPerSecond > 0 && mbitPerSecond < 0.05 {
                return L10n.string("traffic.lessThanPointOneMbit")
            }
            return L10n.format("traffic.mbit", mbitPerSecond.formatted(.number.precision(.fractionLength(1))))
        }
        if mbitPerSecond > 0 && mbitPerSecond < 0.5 {
            return L10n.string("traffic.lessThanOneMbit")
        }
        return L10n.format("traffic.mbit", mbitPerSecond.formatted(.number.precision(.fractionLength(0))))
    }

    static func fixedWidthMbit(_ bitsPerSecond: Double) -> String {
        guard bitsPerSecond.isFinite else { return "  0 Mbit" }
        let roundedMbit = min(max((bitsPerSecond / 1_000_000).rounded(), 0), 999)
        return String(format: "%3.0f Mbit", roundedMbit)
    }
}

private enum PopoverLayout {
    static let outerPadding: CGFloat = 16
    static let cardSpacing: CGFloat = 12
    static let cardPadding: CGFloat = 14
    static let formHorizontalPadding: CGFloat = 28
    static let actionBarBottomPadding: CGFloat = 8
    static let minimumSettingsHeight: CGFloat = 240
    static let nonSettingsHeightEstimate: CGFloat = 470
    static let maximumScreenMargin: CGFloat = 48
}

private struct ContentSizePreferenceKey: PreferenceKey {
    static let defaultValue = CGSize.zero

    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let nextValue = nextValue()
        value = CGSize(
            width: max(value.width, nextValue.width),
            height: max(value.height, nextValue.height)
        )
    }
}

private struct QuitButtonFramePreferenceKey: PreferenceKey {
    static let defaultValue = CGRect.null

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let nextValue = nextValue()
        if !nextValue.isNull {
            value = nextValue
        }
    }
}

struct MenuPopoverView: View {
    @ObservedObject var monitor: TrafficMonitor
    let onContentSizeChange: (CGSize) -> Void
    var onQuitButtonFrameChange: ((CGRect) -> Void)?
    @AppStorage("configPanelIsExpanded") private var isConfigPanelExpanded = true
    @AppStorage("configPanelUserPreferenceSet") private var configPanelUserPreferenceSet = false
    @State private var showsHiddenSettings = false
    @State private var versionClickCount = 0
    @State private var lastVersionClickAt: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: PopoverLayout.cardSpacing) {
            header
            monitoringCard
            configCard
            footer
            actionBar
        }
        .padding(PopoverLayout.outerPadding)
        .frame(width: 540)
        .fixedSize(horizontal: false, vertical: true)
        .coordinateSpace(name: "popover")
        .background(Color(nsColor: .windowBackgroundColor))
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: ContentSizePreferenceKey.self, value: proxy.size)
            }
        }
        .onAppear {
            applyDefaultConfigPanelState()
        }
        .onChange(of: monitor.isConnected) { _ in
            applyDefaultConfigPanelState()
        }
        .onPreferenceChange(ContentSizePreferenceKey.self) { size in
            publishContentSize(size)
        }
        .onPreferenceChange(QuitButtonFramePreferenceKey.self) { frame in
            guard !frame.isNull else { return }
            onQuitButtonFrameChange?(frame)
        }
    }

    private var maximumPopoverHeight: CGFloat {
        let visibleHeight = NSScreen.main?.visibleFrame.height ?? 760
        return max(420, visibleHeight - PopoverLayout.maximumScreenMargin)
    }

    private var maximumSettingsHeight: CGFloat {
        max(
            PopoverLayout.minimumSettingsHeight,
            maximumPopoverHeight - PopoverLayout.nonSettingsHeightEstimate - PopoverLayout.actionBarBottomPadding
        )
    }

    private func publishContentSize(_ measuredSize: CGSize) {
        guard measuredSize.width > 0, measuredSize.height > 0 else { return }
        onContentSizeChange(CGSize(
            width: 540,
            height: ceil(min(measuredSize.height, maximumPopoverHeight))
        ))
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "network")
                .font(.system(size: 15, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
            VStack(alignment: .leading, spacing: 1) {
                Text(L10n.string("app.name"))
                    .font(.headline)
                Text(headerStatusLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if monitor.isRefreshing {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 4)
    }

    private var monitoringCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            if recentSamples.isEmpty {
                VStack(spacing: 8) {
                    if monitor.isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: emptyStateSystemImage)
                            .font(.title2)
                            .symbolRenderingMode(.hierarchical)
                    }
                    Text(emptyStateTitle).font(.headline)
                    Text(emptyStateMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 150)
            } else {
                HStack(alignment: .center, spacing: 12) {
                    if let latestSample = monitor.samples.last {
                        let latest = latestSample
                        let downCapacity = UserDefaults.standard.double(forKey: "downstreamCapacityMbit") * 1_000_000
                        let upCapacity = UserDefaults.standard.double(forKey: "upstreamCapacityMbit") * 1_000_000
                        let warningState = CapacityWarning.state(
                            for: latest,
                            downCapacityBitsPerSecond: downCapacity,
                            upCapacityBitsPerSecond: upCapacity,
                            isEnabled: AppDefaults.highlightNearCapacityMenuBarItems
                        )
                        TrafficMetricView(
                            downloadValue: formatWithPercentage(latest.downloadBitsPerSecond, capacityKey: "downstreamCapacityMbit"),
                            uploadValue: formatWithPercentage(latest.uploadBitsPerSecond, capacityKey: "upstreamCapacityMbit"),
                            warningState: warningState
                        )
                        .frame(width: 112)
                    }
                    TrafficChartView(samples: recentSamples)
                        .frame(maxWidth: .infinity)
                }
                .frame(height: 170)
            }
        }
        .padding(PopoverLayout.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .popoverCard()
    }

    private var configCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    configPanelUserPreferenceSet = true
                    isConfigPanelExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isConfigPanelExpanded ? 90 : 0))
                        .frame(width: 12)
                    Image(systemName: "slider.horizontal.3")
                        .foregroundStyle(.secondary)
                    Text(L10n.string("section.config"))
                        .font(.headline)
                    Spacer()
                    Text(configSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
                .padding(.horizontal, PopoverLayout.cardPadding)
                .padding(.vertical, PopoverLayout.cardPadding)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.string("section.config"))
            .help(L10n.string("help.toggleConfig"))

            if isConfigPanelExpanded {
                Divider()
                    .padding(.horizontal, PopoverLayout.cardPadding)

                settingsPane
            }
        }
        .popoverCard()
    }

    @ViewBuilder
    private var settingsPane: some View {
        if showsHiddenSettings {
            ScrollView(.vertical) {
                settingsContent
            }
            .scrollIndicators(.automatic)
            .frame(height: maximumSettingsHeight)
        } else {
            settingsContent
        }
    }

    private var settingsContent: some View {
        SettingsView(
            monitor: monitor,
            showsHiddenSettings: showsHiddenSettings,
            onSaved: {
                configPanelUserPreferenceSet = false
                applyDefaultConfigPanelState()
            }
        )
        .padding(.horizontal, PopoverLayout.formHorizontalPadding)
        .padding(.top, PopoverLayout.cardPadding)
        .padding(.bottom, PopoverLayout.cardPadding)
    }

    private var footer: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(L10n.string("disclaimer.short"))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            Text(L10n.format("app.version", "1.0.68"))
                .lineLimit(1)
                .onTapGesture {
                    registerVersionClick()
                }
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 4)
    }

    private var actionBar: some View {
        HStack {
            Button {
                monitor.poll()
            } label: {
                Label(L10n.string("button.refreshNow"), systemImage: "arrow.clockwise")
            }
            .disabled(monitor.isRefreshing)
            Spacer()
            Button(L10n.string("button.quit")) { NSApp.terminate(nil) }
                .accessibilityIdentifier("quitButton")
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: QuitButtonFramePreferenceKey.self,
                            value: proxy.frame(in: .named("popover"))
                        )
                    }
                }
        }
        .padding(.horizontal, 4)
        .padding(.bottom, PopoverLayout.actionBarBottomPadding)
    }

    private func format(_ bitsPerSecond: Double) -> String {
        TrafficFormatting.compactMbit(bitsPerSecond)
    }

    private func formatWithPercentage(_ bitsPerSecond: Double, capacityKey: String) -> String {
        let capacity = UserDefaults.standard.double(forKey: capacityKey) * 1_000_000
        guard capacity > 0 else { return format(bitsPerSecond) }
        return "\(format(bitsPerSecond)) (\(String(format: "%.0f%%", bitsPerSecond / capacity * 100)))"
    }

    private var headerStatusLabel: String {
        if monitor.isRefreshing { return L10n.string("status.polling") }
        guard let lastUpdated = monitor.lastUpdated else { return monitor.status }
        return L10n.format("status.lastUpdated", lastUpdated.formatted(date: .omitted, time: .shortened))
    }

    private var emptyStateTitle: String {
        if isSetupRequired { return L10n.string("empty.setupRequired.title") }
        if monitor.isRefreshing { return L10n.string("empty.pollingRouter.title") }
        if monitor.lastUpdated != nil { return L10n.string("empty.waitingForSecondSample.title") }
        return L10n.string("empty.waitingForRouter.title")
    }

    private var emptyStateMessage: String {
        if isSetupRequired {
            return L10n.string("empty.setupRequired.message")
        }
        if monitor.isRefreshing {
            return L10n.string("empty.pollingRouter.message")
        }
        if monitor.lastUpdated != nil {
            return L10n.string("empty.waitingForSecondSample.message")
        }
        return monitor.status
    }

    private var emptyStateSystemImage: String {
        isSetupRequired ? "gearshape" : "chart.xyaxis.line"
    }

    private var isSetupRequired: Bool {
        monitor.status == L10n.string("status.enterCredentials")
    }

    private var configSummary: String {
        isSetupRequired ? L10n.string("config.summary.setupRequired") : L10n.string("config.summary.configured")
    }

    private var recentSamples: [TrafficSample] {
        let cutoff = Date().addingTimeInterval(-30 * 60)
        return TrafficSampleSeries.smoothedRates(
            in: Array(TrafficSampleSeries.recentSlice(from: monitor.samples, since: cutoff)),
            window: TrafficSamplingPolicy.rateSmoothingWindow,
            maximumGap: TrafficSamplingPolicy.maximumContinuousSampleGap
        )
    }

    private func applyDefaultConfigPanelState() {
        guard !configPanelUserPreferenceSet else { return }
        isConfigPanelExpanded = isSetupRequired || !monitor.isConnected
    }

    private func registerVersionClick() {
        let now = Date()
        if let lastVersionClickAt, now.timeIntervalSince(lastVersionClickAt) <= 1.5 {
            versionClickCount += 1
        } else {
            versionClickCount = 1
        }
        lastVersionClickAt = now

        if versionClickCount >= 5 {
            showsHiddenSettings = true
            versionClickCount = 0
        }
    }
}

private struct TrafficMetricView: View {
    let downloadValue: String
    let uploadValue: String
    let warningState: CapacityWarningState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            metric(
                title: L10n.string("traffic.download"),
                value: downloadValue,
                systemImage: "arrow.down",
                color: .blue,
                isNearCapacity: warningState.downloadNearCapacity
            )
            .frame(maxHeight: .infinity, alignment: .center)

            Divider()

            metric(
                title: L10n.string("traffic.upload"),
                value: uploadValue,
                systemImage: "arrow.up",
                color: Color(nsColor: .systemPink),
                isNearCapacity: warningState.uploadNearCapacity
            )
            .frame(maxHeight: .infinity, alignment: .center)
        }
        .frame(maxHeight: .infinity)
    }

    private func metric(title: String, value: String, systemImage: String, color: Color, isNearCapacity: Bool) -> some View {
        let warningColor = Color(nsColor: .systemRed)
        return VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.medium))
                .foregroundStyle(isNearCapacity ? warningColor : color)
            Text(value)
                .font(.headline.monospacedDigit())
                .foregroundStyle(isNearCapacity ? warningColor : Color.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct TrafficChartView: View {
    let samples: [TrafficSample]

    var body: some View {
        Canvas { context, size in
            let layout = TrafficChartLayout(size: size, samples: samples)
            drawGrid(in: &context, layout: layout)
            drawCapacityLines(in: &context, layout: layout)
            drawAxisLabels(in: &context, layout: layout)
            drawTrafficSeries(
                in: &context,
                layout: layout,
                direction: .download,
                value: \.downloadBitsPerSecond,
                color: .blue,
                fillOpacity: 0.08,
                style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
            )
            drawTrafficSeries(
                in: &context,
                layout: layout,
                direction: .upload,
                value: \.uploadBitsPerSecond,
                color: Color(nsColor: .systemPink),
                fillOpacity: 0.07,
                style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round, dash: [5, 3])
            )
        }
        .accessibilityLabel(L10n.string("chart.axis.time"))
    }

    private func drawGrid(in context: inout GraphicsContext, layout: TrafficChartLayout) {
        var horizontalGrid = Path()
        for tick in layout.yTicks {
            horizontalGrid.move(to: CGPoint(x: layout.plotFrame.minX, y: tick.positionY))
            horizontalGrid.addLine(to: CGPoint(x: layout.plotFrame.maxX, y: tick.positionY))
        }
        context.stroke(horizontalGrid, with: .color(Color(nsColor: .gridColor)), lineWidth: 0.6)

        var zeroAxis = Path()
        zeroAxis.move(to: CGPoint(x: layout.plotFrame.minX, y: layout.zeroAxisY))
        zeroAxis.addLine(to: CGPoint(x: layout.plotFrame.maxX, y: layout.zeroAxisY))
        context.stroke(zeroAxis, with: .color(Color(nsColor: .separatorColor)), lineWidth: 0.8)

        var verticalGrid = Path()
        for tick in layout.xTicks {
            verticalGrid.move(to: CGPoint(x: tick.positionX, y: layout.plotFrame.minY))
            verticalGrid.addLine(to: CGPoint(x: tick.positionX, y: layout.plotFrame.maxY))
        }
        context.stroke(
            verticalGrid,
            with: .color(Color(nsColor: .gridColor)),
            style: StrokeStyle(lineWidth: 0.6, dash: [4, 5])
        )
    }

    private func drawCapacityLines(in context: inout GraphicsContext, layout: TrafficChartLayout) {
        for line in layout.capacityLines {
            var path = Path()
            path.move(to: CGPoint(x: layout.plotFrame.minX, y: line.positionY))
            path.addLine(to: CGPoint(x: layout.plotFrame.maxX, y: line.positionY))
            context.stroke(
                path,
                with: .color(line.direction.color.opacity(0.45)),
                style: StrokeStyle(lineWidth: 1, dash: [3, 4])
            )
        }
    }

    private func drawAxisLabels(in context: inout GraphicsContext, layout: TrafficChartLayout) {
        context.draw(
            Text("Mbit/s")
                .font(.caption)
                .foregroundColor(.secondary),
            at: CGPoint(x: layout.plotFrame.maxX + 4, y: layout.plotFrame.minY - 12),
            anchor: .leading
        )

        for tick in layout.yTicks {
            context.draw(
                Text(tick.label)
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary),
                at: CGPoint(x: layout.plotFrame.maxX + 4, y: tick.positionY),
                anchor: .leading
            )
        }

        for tick in layout.xTicks {
            context.draw(
                Text(tick.label)
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary),
                at: CGPoint(x: tick.positionX, y: layout.plotFrame.maxY + 14),
                anchor: .center
            )
        }
    }

    private func drawTrafficSeries(
        in context: inout GraphicsContext,
        layout: TrafficChartLayout,
        direction: TrafficDirection,
        value: KeyPath<TrafficSample, Double>,
        color: Color,
        fillOpacity: Double,
        style: StrokeStyle
    ) {
        let chartPoints = samples.map { sample in
            TrafficChartInterpolation.ChartPoint(
                recordedAt: sample.recordedAt,
                point: layout.point(for: sample, direction: direction, value: sample[keyPath: value])
            )
        }

        for run in TrafficChartInterpolation.contiguousRuns(
            in: chartPoints,
            maximumGap: TrafficSamplingPolicy.maximumContinuousSampleGap
        ) where run.count > 1 {
            let points = run.map(\.point)
            let fillPath = TrafficChartInterpolation.areaPath(
                through: points,
                baselineY: layout.zeroAxisY
            )
            context.fill(fillPath, with: .color(color.opacity(fillOpacity)))

            let path = TrafficChartInterpolation.path(through: points)
            context.stroke(path, with: .color(color), style: style)
        }

        for point in TrafficChartInterpolation.gapMarkerPoints(
            in: chartPoints,
            maximumGap: TrafficSamplingPolicy.maximumContinuousSampleGap
        ) {
            let markerFrame = CGRect(
                x: point.x - 2,
                y: point.y - 2,
                width: 4,
                height: 4
            )
            context.fill(Path(ellipseIn: markerFrame), with: .color(color))
        }
    }
}

enum TrafficDirection {
    case download
    case upload

    var color: Color {
        switch self {
        case .download: return .blue
        case .upload: return Color(nsColor: .systemPink)
        }
    }
}

private struct TrafficChartLayout {
    struct AxisTick: Identifiable {
        let id: Int
        let label: String
        let positionY: CGFloat
    }

    struct TimeTick: Identifiable {
        let id: Int
        let label: String
        let positionX: CGFloat
    }

    struct CapacityLine: Identifiable {
        let id: Int
        let direction: TrafficDirection
        let positionY: CGFloat
    }

    let plotFrame: CGRect
    let zeroAxisY: CGFloat
    let yTicks: [AxisTick]
    let xTicks: [TimeTick]
    let capacityLines: [CapacityLine]

    private let startDate: Date
    private let endDate: Date
    private let downloadScaleMbit: Double
    private let uploadScaleMbit: Double

    init(size: CGSize, samples: [TrafficSample]) {
        let plotFrame = CGRect(
            x: 0,
            y: 18,
            width: max(1, size.width - 42),
            height: max(1, size.height - 42)
        )
        let startDate = samples.first?.recordedAt ?? Date()
        let endDate = samples.last?.recordedAt ?? startDate.addingTimeInterval(1)
        let capacities = TrafficChartScale.configuredCapacitiesMbit()
        let downloadScaleMbit = TrafficChartScale.upperBound(
            for: samples,
            value: \.downloadBitsPerSecond,
            configuredCapacityMbit: capacities.download
        )
        let uploadScaleMbit = TrafficChartScale.upperBound(
            for: samples,
            value: \.uploadBitsPerSecond,
            configuredCapacityMbit: capacities.upload
        )
        let zeroAxisY = plotFrame.midY

        let yTicks = Self.yTicks(
            plotFrame: plotFrame,
            zeroAxisY: zeroAxisY,
            downloadScaleMbit: downloadScaleMbit,
            uploadScaleMbit: uploadScaleMbit
        )
        let capacityLines = Self.capacityLines(
            plotFrame: plotFrame,
            zeroAxisY: zeroAxisY,
            downloadScaleMbit: downloadScaleMbit,
            uploadScaleMbit: uploadScaleMbit,
            capacities: capacities
        )

        let duration = max(1, endDate.timeIntervalSince(startDate))
        let xTicks = (1...5).map { index in
            let fraction = Double(index) / 6
            let date = startDate.addingTimeInterval(duration * fraction)
            return TimeTick(
                id: index,
                label: date.formatted(date: .omitted, time: .shortened),
                positionX: plotFrame.minX + plotFrame.width * CGFloat(fraction)
            )
        }

        self.plotFrame = plotFrame
        self.zeroAxisY = zeroAxisY
        self.startDate = startDate
        self.endDate = endDate
        self.downloadScaleMbit = downloadScaleMbit
        self.uploadScaleMbit = uploadScaleMbit
        self.yTicks = yTicks
        self.xTicks = xTicks
        self.capacityLines = capacityLines
    }

    func point(for sample: TrafficSample, direction: TrafficDirection, value bitsPerSecond: Double) -> CGPoint {
        let duration = max(1, endDate.timeIntervalSince(startDate))
        let timeFraction = sample.recordedAt.timeIntervalSince(startDate) / duration
        let scaleMbit = scale(for: direction)
        let mbit = max(0, min(bitsPerSecond / 1_000_000, scaleMbit))
        return CGPoint(
            x: plotFrame.minX + plotFrame.width * CGFloat(timeFraction),
            y: positionY(for: mbit, direction: direction)
        )
    }

    private func positionY(for valueMbit: Double, direction: TrafficDirection) -> CGFloat {
        let fraction = CGFloat(valueMbit / scale(for: direction))
        switch direction {
        case .download:
            return zeroAxisY - upperPlotHeight * fraction
        case .upload:
            return zeroAxisY + lowerPlotHeight * fraction
        }
    }

    private func scale(for direction: TrafficDirection) -> Double {
        switch direction {
        case .download: return downloadScaleMbit
        case .upload: return uploadScaleMbit
        }
    }

    private var upperPlotHeight: CGFloat {
        max(1, zeroAxisY - plotFrame.minY)
    }

    private var lowerPlotHeight: CGFloat {
        max(1, plotFrame.maxY - zeroAxisY)
    }

    private static func yTicks(
        plotFrame: CGRect,
        zeroAxisY: CGFloat,
        downloadScaleMbit: Double,
        uploadScaleMbit: Double
    ) -> [AxisTick] {
        let upperPlotHeight = max(1, zeroAxisY - plotFrame.minY)
        let lowerPlotHeight = max(1, plotFrame.maxY - zeroAxisY)
        let downloadValues = [downloadScaleMbit, downloadScaleMbit / 2]
        let uploadValues = [uploadScaleMbit / 2, uploadScaleMbit]

        var ticks = downloadValues.enumerated().map { index, value in
            AxisTick(
                id: index,
                label: TrafficChartScale.format(value),
                positionY: zeroAxisY - upperPlotHeight * CGFloat(value / downloadScaleMbit)
            )
        }
        ticks.append(AxisTick(id: 2, label: "0", positionY: zeroAxisY))
        ticks += uploadValues.enumerated().map { index, value in
            AxisTick(
                id: index + 3,
                label: TrafficChartScale.format(value),
                positionY: zeroAxisY + lowerPlotHeight * CGFloat(value / uploadScaleMbit)
            )
        }
        return ticks
    }

    private static func capacityLines(
        plotFrame: CGRect,
        zeroAxisY: CGFloat,
        downloadScaleMbit: Double,
        uploadScaleMbit: Double,
        capacities: (download: Double?, upload: Double?)
    ) -> [CapacityLine] {
        let upperPlotHeight = max(1, zeroAxisY - plotFrame.minY)
        let lowerPlotHeight = max(1, plotFrame.maxY - zeroAxisY)
        var lines: [CapacityLine] = []

        if let download = capacities.download, download > 0 {
            lines.append(CapacityLine(
                id: lines.count,
                direction: .download,
                positionY: zeroAxisY - upperPlotHeight * CGFloat(min(download / downloadScaleMbit, 1))
            ))
        }
        if let upload = capacities.upload, upload > 0 {
            lines.append(CapacityLine(
                id: lines.count,
                direction: .upload,
                positionY: zeroAxisY + lowerPlotHeight * CGFloat(min(upload / uploadScaleMbit, 1))
            ))
        }

        return lines
    }
}

enum TrafficChartInterpolation {
    struct ChartPoint {
        let recordedAt: Date
        let point: CGPoint
    }

    struct CurveSegment {
        let start: CGPoint
        let control1: CGPoint
        let control2: CGPoint
        let end: CGPoint
    }

    static func contiguousRuns(in points: [ChartPoint], maximumGap: TimeInterval) -> [[ChartPoint]] {
        guard let firstPoint = points.first else { return [] }

        var runs: [[ChartPoint]] = [[firstPoint]]
        for point in points.dropFirst() {
            guard let previousPoint = runs[runs.count - 1].last else { continue }
            if point.recordedAt.timeIntervalSince(previousPoint.recordedAt) >= maximumGap {
                runs.append([point])
            } else {
                runs[runs.count - 1].append(point)
            }
        }
        return runs
    }

    static func gapMarkerPoints(in points: [ChartPoint], maximumGap: TimeInterval) -> [CGPoint] {
        guard points.count > 1 else { return points.map(\.point) }

        var markerPoints: [CGPoint] = []
        for (previousPoint, point) in zip(points, points.dropFirst()) {
            guard point.recordedAt.timeIntervalSince(previousPoint.recordedAt) >= maximumGap else { continue }
            markerPoints.append(previousPoint.point)
            markerPoints.append(point.point)
        }
        return markerPoints
    }

    static func path(through points: [CGPoint]) -> Path {
        var path = Path()
        guard let firstPoint = points.first else { return path }

        path.move(to: firstPoint)
        for segment in curveSegments(through: points) {
            path.addCurve(to: segment.end, control1: segment.control1, control2: segment.control2)
        }
        return path
    }

    static func areaPath(through points: [CGPoint], baselineY: CGFloat) -> Path {
        var path = Path()
        guard let firstPoint = points.first, let lastPoint = points.last else { return path }

        path.move(to: CGPoint(x: firstPoint.x, y: baselineY))
        path.addLine(to: firstPoint)
        for segment in curveSegments(through: points) {
            path.addCurve(to: segment.end, control1: segment.control1, control2: segment.control2)
        }
        path.addLine(to: CGPoint(x: lastPoint.x, y: baselineY))
        path.closeSubpath()
        return path
    }

    static func curveSegments(through points: [CGPoint]) -> [CurveSegment] {
        guard points.count > 1 else { return [] }
        guard points.allSatisfy(\.hasFiniteCoordinates), points.haveStrictlyIncreasingXValues else {
            return straightSegments(through: points)
        }

        let intervals = zip(points, points.dropFirst()).map { nextPoint, point in
            point.x - nextPoint.x
        }
        let slopes = zip(zip(points, points.dropFirst()), intervals).map { pointPair, interval in
            let (point, nextPoint) = pointPair
            return (nextPoint.y - point.y) / interval
        }
        let tangents = monotoneTangents(intervals: intervals, slopes: slopes)

        return points.indices.dropLast().map { index in
            let nextIndex = points.index(after: index)
            let interval = intervals[index]
            return CurveSegment(
                start: points[index],
                control1: CGPoint(
                    x: points[index].x + interval / 3,
                    y: points[index].y + tangents[index] * interval / 3
                ),
                control2: CGPoint(
                    x: points[nextIndex].x - interval / 3,
                    y: points[nextIndex].y - tangents[nextIndex] * interval / 3
                ),
                end: points[nextIndex]
            )
        }
    }

    private static func monotoneTangents(intervals: [CGFloat], slopes: [CGFloat]) -> [CGFloat] {
        guard let firstSlope = slopes.first else { return [] }
        guard slopes.count > 1 else { return [firstSlope, firstSlope] }

        var tangents = Array(repeating: CGFloat.zero, count: slopes.count + 1)
        tangents[0] = endpointTangent(
            firstInterval: intervals[0],
            secondInterval: intervals[1],
            firstSlope: slopes[0],
            secondSlope: slopes[1]
        )

        for index in 1..<slopes.count {
            let previousSlope = slopes[index - 1]
            let nextSlope = slopes[index]
            guard previousSlope != 0, nextSlope != 0, previousSlope.sign == nextSlope.sign else {
                tangents[index] = 0
                continue
            }

            let previousInterval = intervals[index - 1]
            let nextInterval = intervals[index]
            let previousWeight = 2 * nextInterval + previousInterval
            let nextWeight = nextInterval + 2 * previousInterval
            tangents[index] = (previousWeight + nextWeight) / (previousWeight / previousSlope + nextWeight / nextSlope)
        }

        let lastIndex = slopes.count - 1
        tangents[slopes.count] = endpointTangent(
            firstInterval: intervals[lastIndex],
            secondInterval: intervals[lastIndex - 1],
            firstSlope: slopes[lastIndex],
            secondSlope: slopes[lastIndex - 1]
        )
        return tangents
    }

    private static func endpointTangent(
        firstInterval: CGFloat,
        secondInterval: CGFloat,
        firstSlope: CGFloat,
        secondSlope: CGFloat
    ) -> CGFloat {
        let tangent = ((2 * firstInterval + secondInterval) * firstSlope - firstInterval * secondSlope) / (firstInterval + secondInterval)
        if tangent == 0 || tangent.sign != firstSlope.sign {
            return 0
        }
        if firstSlope.sign != secondSlope.sign, abs(tangent) > abs(3 * firstSlope) {
            return 3 * firstSlope
        }
        return tangent
    }

    private static func straightSegments(through points: [CGPoint]) -> [CurveSegment] {
        points.indices.dropLast().map { index in
            let nextIndex = points.index(after: index)
            return CurveSegment(
                start: points[index],
                control1: points[index],
                control2: points[nextIndex],
                end: points[nextIndex]
            )
        }
    }
}

private extension Array where Element == CGPoint {
    var haveStrictlyIncreasingXValues: Bool {
        zip(self, dropFirst()).allSatisfy { point, nextPoint in
            nextPoint.x > point.x
        }
    }
}

private extension CGPoint {
    var hasFiniteCoordinates: Bool {
        x.isFinite && y.isFinite
    }
}

enum TrafficChartScale {
    static func upperBound(
        for samples: [TrafficSample],
        value: KeyPath<TrafficSample, Double>,
        configuredCapacityMbit: Double? = nil
    ) -> Double {
        let maximumMbit = samples.reduce(0) { maximum, sample in
            max(maximum, sample[keyPath: value] / 1_000_000)
        }
        let measuredUpperBound = niceUpperBound(maximumMbit)
        guard let configuredCapacityMbit,
              configuredCapacityMbit.isFinite,
              configuredCapacityMbit > 0 else {
            return measuredUpperBound
        }
        return max(measuredUpperBound, configuredCapacityMbit * 1.2)
    }

    static func upperBound(for samples: [TrafficSample], configuredCapacityMbit: Double? = nil) -> Double {
        let maximumMbit = samples.reduce(0) { maximum, sample in
            max(
                maximum,
                sample.downloadBitsPerSecond / 1_000_000,
                sample.uploadBitsPerSecond / 1_000_000
            )
        }
        let measuredUpperBound = niceUpperBound(maximumMbit)
        guard let configuredCapacityMbit,
              configuredCapacityMbit.isFinite,
              configuredCapacityMbit > 0 else {
            return measuredUpperBound
        }
        return max(measuredUpperBound, configuredCapacityMbit * 1.2)
    }

    static func configuredCapacitiesMbit(defaults: UserDefaults = .standard) -> (download: Double?, upload: Double?) {
        (
            download: configuredCapacityMbit(forKey: "downstreamCapacityMbit", defaults: defaults),
            upload: configuredCapacityMbit(forKey: "upstreamCapacityMbit", defaults: defaults)
        )
    }

    static func configuredCapacityUpperBoundMbit(defaults: UserDefaults = .standard) -> Double? {
        let capacities = configuredCapacitiesMbit(defaults: defaults)
        return [capacities.download, capacities.upload].compactMap { $0 }.max()
    }

    private static func configuredCapacityMbit(forKey key: String, defaults: UserDefaults) -> Double? {
        let value = defaults.double(forKey: key)
        guard value.isFinite, value > 0 else { return nil }
        return value
    }

    static func niceUpperBound(_ value: Double) -> Double {
        guard value.isFinite, value > 0 else { return 1 }
        let magnitude = pow(10, floor(log10(value)))
        let normalized = value / magnitude
        let niceNormalized: Double
        switch normalized {
        case ...1: niceNormalized = 1
        case ...2: niceNormalized = 2
        case ...3: niceNormalized = 3
        case ...5: niceNormalized = 5
        case ...6: niceNormalized = 6
        case ...9: niceNormalized = 9
        default: niceNormalized = 10
        }
        return niceNormalized * magnitude
    }

    static func format(_ value: Double) -> String {
        if value >= 10 || value.rounded() == value {
            return String(format: "%.0f", value)
        }
        return String(format: "%.1f", value)
    }
}

private struct PopoverCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.65), lineWidth: 1)
            }
    }
}

private extension View {
    func popoverCard() -> some View {
        modifier(PopoverCardModifier())
    }
}

struct SettingsView: View {
    private enum FormLayout {
        static let labelWidth: CGFloat = 202
        static let labelSpacing: CGFloat = 18

        static var controlLeadingIndent: CGFloat {
            labelWidth + labelSpacing
        }
    }

    private enum SettingsTab: String, Hashable {
        case router
        case lineSpeed
        case menuBar
    }

    @ObservedObject var monitor: TrafficMonitor
    let showsHiddenSettings: Bool
    let onSaved: () -> Void
    @AppStorage("routerHost") private var host = "192.168.178.1"
    @AppStorage("routerUsername") private var username = ""
    @AppStorage("menuBarDisplayStyle") private var menuBarDisplayStyle = MenuBarDisplayStyle.defaultStyle.rawValue
    @AppStorage("menuBarLabelStyle") private var menuBarLabelStyle = "arrows"
    @AppStorage("showOneDecimalMbit") private var showOneDecimalMbit = false
    @AppStorage("highlightNearCapacityMenuBarItems") private var highlightNearCapacityMenuBarItems = true
    @AppStorage("pollIntervalSeconds") private var pollIntervalSeconds = 5.0
    @AppStorage("downstreamCapacityMbit") private var downstreamCapacityMbit = 0.0
    @AppStorage("upstreamCapacityMbit") private var upstreamCapacityMbit = 0.0
    @State private var password = ""
    @State private var saved = false
    @State private var detectedLineRates: DSLLineRates?
    @State private var detectionError: String?
    @State private var isDiscovering = false
    @State private var discoveryStatus: String?
    @State private var showsCapacityHelp = false
    @State private var selectedSettingsTab = SettingsTab.router

    var body: some View {
        VStack(alignment: .center, spacing: 12) {
            settingsTabPicker
                .frame(width: 360)

            Form {
                switch selectedSettingsTab {
                case .router:
                    routerSettingsTab
                case .lineSpeed:
                    lineSpeedSettingsTab
                case .menuBar:
                    menuBarSettingsTab
                }
            }
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 2)
        .onAppear {
            password = Keychain.password() ?? ""
            detectLineRates()
        }
        .onChange(of: showOneDecimalMbit) { _ in
            monitor.refreshPresentation()
        }
        .onChange(of: highlightNearCapacityMenuBarItems) { _ in
            monitor.refreshPresentation()
        }
        .onChange(of: menuBarDisplayStyle) { _ in
            monitor.refreshPresentation()
        }
        .onChange(of: menuBarLabelStyle) { _ in
            monitor.refreshPresentation()
        }
        .onChange(of: downstreamCapacityMbit) { _ in
            monitor.refreshPresentation()
        }
        .onChange(of: upstreamCapacityMbit) { _ in
            monitor.refreshPresentation()
        }
        .onChange(of: pollIntervalSeconds) { _ in
            normalizePollingInterval()
            monitor.updatePollingInterval()
        }
    }

    private var settingsTabPicker: some View {
        Picker("", selection: $selectedSettingsTab) {
            Text(L10n.string("settingsTab.router")).tag(SettingsTab.router)
            Text(L10n.string("settingsTab.lineSpeed")).tag(SettingsTab.lineSpeed)
            Text(L10n.string("settingsTab.menuBar")).tag(SettingsTab.menuBar)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    @ViewBuilder
    private var routerSettingsTab: some View {
        Group {
            Section {
                HStack {
                    TextField(L10n.string("field.routerHost"), text: $host)
                    Button(L10n.string("button.findRouter")) { discoverRouter() }
                        .disabled(isDiscovering)
                }
                if let discoveryStatus {
                    Text(discoveryStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                TextField(L10n.string("field.username"), text: $username)
                SecureField(L10n.string("field.password"), text: $password)
            } header: {
                HStack(spacing: 5) {
                    Text(L10n.string("section.routerConnection"))
                    Circle()
                        .fill(connectionColor)
                        .frame(width: 8, height: 8)
                        .accessibilityLabel(connectionAccessibilityLabel)
                    Text("(\(connectionStatusLabel))")
                        .foregroundStyle(.secondary)
                }
            }

            formSeparator

            Section {
                HStack {
                    if saved {
                        Label(L10n.string("status.savedToKeychain"), systemImage: "checkmark.circle")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Button(L10n.string("button.saveAndConnect")) {
                        guard let configuration = routerConfiguration else { return }
                        if Keychain.save(password: configuration.password) {
                            saved = true
                            monitor.reconfigure(configuration: configuration)
                            detectLineRates(using: configuration)
                            onSaved()
                        }
                    }
                    .disabled(routerConfiguration == nil)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    @ViewBuilder
    private var lineSpeedSettingsTab: some View {
        Group {
            Section {
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        showsCapacityHelp.toggle()
                    }
                } label: {
                    Label(
                        showsCapacityHelp ? L10n.string("button.hideLineSpeedHelp") : L10n.string("button.showLineSpeedHelp"),
                        systemImage: showsCapacityHelp ? "info.circle.fill" : "info.circle"
                    )
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)

                if showsCapacityHelp {
                    Text(L10n.string("help.capacityLimits"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if needsCapacityValues {
                    Label(L10n.string("warning.capacityLimitsRequired"), systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(Color(nsColor: .systemOrange))
                        .fixedSize(horizontal: false, vertical: true)
                }
                TextField(L10n.string("field.downstreamCapacity"), value: $downstreamCapacityMbit, format: .number)
                TextField(L10n.string("field.upstreamCapacity"), value: $upstreamCapacityMbit, format: .number)
                if let rates = detectedLineRates {
                    LabeledContent(L10n.string("lineRate.detectedDownstream")) {
                        Text(L10n.format("lineRate.currentAndMax", format(rates.currentDownstreamMbit), format(rates.maximumDownstreamMbit)))
                    }
                    LabeledContent(L10n.string("lineRate.detectedUpstream")) {
                        Text(L10n.format("lineRate.currentAndMax", format(rates.currentUpstreamMbit), format(rates.maximumUpstreamMbit)))
                    }
                    Button(L10n.string("button.useRouterLineRate")) {
                        downstreamCapacityMbit = rates.currentDownstreamMbit
                        upstreamCapacityMbit = rates.currentUpstreamMbit
                    }
                } else if let detectionError {
                    Text(detectionError).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(L10n.string("lineRate.reading")).font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text(L10n.string("section.capacityLimits"))
            }
        }
    }

    @ViewBuilder
    private var menuBarSettingsTab: some View {
        Group {
            Section {
                menuBarFormRow(L10n.string("picker.menuBarDisplay")) {
                    Picker("", selection: $menuBarDisplayStyle) {
                        ForEach(MenuBarDisplayStyle.allCases) { style in
                            Text(L10n.string(style.pickerLocalizationKey)).tag(style.rawValue)
                        }
                    }
                    .labelsHidden()
                    .accessibilityLabel(L10n.string("picker.menuBarDisplay"))
                }
                if selectedMenuBarDisplayStyle.showsDecimalPrecisionToggle {
                    menuBarControlRow {
                        Toggle(L10n.string("toggle.showOneDecimalPlace"), isOn: $showOneDecimalMbit)
                    }
                    menuBarControlRow {
                        Text(L10n.string("help.showOneDecimalPlace"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if selectedMenuBarDisplayStyle.showsMenuBarLabelPicker {
                    menuBarFormRow(L10n.string("picker.menuBarLabels")) {
                        Picker("", selection: $menuBarLabelStyle) {
                            Text(L10n.string("picker.menuBarLabels.arrows")).tag("arrows")
                            Text(L10n.string("picker.menuBarLabels.short")).tag("short")
                            Text(L10n.string("picker.menuBarLabels.words")).tag("words")
                            Text(L10n.string("picker.menuBarLabels.network")).tag("network")
                            Text(L10n.string("picker.menuBarLabels.direction")).tag("direction")
                        }
                        .labelsHidden()
                        .accessibilityLabel(L10n.string("picker.menuBarLabels"))
                    }
                }
            } header: {
                Text(L10n.string("section.menuBar"))
                    .padding(.leading, FormLayout.controlLeadingIndent)
            } footer: {
                Text(menuBarDisplayHelp)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, FormLayout.controlLeadingIndent)
            }

            formSeparator

            Section {
                menuBarFormRow(L10n.string("section.capacityWarning")) {
                    Toggle(L10n.string("toggle.highlightNearCapacityMenuBarItems"), isOn: $highlightNearCapacityMenuBarItems)
                }
            } footer: {
                Text(L10n.string("help.highlightNearCapacityMenuBarItems"))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, FormLayout.controlLeadingIndent)
            }

            if showsHiddenSettings {
                formSeparator

                Section {
                    menuBarFormRow(L10n.string("field.pollingInterval")) {
                        TextField("", value: $pollIntervalSeconds, format: .number)
                            .labelsHidden()
                            .accessibilityLabel(L10n.string("field.pollingInterval"))
                    }
                } header: {
                    Text(L10n.string("section.hiddenSettings"))
                        .padding(.leading, FormLayout.controlLeadingIndent)
                } footer: {
                    Text(L10n.string("help.pollingInterval"))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, FormLayout.controlLeadingIndent)
                }
            }
        }
    }

    private func menuBarFormRow<Content: View>(
        _ label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: FormLayout.labelSpacing) {
            Text(label)
                .frame(width: FormLayout.labelWidth, alignment: .trailing)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func menuBarControlRow<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: FormLayout.labelSpacing) {
            Spacer()
                .frame(width: FormLayout.labelWidth)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var formSeparator: some View {
        Divider()
            .padding(.vertical, 5)
    }

    private var routerConfiguration: RouterClient.Configuration? {
        RouterClient.Configuration.validated(host: host, username: username, password: password)
    }

    private func detectLineRates() {
        guard let configuration = routerConfiguration else { return }
        detectLineRates(using: configuration)
    }

    private func detectLineRates(using configuration: RouterClient.Configuration) {
        let client = RouterClient(configuration: configuration)
        let startingDownstreamCapacityMbit = downstreamCapacityMbit
        let startingUpstreamCapacityMbit = upstreamCapacityMbit
        Task {
            do {
                let rates = try await client.lineRates()
                detectedLineRates = rates
                detectionError = nil
                if CapacityAutoFill.shouldApply(startingValue: startingDownstreamCapacityMbit, currentValue: downstreamCapacityMbit) {
                    downstreamCapacityMbit = rates.currentDownstreamMbit
                }
                if CapacityAutoFill.shouldApply(startingValue: startingUpstreamCapacityMbit, currentValue: upstreamCapacityMbit) {
                    upstreamCapacityMbit = rates.currentUpstreamMbit
                }
            } catch {
                detectionError = L10n.string("lineRate.error")
            }
        }
    }

    private func discoverRouter() {
        isDiscovering = true
        discoveryStatus = L10n.string("routerDiscovery.searching")
        Task {
            do {
                let discoveredHost = try await RouterDiscovery.host()
                host = discoveredHost
                discoveryStatus = L10n.format("routerDiscovery.found", discoveredHost)
            } catch {
                discoveryStatus = L10n.string("routerDiscovery.notFound")
            }
            isDiscovering = false
        }
    }

    private func format(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    private func normalizePollingInterval() {
        if pollIntervalSeconds < 1 {
            pollIntervalSeconds = 1
        }
    }

    private var selectedMenuBarDisplayStyle: MenuBarDisplayStyle {
        MenuBarDisplayStyle(rawValue: menuBarDisplayStyle) ?? .defaultStyle
    }

    private var menuBarDisplayHelp: String {
        L10n.string(selectedMenuBarDisplayStyle.helpLocalizationKey)
    }

    private var needsCapacityValues: Bool {
        downstreamCapacityMbit <= 0 || upstreamCapacityMbit <= 0
    }

    private var connectionColor: Color {
        if monitor.isConnected { return Color(nsColor: .systemGreen) }
        if monitor.isConnecting { return Color(nsColor: .systemOrange) }
        return Color(nsColor: .systemRed)
    }

    private var connectionAccessibilityLabel: String {
        monitor.isConnected ? L10n.string("connection.connected") : monitor.isConnecting ? L10n.string("connection.connecting") : L10n.string("connection.disconnected")
    }

    private var connectionStatusLabel: String {
        connectionAccessibilityLabel
    }
}

struct TrafficSample: Codable, Identifiable {
    var recordedAt: Date
    var uploadBitsPerSecond: Double
    var downloadBitsPerSecond: Double
    var id: Date { recordedAt }
}

enum TrafficHistoryPolicy {
    static let retentionDuration: TimeInterval = 12 * 3600
    static let maximumStoredSamples = 10_000
    static let storageSaveInterval: TimeInterval = 60
}

enum TrafficSamplingPolicy {
    static let rateSmoothingWindow: TimeInterval = 15
    static let maximumContinuousSampleGap: TimeInterval = 60
}

enum TrafficSampleSeries {
    static func recentSlice(from samples: [TrafficSample], since cutoff: Date) -> ArraySlice<TrafficSample> {
        guard let lastOlderSampleIndex = samples.lastIndex(where: { $0.recordedAt < cutoff }) else {
            return samples[...]
        }
        let firstRecentSampleIndex = samples.index(after: lastOlderSampleIndex)
        guard firstRecentSampleIndex < samples.endIndex else {
            return []
        }
        return samples[firstRecentSampleIndex...]
    }

    static func smoothedRates(
        in samples: [TrafficSample],
        window: TimeInterval,
        maximumGap: TimeInterval
    ) -> [TrafficSample] {
        guard samples.count > 1, window > 0 else { return samples }

        var smoothedSamples: [TrafficSample] = []
        var runStartIndex = samples.startIndex

        for index in samples.indices {
            if index > samples.startIndex {
                let previousIndex = samples.index(before: index)
                if samples[index].recordedAt.timeIntervalSince(samples[previousIndex].recordedAt) >= maximumGap {
                    runStartIndex = index
                }
            }

            let cutoff = samples[index].recordedAt.addingTimeInterval(-window)
            var windowStartIndex = runStartIndex
            while windowStartIndex < index, samples[windowStartIndex].recordedAt < cutoff {
                windowStartIndex = samples.index(after: windowStartIndex)
            }

            let windowSamples = samples[windowStartIndex...index]
            let divisor = Double(windowSamples.count)
            let upload = windowSamples.reduce(0) { $0 + $1.uploadBitsPerSecond } / divisor
            let download = windowSamples.reduce(0) { $0 + $1.downloadBitsPerSecond } / divisor
            smoothedSamples.append(TrafficSample(
                recordedAt: samples[index].recordedAt,
                uploadBitsPerSecond: upload,
                downloadBitsPerSecond: download
            ))
        }

        return smoothedSamples
    }
}

struct DSLLineRates {
    let currentDownstreamMbit: Double
    let currentUpstreamMbit: Double
    let maximumDownstreamMbit: Double
    let maximumUpstreamMbit: Double
}

enum CapacityAutoFill {
    static func shouldApply(startingValue: Double, currentValue: Double) -> Bool {
        startingValue.isFinite
        && currentValue.isFinite
        && startingValue <= 0
        && currentValue == startingValue
    }
}

struct TrafficCounterObservation {
    let recordedAt: Date
    let sent: UInt64
    let received: UInt64
}

enum TrafficRateEstimator {
    static func sample(from observations: [TrafficCounterObservation], to current: TrafficCounterObservation) -> TrafficSample? {
        guard let previous = observations.last else { return nil }
        let previousElapsed = current.recordedAt.timeIntervalSince(previous.recordedAt)
        guard previousElapsed > 0 else { return nil }
        guard previousElapsed < TrafficSamplingPolicy.maximumContinuousSampleGap else { return nil }

        let baseline = observations.last(where: {
            current.recordedAt.timeIntervalSince($0.recordedAt) >= TrafficSamplingPolicy.rateSmoothingWindow
        }) ?? observations.first ?? previous
        let elapsed = current.recordedAt.timeIntervalSince(baseline.recordedAt)
        guard elapsed > 0 else { return nil }

        return TrafficSample(
            recordedAt: current.recordedAt,
            uploadBitsPerSecond: Double(delta(from: baseline.sent, to: current.sent)) * 8 / elapsed,
            downloadBitsPerSecond: Double(delta(from: baseline.received, to: current.received)) * 8 / elapsed
        )
    }

    static func observations(afterAdding current: TrafficCounterObservation, to observations: [TrafficCounterObservation]) -> [TrafficCounterObservation] {
        if let previous = observations.last,
           current.recordedAt.timeIntervalSince(previous.recordedAt) >= TrafficSamplingPolicy.maximumContinuousSampleGap {
            return [current]
        }

        return (observations + [current]).filter {
            current.recordedAt.timeIntervalSince($0.recordedAt) <= TrafficSamplingPolicy.rateSmoothingWindow
        }
    }

    private static func delta(from old: UInt64, to new: UInt64) -> UInt64 {
        new >= old ? new - old : new + (1 << 32) - old
    }
}

@MainActor
final class TrafficMonitor: ObservableObject {
    static let shared = TrafficMonitor()
    @Published private(set) var samples: [TrafficSample] = []
    @Published private(set) var status = L10n.string("status.enterCredentials")
    @Published private(set) var preferencesVersion = 0
    @Published private(set) var isConnected = false
    @Published private(set) var isConnecting = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastUpdated: Date?

    private let storage = SampleStorage()
    private var counterObservations: [TrafficCounterObservation] = []
    private var timer: Timer?
    private var pollInFlight = false
    private var consecutivePollFailures = 0
    private var client: RouterClient?
    private var configuration: RouterClient.Configuration?
    private var lastStorageSaveAt: Date?
    private var hasUnsavedSamples = false

    init() {
        samples = storage.load()
        lastUpdated = samples.last?.recordedAt
        configuration = RouterClient.Configuration.fromPreferences()
        scheduleTimer()
        poll()
        prepopulateLineCapacities()
    }

    deinit {
        timer?.invalidate()
        client?.invalidate()
    }

    func reconfigure(configuration: RouterClient.Configuration? = nil) {
        client?.invalidate()
        client = nil
        self.configuration = configuration ?? RouterClient.Configuration.fromPreferences()
        counterObservations = []
        preferencesVersion += 1
        poll()
        prepopulateLineCapacities()
    }

    func refreshPresentation() {
        preferencesVersion += 1
    }

    func updatePollingInterval() {
        scheduleTimer()
    }

    func persistSamples() {
        saveSamplesIfNeeded(now: Date(), force: true)
    }

    func prepopulateLineCapacities() {
        let defaults = UserDefaults.standard
        let startingDownstreamCapacityMbit = defaults.double(forKey: "downstreamCapacityMbit")
        let startingUpstreamCapacityMbit = defaults.double(forKey: "upstreamCapacityMbit")
        guard startingDownstreamCapacityMbit <= 0 || startingUpstreamCapacityMbit <= 0,
              let client = configuredClient() else { return }
        Task {
            do {
                let rates = try await client.lineRates()
                var didUpdateCapacity = false
                if CapacityAutoFill.shouldApply(
                    startingValue: startingDownstreamCapacityMbit,
                    currentValue: defaults.double(forKey: "downstreamCapacityMbit")
                ) {
                    defaults.set(rates.currentDownstreamMbit, forKey: "downstreamCapacityMbit")
                    didUpdateCapacity = true
                }
                if CapacityAutoFill.shouldApply(
                    startingValue: startingUpstreamCapacityMbit,
                    currentValue: defaults.double(forKey: "upstreamCapacityMbit")
                ) {
                    defaults.set(rates.currentUpstreamMbit, forKey: "upstreamCapacityMbit")
                    didUpdateCapacity = true
                }
                if didUpdateCapacity {
                    preferencesVersion += 1
                }
            } catch {
                NSLog("Could not prepopulate DSL line capacities: %@", error.localizedDescription)
            }
        }
    }

    func poll() {
        guard !pollInFlight else { return }
        guard let client = configuredClient() else {
            status = L10n.string("status.enterCredentials")
            isConnecting = false
            isConnected = false
            isRefreshing = false
            return
        }
        pollInFlight = true
        isRefreshing = true
        if !isConnected { isConnecting = true }
        status = L10n.string("status.refreshing")
        Task {
            defer {
                pollInFlight = false
                isRefreshing = false
            }
            do {
                let counters = try await client.counters()
                let now = Date()
                let observation = TrafficCounterObservation(recordedAt: now, sent: counters.sent, received: counters.received)
                if let sample = TrafficRateEstimator.sample(from: counterObservations, to: observation) {
                    samples.append(sample)
                    pruneSamples(now: now)
                    hasUnsavedSamples = true
                    saveSamplesIfNeeded(now: now)
                } else {
                    status = L10n.string("status.connectedWaitingForSecondSample")
                }
                counterObservations = TrafficRateEstimator.observations(afterAdding: observation, to: counterObservations)
                consecutivePollFailures = 0
                isConnected = true
                isConnecting = false
                lastUpdated = now
                if !samples.isEmpty {
                    status = L10n.format("status.updated", now.formatted(date: .omitted, time: .shortened))
                }
            } catch {
                consecutivePollFailures += 1
                if consecutivePollFailures >= 3 {
                    isConnecting = false
                    isConnected = false
                    status = L10n.format("status.routerUnavailable", error.localizedDescription)
                } else {
                    isConnecting = true
                    status = L10n.string("status.retryingRouterConnection")
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(for: .seconds(2))
                        self?.poll()
                    }
                }
            }
        }
    }

    private func pruneSamples(now: Date) {
        samples.removeAll { $0.recordedAt < now.addingTimeInterval(-TrafficHistoryPolicy.retentionDuration) }
        if samples.count > TrafficHistoryPolicy.maximumStoredSamples {
            samples = Array(samples.suffix(TrafficHistoryPolicy.maximumStoredSamples))
        }
    }

    private func saveSamplesIfNeeded(now: Date, force: Bool = false) {
        guard hasUnsavedSamples else { return }
        if !force, let lastStorageSaveAt, now.timeIntervalSince(lastStorageSaveAt) < TrafficHistoryPolicy.storageSaveInterval {
            return
        }
        storage.save(samples)
        lastStorageSaveAt = now
        hasUnsavedSamples = false
    }

    private func scheduleTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.pollIntervalSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.poll()
            }
        }
    }

    private func configuredClient() -> RouterClient? {
        guard let configuration else {
            client?.invalidate()
            client = nil
            return nil
        }
        if let client, client.matches(configuration) {
            return client
        }
        client?.invalidate()
        let newClient = RouterClient(configuration: configuration)
        client = newClient
        return newClient
    }

    private static var pollIntervalSeconds: TimeInterval {
        let value = UserDefaults.standard.double(forKey: "pollIntervalSeconds")
        return value >= 1 ? value : 5
    }
}

final class RouterClient {
    struct Configuration: Equatable {
        let host: String
        let username: String
        let password: String

        init(host: String, username: String, password: String) {
            self.host = host
            self.username = username
            self.password = password
        }

        static func validated(host: String, username: String, password: String) -> Configuration? {
            let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
            let username = username.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !host.isEmpty, !username.isEmpty, !password.isEmpty else { return nil }
            return Configuration(host: host, username: username, password: password)
        }

        static func fromPreferences() -> Configuration? {
            let host = UserDefaults.standard.string(forKey: "routerHost")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let username = UserDefaults.standard.string(forKey: "routerUsername")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard let password = Keychain.password() else { return nil }
            return validated(host: host, username: username, password: password)
        }
    }

    private let configuration: Configuration
    private let session: URLSession
    private let delegate: DigestDelegate
    private static let service = "urn:dslforum-org:service:WANCommonInterfaceConfig:1"
    private static let dslService = "urn:dslforum-org:service:WANDSLInterfaceConfig:1"
    private static let wanCommonControlPath = "/upnp/control/wancommonifconfig1"
    private static let dslControlPath = "/upnp/control/wandslifconfig1"

    private var host: String { configuration.host }

    init(configuration: Configuration) {
        self.configuration = configuration
        delegate = DigestDelegate(username: configuration.username, password: configuration.password)
        let urlConfiguration = URLSessionConfiguration.ephemeral
        urlConfiguration.httpMaximumConnectionsPerHost = 2
        urlConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
        urlConfiguration.timeoutIntervalForRequest = 4
        urlConfiguration.timeoutIntervalForResource = 8
        session = URLSession(configuration: urlConfiguration, delegate: delegate, delegateQueue: nil)
    }

    deinit {
        session.invalidateAndCancel()
    }

    func matches(_ configuration: Configuration) -> Bool {
        self.configuration == configuration
    }

    func invalidate() {
        session.invalidateAndCancel()
    }

    func counters() async throws -> (sent: UInt64, received: UInt64) {
        do {
            return try await addonCounters()
        } catch {
            async let sent = counter(action: "GetTotalBytesSent", field: "NewTotalBytesSent")
            async let received = counter(action: "GetTotalBytesReceived", field: "NewTotalBytesReceived")
            return try await (sent, received)
        }
    }

    func lineRates() async throws -> DSLLineRates {
        let data = try await soapData(controlPath: Self.dslControlPath, service: Self.dslService, action: "GetInfo")
        let root = try XMLDocument(data: data, options: [])
        func rate(_ field: String) throws -> Double {
            guard let text = try root.nodes(forXPath: "//*[local-name() = '\(field)']").first?.stringValue, let kbitPerSecond = Double(text) else { throw RouterAPIError.invalidResponse }
            return kbitPerSecond / 1_000
        }
        return try DSLLineRates(
            currentDownstreamMbit: rate("NewDownstreamCurrRate"),
            currentUpstreamMbit: rate("NewUpstreamCurrRate"),
            maximumDownstreamMbit: rate("NewDownstreamMaxRate"),
            maximumUpstreamMbit: rate("NewUpstreamMaxRate")
        )
    }

    private func addonCounters() async throws -> (sent: UInt64, received: UInt64) {
        let data = try await soapData(controlPath: Self.wanCommonControlPath, service: Self.service, action: "GetAddonInfos")
        let root = try XMLDocument(data: data, options: [])
        let sent = try counterValue(root: root, preferredField: "NewX_AVM_DE_TotalBytesSent64", fallbackField: "NewTotalBytesSent")
        let received = try counterValue(root: root, preferredField: "NewX_AVM_DE_TotalBytesReceived64", fallbackField: "NewTotalBytesReceived")
        return (sent, received)
    }

    private func counter(action: String, field: String) async throws -> UInt64 {
        let data = try await soapData(controlPath: Self.wanCommonControlPath, service: Self.service, action: action)
        let root = try XMLDocument(data: data, options: [])
        return try counterValue(root: root, preferredField: field)
    }

    private func soapData(controlPath: String, service: String, action: String) async throws -> Data {
        guard let url = URL(string: "http://\(host):49000\(controlPath)") else { throw RouterAPIError.invalidHost }
        let xml = soapEnvelope(service: service, action: action)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data(xml.utf8)
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\"\(service)#\(action)\"", forHTTPHeaderField: "SOAPAction")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw RouterAPIError.requestFailed }
        return data
    }

    private func soapEnvelope(service: String, action: String) -> String {
        """
        <?xml version=\"1.0\" encoding=\"utf-8\"?>
        <s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\"><s:Body><u:\(action) xmlns:u=\"\(service)\"/></s:Body></s:Envelope>
        """
    }

    private func counterValue(root: XMLDocument, preferredField: String, fallbackField: String? = nil) throws -> UInt64 {
        if let value = try value(root: root, field: preferredField) {
            return value
        }
        if let fallbackField, let value = try value(root: root, field: fallbackField) {
            return value
        }
        throw RouterAPIError.invalidResponse
    }

    private func value(root: XMLDocument, field: String) throws -> UInt64? {
        guard let text = try root.nodes(forXPath: "//*[local-name() = '\(field)']").first?.stringValue else { return nil }
        return UInt64(text)
    }
}

final class DigestDelegate: NSObject, URLSessionTaskDelegate {
    private let credential: URLCredential

    init(username: String, password: String) {
        credential = URLCredential(user: username, password: password, persistence: .none)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodHTTPDigest {
            completionHandler(.useCredential, credential)
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

enum RouterAPIError: LocalizedError {
    case invalidHost, requestFailed, invalidResponse
    var errorDescription: String? {
        switch self {
        case .invalidHost: return L10n.string("error.invalidHost")
        case .requestFailed: return L10n.string("error.requestFailed")
        case .invalidResponse: return L10n.string("error.invalidResponse")
        }
    }
}

enum RouterDiscovery {
    private static let discoveryPath = "/tr64desc.xml"

    static func host() async throws -> String {
        let savedHost = UserDefaults.standard.string(forKey: "routerHost")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates = [savedHost, "192.168.178.1", "192.168.1.1", "192.168.0.1"]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .removingDuplicates()

        let foundHost: String? = await withTaskGroup(of: String?.self) { group -> String? in
            for candidate in candidates {
                group.addTask {
                    do {
                        try await verify(candidate)
                        return candidate
                    } catch {
                        return nil
                    }
                }
            }
            for await result in group {
                if let result {
                    group.cancelAll()
                    return result
                }
            }
            return nil
        }
        guard let foundHost else { throw RouterAPIError.requestFailed }
        return foundHost
    }

    private static func verify(_ host: String) async throws {
        guard let url = URL(string: "http://\(host):49000\(discoveryPath)") else {
            throw RouterAPIError.invalidHost
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2
        configuration.timeoutIntervalForResource = 3
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              let description = String(data: data, encoding: .utf8),
              description.localizedCaseInsensitiveContains("AVM") || description.localizedCaseInsensitiveContains("FRITZ") else {
            throw RouterAPIError.invalidResponse
        }
    }
}

private extension Array where Element: Hashable {
    func removingDuplicates() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

final class SampleStorage {
    private let url: URL
    private let now: () -> Date

    init(url: URL? = nil, now: @escaping () -> Date = Date.init) {
        if let url {
            self.url = url
        } else {
            let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("RouterOnlineMonitor", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            self.url = folder.appendingPathComponent("samples.json")
        }
        self.now = now
    }

    func load() -> [TrafficSample] {
        guard let data = try? Data(contentsOf: url), let samples = try? JSONDecoder().decode([TrafficSample].self, from: data) else { return [] }
        let retentionCutoff = now().addingTimeInterval(-TrafficHistoryPolicy.retentionDuration)
        let retainedSamples = samples.filter { $0.recordedAt > retentionCutoff }
        if retainedSamples.count > TrafficHistoryPolicy.maximumStoredSamples {
            return Array(retainedSamples.suffix(TrafficHistoryPolicy.maximumStoredSamples))
        }
        return retainedSamples
    }

    func save(_ samples: [TrafficSample]) {
        guard let data = try? JSONEncoder().encode(samples) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

enum Keychain {
    private static let service = "RouterOnlineMonitor"
    private static let account = "router-password"
    private static var cachedPassword: String?
    private static var hasCachedPassword = false

    static func password() -> String? {
        if hasCachedPassword {
            return cachedPassword
        }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account, kSecReturnData as String: true]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else {
            cachedPassword = nil
            hasCachedPassword = true
            return nil
        }
        cachedPassword = String(data: data, encoding: .utf8)
        hasCachedPassword = true
        return cachedPassword
    }

    @discardableResult
    static func save(password: String) -> Bool {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        let attributes = [kSecValueData as String: Data(password.utf8)]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess {
            cachedPassword = password
            hasCachedPassword = true
            return true
        }
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = Data(password.utf8)
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            if addStatus == errSecSuccess {
                cachedPassword = password
                hasCachedPassword = true
                return true
            }
        }
        return false
    }
}
