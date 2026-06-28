import Charts
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

@main
enum RouterOnlineMonitorMenuBarApp {
    @MainActor private static var menuBarController: MenuBarController?

    @MainActor static func main() {
        let app = NSApplication.shared
        let controller = MenuBarController()
        menuBarController = controller
        app.delegate = controller
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class MenuBarController: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var samplesSubscription: AnyCancellable?
    private var preferencesSubscription: AnyCancellable?
    private var connectionSubscription: AnyCancellable?
    private var connectingSubscription: AnyCancellable?
    private var connectingAnimationTimer: Timer?
    private var connectingAnimationStep = 0
    private var currentPopoverContentSize = CGSize.zero

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = Self.menuBarArrowsImage()
            button.imagePosition = .imageOnly
            button.toolTip = L10n.string("menubar.tooltip.waitingForFirstSample")
        }
        statusItem = item

        Task { @MainActor in
            let monitor = TrafficMonitor.shared
            popover.behavior = .transient
            popover.contentViewController = NSHostingController(
                rootView: MenuPopoverView(monitor: monitor) { [weak self] size in
                    self?.updatePopoverContentSize(size)
                }
            )
            item.button?.target = self
            item.button?.action = #selector(togglePopover)
            samplesSubscription = monitor.$samples.sink { [weak self] _ in self?.updateMenuBar() }
            preferencesSubscription = monitor.$preferencesVersion.sink { [weak self] _ in self?.updateMenuBar() }
            connectionSubscription = monitor.$isConnected.sink { [weak self] _ in self?.updateMenuBar() }
            connectingSubscription = monitor.$isConnecting.sink { [weak self] _ in self?.updateMenuBar() }
            updateMenuBar()
        }
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
        let sample = TrafficRateLimiter.cappedToConfiguredCapacities(latestSample)
        let downCapacity = UserDefaults.standard.double(forKey: "downstreamCapacityMbit") * 1_000_000
        let upCapacity = UserDefaults.standard.double(forKey: "upstreamCapacityMbit") * 1_000_000
        let labels = menuBarLabels()
        switch UserDefaults.standard.string(forKey: "menuBarDisplayStyle") ?? "rectangles" {
        case "minimalist":
            setMenuBarIcon(
                isAlerting: isAtCapacity(sample.downloadBitsPerSecond, capacity: downCapacity) ||
                    isAtCapacity(sample.uploadBitsPerSecond, capacity: upCapacity)
            )
        case "rate":
            setMenuBarRateTitle(
                sample: sample,
                downCapacity: downCapacity,
                upCapacity: upCapacity,
                labels: labels
            )
        case "stableText":
            setMenuBarStableTextTitle(
                sample: sample,
                downCapacity: downCapacity,
                upCapacity: upCapacity,
                labels: labels
            )
        case "percentage":
            setMenuBarPercentageTitle(
                sample: sample,
                downCapacity: downCapacity,
                upCapacity: upCapacity,
                labels: labels
            )
        default:
            setMenuBarUsageBars(
                sample: sample,
                downCapacity: downCapacity,
                upCapacity: upCapacity,
                labels: labels
            )
        }
        statusItem?.button?.toolTip = menuBarTooltip(sample: sample, downCapacity: downCapacity, upCapacity: upCapacity)
    }

    private func setMenuBarUsageBars(sample: TrafficSample, downCapacity: Double, upCapacity: Double, labels: (download: String, upload: String)) {
        guard let button = statusItem?.button else { return }
        let downloadNearCapacity = isNearCapacity(sample.downloadBitsPerSecond, capacity: downCapacity)
        let uploadNearCapacity = isNearCapacity(sample.uploadBitsPerSecond, capacity: upCapacity)
        let image = Self.menuBarUsageImage(
            downloadFraction: usageFraction(sample.downloadBitsPerSecond, capacity: downCapacity),
            uploadFraction: usageFraction(sample.uploadBitsPerSecond, capacity: upCapacity),
            downloadLabel: labels.download,
            uploadLabel: labels.upload
        )
        statusItem?.length = image.size.width + 8
        button.title = ""
        button.attributedTitle = NSAttributedString()
        button.image = image
        button.contentTintColor = downloadNearCapacity || uploadNearCapacity ? .systemRed : nil
        button.imagePosition = .imageOnly
    }

    private func setMenuBarIcon(isAlerting: Bool = false) {
        guard let button = statusItem?.button else { return }
        statusItem?.length = NSStatusItem.squareLength
        button.title = ""
        button.attributedTitle = NSAttributedString()
        button.image = Self.menuBarArrowsImage()
        button.contentTintColor = isAlerting ? .systemRed : nil
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
        labels: (download: String, upload: String)
    ) {
        setMenuBarDirectionalTitle(
            downloadLabel: labels.download,
            downloadValue: TrafficFormatting.compactMbit(sample.downloadBitsPerSecond),
            uploadLabel: labels.upload,
            uploadValue: TrafficFormatting.compactMbit(sample.uploadBitsPerSecond),
            font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
            downloadNearCapacity: isNearCapacity(sample.downloadBitsPerSecond, capacity: downCapacity),
            uploadNearCapacity: isNearCapacity(sample.uploadBitsPerSecond, capacity: upCapacity)
        )
    }

    private func setMenuBarStableTextTitle(
        sample: TrafficSample,
        downCapacity: Double,
        upCapacity: Double,
        labels: (download: String, upload: String)
    ) {
        let downloadValue = TrafficFormatting.fixedWidthMbit(sample.downloadBitsPerSecond)
        let uploadValue = TrafficFormatting.fixedWidthMbit(sample.uploadBitsPerSecond)
        setMenuBarDirectionalTitle(
            downloadLabel: labels.download,
            downloadValue: downloadValue,
            uploadLabel: labels.upload,
            uploadValue: uploadValue,
            font: NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
            downloadNearCapacity: isNearCapacity(sample.downloadBitsPerSecond, capacity: downCapacity),
            uploadNearCapacity: isNearCapacity(sample.uploadBitsPerSecond, capacity: upCapacity)
        )
    }

    private func setMenuBarPercentageTitle(
        sample: TrafficSample,
        downCapacity: Double,
        upCapacity: Double,
        labels: (download: String, upload: String)
    ) {
        setMenuBarDirectionalTitle(
            downloadLabel: labels.download,
            downloadValue: menuBarPercentage(sample.downloadBitsPerSecond, capacity: downCapacity),
            uploadLabel: labels.upload,
            uploadValue: menuBarPercentage(sample.uploadBitsPerSecond, capacity: upCapacity),
            font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
            downloadNearCapacity: isNearCapacity(sample.downloadBitsPerSecond, capacity: downCapacity),
            uploadNearCapacity: isNearCapacity(sample.uploadBitsPerSecond, capacity: upCapacity)
        )
    }

    private func menuBarPercentage(_ bitsPerSecond: Double, capacity: Double) -> String {
        guard capacity > 0 else { return "--%" }
        return String(format: "%.0f%%", usageFraction(bitsPerSecond, capacity: capacity) * 100)
    }

    private func setMenuBarTitle(_ title: String) {
        setMenuBarAttributedTitle(NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
                .foregroundColor: NSColor.labelColor,
            ]
        ))
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
        let title = NSMutableAttributedString()
        let baseAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.labelColor,
        ]
        func append(_ string: String, color: NSColor = .labelColor) {
            var attributes = baseAttributes
            attributes[.foregroundColor] = color
            title.append(NSAttributedString(string: string, attributes: attributes))
        }
        append("\(downloadLabel) ")
        append(downloadValue, color: downloadNearCapacity ? .systemRed : .labelColor)
        append("  \(uploadLabel) ")
        append(uploadValue, color: uploadNearCapacity ? .systemRed : .labelColor)
        setMenuBarAttributedTitle(title)
    }

    private func setMenuBarAttributedTitle(_ title: NSAttributedString) {
        guard let button = statusItem?.button else { return }
        statusItem?.length = NSStatusItem.variableLength
        button.image = nil
        button.contentTintColor = nil
        button.imagePosition = .noImage
        button.attributedTitle = title
    }

    private static func menuBarArrowsImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()
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
            up.stroke()

            return true
        }
        image.isTemplate = true
        return image
    }

    private static func menuBarUsageImage(
        downloadFraction: Double,
        uploadFraction: Double,
        downloadLabel: String,
        uploadLabel: String
    ) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let drawingColor = NSColor.black
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
                color: drawingColor,
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
                color: drawingColor,
                font: font
            )
            return true
        }
        image.isTemplate = true
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
        capacity > 0 && bitsPerSecond >= capacity * 0.95
    }

    private func isAtCapacity(_ bitsPerSecond: Double, capacity: Double) -> Bool {
        capacity > 0 && bitsPerSecond >= capacity
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
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            Task { @MainActor [weak self, weak button] in
                guard let self, let button else { return }
                self.constrainPopover(to: button)
            }
        }
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
    static let maximumScreenMargin: CGFloat = 48
}

struct MenuPopoverView: View {
    @ObservedObject var monitor: TrafficMonitor
    let onContentSizeChange: (CGSize) -> Void
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
        .frame(height: targetPopoverHeight, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            applyDefaultConfigPanelState()
            publishTargetContentSize()
        }
        .onChange(of: monitor.isConnected) { _ in
            applyDefaultConfigPanelState()
            publishTargetContentSize()
        }
        .onChange(of: isConfigPanelExpanded) { _ in
            publishTargetContentSize()
        }
    }

    private var maximumPopoverHeight: CGFloat {
        let visibleHeight = NSScreen.main?.visibleFrame.height ?? 760
        return max(420, visibleHeight - PopoverLayout.maximumScreenMargin)
    }

    private var targetPopoverHeight: CGFloat {
        isConfigPanelExpanded ? expandedPopoverHeight : collapsedPopoverHeight
    }

    private var collapsedPopoverHeight: CGFloat {
        min(440, maximumPopoverHeight)
    }

    private var expandedPopoverHeight: CGFloat {
        min(720, maximumPopoverHeight)
    }

    private var maximumSettingsHeight: CGFloat {
        max(240, expandedPopoverHeight - 430)
    }

    private func publishTargetContentSize() {
        onContentSizeChange(CGSize(width: 540, height: ceil(targetPopoverHeight)))
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
                Chart(recentSamples) { sample in
                    LineMark(
                        x: .value(L10n.string("chart.axis.time"), sample.recordedAt),
                        y: .value("Mbit/s", sample.downloadBitsPerSecond / 1_000_000),
                        series: .value(L10n.string("chart.series.direction"), L10n.string("traffic.download"))
                    )
                    .foregroundStyle(.blue)
                    .interpolationMethod(.linear)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    LineMark(
                        x: .value(L10n.string("chart.axis.time"), sample.recordedAt),
                        y: .value("Mbit/s", sample.uploadBitsPerSecond / 1_000_000),
                        series: .value(L10n.string("chart.series.direction"), L10n.string("traffic.upload"))
                    )
                    .foregroundStyle(Color(nsColor: .systemPink))
                    .interpolationMethod(.linear)
                    .lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 3]))
                }
                .chartYAxisLabel("Mbit/s")
                .frame(height: 170)
            }

            if let latestSample = monitor.samples.last {
                Divider()
                let latest = TrafficRateLimiter.cappedToConfiguredCapacities(latestSample)
                HStack(spacing: 12) {
                    TrafficMetricView(
                        title: L10n.string("traffic.download"),
                        value: formatWithPercentage(latest.downloadBitsPerSecond, capacityKey: "downstreamCapacityMbit"),
                        systemImage: "arrow.down",
                        color: .blue
                    )
                    TrafficMetricView(
                        title: L10n.string("traffic.upload"),
                        value: formatWithPercentage(latest.uploadBitsPerSecond, capacityKey: "upstreamCapacityMbit"),
                        systemImage: "arrow.up",
                        color: Color(nsColor: .systemPink)
                    )
                }
            }
        }
        .padding(PopoverLayout.cardPadding)
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

                ScrollView(.vertical) {
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
                .scrollIndicators(.automatic)
                .frame(height: maximumSettingsHeight)
            }
        }
        .popoverCard()
    }

    private var footer: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(L10n.string("disclaimer.short"))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            Text(L10n.format("app.version", "1.0.40"))
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
        }
        .padding(.horizontal, 4)
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
        return monitor.samples
            .filter { $0.recordedAt >= cutoff }
            .map(TrafficRateLimiter.cappedToConfiguredCapacities)
    }

    private func applyDefaultConfigPanelState() {
        guard !configPanelUserPreferenceSet else { return }
        isConfigPanelExpanded = !RouterClient.hasPreferences || !monitor.isConnected
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
    let title: String
    let value: String
    let systemImage: String
    let color: Color

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.headline.monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
        } icon: {
            Image(systemName: systemImage)
                .font(.headline)
        }
        .foregroundStyle(color)
        .frame(maxWidth: .infinity, alignment: .leading)
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
    @AppStorage("menuBarDisplayStyle") private var menuBarDisplayStyle = "rectangles"
    @AppStorage("menuBarLabelStyle") private var menuBarLabelStyle = "arrows"
    @AppStorage("showOneDecimalMbit") private var showOneDecimalMbit = false
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
                        Keychain.save(password: password)
                        saved = true
                        monitor.reconfigure()
                        detectLineRates()
                        if RouterClient.hasPreferences {
                            onSaved()
                        }
                    }
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
                Picker(L10n.string("picker.menuBarDisplay"), selection: $menuBarDisplayStyle) {
                    Text(L10n.string("picker.menuBarDisplay.rectangles")).tag("rectangles")
                    Text(L10n.string("picker.menuBarDisplay.minimalist")).tag("minimalist")
                    Text(L10n.string("picker.menuBarDisplay.rate")).tag("rate")
                    Text(L10n.string("picker.menuBarDisplay.stableText")).tag("stableText")
                    Text(L10n.string("picker.menuBarDisplay.percentage")).tag("percentage")
                }
                if menuBarDisplayStyle == "rate" {
                    Toggle(L10n.string("toggle.showOneDecimalPlace"), isOn: $showOneDecimalMbit)
                    Text(L10n.string("help.showOneDecimalPlace"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if menuBarDisplayStyle != "minimalist" {
                    Picker(L10n.string("picker.menuBarLabels"), selection: $menuBarLabelStyle) {
                        Text(L10n.string("picker.menuBarLabels.arrows")).tag("arrows")
                        Text(L10n.string("picker.menuBarLabels.short")).tag("short")
                        Text(L10n.string("picker.menuBarLabels.words")).tag("words")
                        Text(L10n.string("picker.menuBarLabels.network")).tag("network")
                        Text(L10n.string("picker.menuBarLabels.direction")).tag("direction")
                    }
                }
            } header: {
                Text(L10n.string("section.menuBar"))
            } footer: {
                Text(menuBarDisplayHelp)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if showsHiddenSettings {
                formSeparator

                Section(L10n.string("section.hiddenSettings")) {
                    TextField(L10n.string("field.pollingInterval"), value: $pollIntervalSeconds, format: .number)
                    Text(L10n.string("help.pollingInterval"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var formSeparator: some View {
        Divider()
            .padding(.vertical, 5)
    }

    private func detectLineRates() {
        guard let client = RouterClient.fromPreferences() else { return }
        Task {
            do {
                let rates = try await client.lineRates()
                detectedLineRates = rates
                detectionError = nil
                if downstreamCapacityMbit <= 0 { downstreamCapacityMbit = rates.currentDownstreamMbit }
                if upstreamCapacityMbit <= 0 { upstreamCapacityMbit = rates.currentUpstreamMbit }
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

    private var menuBarDisplayHelp: String {
        switch menuBarDisplayStyle {
        case "minimalist":
            return L10n.string("help.menuBarDisplay.minimalist")
        case "rate":
            return L10n.string("help.menuBarDisplay.rate")
        case "stableText":
            return L10n.string("help.menuBarDisplay.stableText")
        case "percentage":
            return L10n.string("help.menuBarDisplay.percentage")
        default:
            return L10n.string("help.menuBarDisplay.rectangles")
        }
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

enum TrafficRateLimiter {
    static func cappedToConfiguredCapacities(_ sample: TrafficSample) -> TrafficSample {
        TrafficSample(
            recordedAt: sample.recordedAt,
            uploadBitsPerSecond: cappedRate(sample.uploadBitsPerSecond, capacityKey: "upstreamCapacityMbit"),
            downloadBitsPerSecond: cappedRate(sample.downloadBitsPerSecond, capacityKey: "downstreamCapacityMbit")
        )
    }

    private static func cappedRate(_ bitsPerSecond: Double, capacityKey: String) -> Double {
        guard bitsPerSecond.isFinite else { return 0 }
        let nonNegativeRate = max(bitsPerSecond, 0)
        let capacityBitsPerSecond = UserDefaults.standard.double(forKey: capacityKey) * 1_000_000
        guard capacityBitsPerSecond.isFinite, capacityBitsPerSecond > 0 else {
            return nonNegativeRate
        }
        return min(nonNegativeRate, capacityBitsPerSecond)
    }
}

struct DSLLineRates {
    let currentDownstreamMbit: Double
    let currentUpstreamMbit: Double
    let maximumDownstreamMbit: Double
    let maximumUpstreamMbit: Double
}

@MainActor
final class TrafficMonitor: ObservableObject {
    static let shared = TrafficMonitor()
    private static let maximumStoredSamples = 10_000
    @Published private(set) var samples: [TrafficSample] = []
    @Published private(set) var status = L10n.string("status.enterCredentials")
    @Published private(set) var preferencesVersion = 0
    @Published private(set) var isConnected = false
    @Published private(set) var isConnecting = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastUpdated: Date?

    private let storage = SampleStorage()
    private var previous: (date: Date, sent: UInt64, received: UInt64)?
    private var timer: Timer?
    private var pollInFlight = false
    private var consecutivePollFailures = 0
    private var client: RouterClient?

    init() {
        samples = storage.load()
        lastUpdated = samples.last?.recordedAt
        scheduleTimer()
        poll()
        prepopulateLineCapacities()
    }

    func reconfigure() {
        client?.invalidate()
        client = nil
        previous = nil
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

    func prepopulateLineCapacities() {
        let defaults = UserDefaults.standard
        guard defaults.double(forKey: "downstreamCapacityMbit") <= 0 || defaults.double(forKey: "upstreamCapacityMbit") <= 0,
              let client = configuredClient() else { return }
        Task {
            do {
                let rates = try await client.lineRates()
                if defaults.double(forKey: "downstreamCapacityMbit") <= 0 {
                    defaults.set(rates.currentDownstreamMbit, forKey: "downstreamCapacityMbit")
                }
                if defaults.double(forKey: "upstreamCapacityMbit") <= 0 {
                    defaults.set(rates.currentUpstreamMbit, forKey: "upstreamCapacityMbit")
                }
                preferencesVersion += 1
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
                if let previous {
                    let elapsed = now.timeIntervalSince(previous.date)
                    if elapsed > 0 {
                        let rawSample = TrafficSample(
                            recordedAt: now,
                            uploadBitsPerSecond: Double(Self.delta(from: previous.sent, to: counters.sent)) * 8 / elapsed,
                            downloadBitsPerSecond: Double(Self.delta(from: previous.received, to: counters.received)) * 8 / elapsed
                        )
                        let sample = TrafficRateLimiter.cappedToConfiguredCapacities(rawSample)
                        samples.append(sample)
                        pruneSamples(now: now)
                        storage.save(samples)
                    }
                } else {
                    status = L10n.string("status.connectedWaitingForSecondSample")
                }
                previous = (now, counters.sent, counters.received)
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

    private static func delta(from old: UInt64, to new: UInt64) -> UInt64 {
        new >= old ? new - old : new + (1 << 32) - old
    }

    private func pruneSamples(now: Date) {
        samples.removeAll { $0.recordedAt < now.addingTimeInterval(-12 * 3600) }
        if samples.count > Self.maximumStoredSamples {
            samples.removeFirst(samples.count - Self.maximumStoredSamples)
        }
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
        guard let configuration = RouterClient.Configuration.fromPreferences() else {
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

        static func fromPreferences() -> Configuration? {
            let host = UserDefaults.standard.string(forKey: "routerHost")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let username = UserDefaults.standard.string(forKey: "routerUsername")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !host.isEmpty, !username.isEmpty, let password = Keychain.password(), !password.isEmpty else { return nil }
            return Configuration(host: host, username: username, password: password)
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

    static func fromPreferences() -> RouterClient? {
        guard let configuration = Configuration.fromPreferences() else { return nil }
        return RouterClient(configuration: configuration)
    }

    static var hasPreferences: Bool {
        Configuration.fromPreferences() != nil
    }

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
        let (data, response) = try await URLSession(configuration: configuration).data(from: url)
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
    private static let maximumStoredSamples = 10_000
    private let url: URL

    init() {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("RouterOnlineMonitor", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        url = folder.appendingPathComponent("samples.json")
    }

    func load() -> [TrafficSample] {
        guard let data = try? Data(contentsOf: url), let samples = try? JSONDecoder().decode([TrafficSample].self, from: data) else { return [] }
        let retainedSamples = samples.filter { $0.recordedAt > Date().addingTimeInterval(-12 * 3600) }
        if retainedSamples.count > Self.maximumStoredSamples {
            return Array(retainedSamples.suffix(Self.maximumStoredSamples))
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

    static func password() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account, kSecReturnData as String: true]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(password: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        let attributes = [kSecValueData as String: Data(password.utf8)]
        if SecItemUpdate(query as CFDictionary, attributes as CFDictionary) == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = Data(password.utf8)
            SecItemAdd(item as CFDictionary, nil)
        }
    }
}
