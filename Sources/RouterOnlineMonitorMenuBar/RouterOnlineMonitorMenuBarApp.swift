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

    func applicationDidFinishLaunching(_ notification: Notification) {
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
            popover.contentViewController = NSHostingController(rootView: MenuPopoverView(monitor: monitor))
            item.button?.target = self
            item.button?.action = #selector(togglePopover)
            samplesSubscription = monitor.$samples.sink { [weak self] _ in self?.updateMenuBar() }
            preferencesSubscription = monitor.$preferencesVersion.sink { [weak self] _ in self?.updateMenuBar() }
            connectionSubscription = monitor.$isConnected.sink { [weak self] _ in self?.updateMenuBar() }
            connectingSubscription = monitor.$isConnecting.sink { [weak self] _ in self?.updateMenuBar() }
            updateMenuBar()
        }
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
        setMenuBarUsageBars(
            sample: sample,
            downCapacity: downCapacity,
            upCapacity: upCapacity,
            labels: menuBarLabels()
        )
        statusItem?.button?.toolTip = menuBarTooltip(sample: sample, downCapacity: downCapacity, upCapacity: upCapacity)
    }

    private func setMenuBarUsageBars(sample: TrafficSample, downCapacity: Double, upCapacity: Double, labels: (download: String, upload: String)) {
        guard let button = statusItem?.button else { return }
        let image = Self.menuBarUsageImage(
            downloadFraction: usageFraction(sample.downloadBitsPerSecond, capacity: downCapacity),
            uploadFraction: usageFraction(sample.uploadBitsPerSecond, capacity: upCapacity),
            downloadNearCapacity: isNearCapacity(sample.downloadBitsPerSecond, capacity: downCapacity),
            uploadNearCapacity: isNearCapacity(sample.uploadBitsPerSecond, capacity: upCapacity),
            downloadLabel: labels.download,
            uploadLabel: labels.upload
        )
        statusItem?.length = image.size.width + 8
        button.title = ""
        button.attributedTitle = NSAttributedString()
        button.image = image
        button.imagePosition = .imageOnly
    }

    private func setMenuBarIcon() {
        guard let button = statusItem?.button else { return }
        statusItem?.length = NSStatusItem.squareLength
        button.title = ""
        button.attributedTitle = NSAttributedString()
        button.image = Self.menuBarArrowsImage()
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

    private func setMenuBarTitle(_ title: String) {
        guard let button = statusItem?.button else { return }
        statusItem?.length = NSStatusItem.variableLength
        button.image = nil
        button.imagePosition = .noImage
        button.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
                .foregroundColor: NSColor.labelColor,
            ]
        )
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
        downloadNearCapacity: Bool,
        uploadNearCapacity: Bool,
        downloadLabel: String,
        uploadLabel: String
    ) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let labelColor = NSColor.labelColor
        let downloadColor = downloadNearCapacity ? NSColor.systemRed : labelColor
        let uploadColor = uploadNearCapacity ? NSColor.systemRed : labelColor
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
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
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
}

struct MenuPopoverView: View {
    @ObservedObject var monitor: TrafficMonitor
    @State private var showsHiddenSettings = false
    @State private var versionClickCount = 0
    @State private var lastVersionClickAt: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L10n.string("app.name")).font(.headline)
                Spacer()
                if monitor.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(headerStatusLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if recentSamples.isEmpty {
                VStack(spacing: 6) {
                    if monitor.isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: emptyStateSystemImage).font(.title2)
                    }
                    Text(emptyStateTitle).font(.headline)
                    Text(emptyStateMessage).font(.caption).foregroundStyle(.secondary)
                }
                    .frame(height: 130)
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
                .frame(height: 150)
            }

            if let latestSample = monitor.samples.last {
                let latest = TrafficRateLimiter.cappedToConfiguredCapacities(latestSample)
                HStack(spacing: 16) {
                    Label(L10n.format("traffic.downloadWithValue", formatWithPercentage(latest.downloadBitsPerSecond, capacityKey: "downstreamCapacityMbit")), systemImage: "arrow.down").foregroundStyle(.blue)
                    Label(L10n.format("traffic.uploadWithValue", formatWithPercentage(latest.uploadBitsPerSecond, capacityKey: "upstreamCapacityMbit")), systemImage: "arrow.up").foregroundStyle(Color(nsColor: .systemPink))
                }
                .font(.headline)
            }

            Divider()
            SettingsView(monitor: monitor, showsHiddenSettings: showsHiddenSettings)
            Divider()
            HStack {
                Text(L10n.string("disclaimer.short"))
                Spacer()
                Text(L10n.format("app.version", "1.0.16"))
                    .onTapGesture {
                        registerVersionClick()
                    }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
            HStack {
                Button(L10n.string("button.refreshNow")) { monitor.poll() }
                    .disabled(monitor.isRefreshing)
                Spacer()
                Button(L10n.string("button.quit")) { NSApp.terminate(nil) }
            }
        }
        .padding()
        .frame(width: 560)
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

    private var recentSamples: [TrafficSample] {
        let cutoff = Date().addingTimeInterval(-30 * 60)
        return monitor.samples
            .filter { $0.recordedAt >= cutoff }
            .map(TrafficRateLimiter.cappedToConfiguredCapacities)
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

struct SettingsView: View {
    @ObservedObject var monitor: TrafficMonitor
    let showsHiddenSettings: Bool
    @AppStorage("routerHost") private var host = "192.168.178.1"
    @AppStorage("routerUsername") private var username = ""
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

    var body: some View {
        Form {
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

            Section {
                Picker(L10n.string("picker.menuBarLabels"), selection: $menuBarLabelStyle) {
                    Text(L10n.string("picker.menuBarLabels.arrows")).tag("arrows")
                    Text(L10n.string("picker.menuBarLabels.short")).tag("short")
                    Text(L10n.string("picker.menuBarLabels.words")).tag("words")
                    Text(L10n.string("picker.menuBarLabels.network")).tag("network")
                    Text(L10n.string("picker.menuBarLabels.direction")).tag("direction")
                }
                Toggle(L10n.string("toggle.showOneDecimalPlace"), isOn: $showOneDecimalMbit)
            }

            Section(L10n.string("section.capacityLimits")) {
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
            }

            if showsHiddenSettings {
                Section(L10n.string("section.hiddenSettings")) {
                    TextField(L10n.string("field.pollingInterval"), value: $pollIntervalSeconds, format: .number)
                    Text(L10n.string("help.pollingInterval"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section {
                HStack {
                    Spacer()
                    Button(L10n.string("button.saveAndConnect")) {
                        Keychain.save(password: password)
                        saved = true
                        monitor.reconfigure()
                        detectLineRates()
                    }
                    .keyboardShortcut(.defaultAction)
                    if saved { Text(L10n.string("status.savedToKeychain")).foregroundStyle(.secondary) }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            password = Keychain.password() ?? ""
            detectLineRates()
        }
        .onChange(of: showOneDecimalMbit) { _ in
            monitor.refreshPresentation()
        }
        .onChange(of: menuBarLabelStyle) { _ in
            monitor.refreshPresentation()
        }
        .onChange(of: pollIntervalSeconds) { _ in
            normalizePollingInterval()
            monitor.updatePollingInterval()
        }
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

    init() {
        samples = storage.load()
        lastUpdated = samples.last?.recordedAt
        scheduleTimer()
        poll()
        prepopulateLineCapacities()
    }

    func reconfigure() {
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
              let client = RouterClient.fromPreferences() else { return }
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
        guard let client = RouterClient.fromPreferences() else {
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

    private static var pollIntervalSeconds: TimeInterval {
        let value = UserDefaults.standard.double(forKey: "pollIntervalSeconds")
        return value >= 1 ? value : 5
    }
}

struct RouterClient {
    let host: String
    let username: String
    let password: String
    private static let service = "urn:dslforum-org:service:WANCommonInterfaceConfig:1"
    private static let dslService = "urn:dslforum-org:service:WANDSLInterfaceConfig:1"

    static func fromPreferences() -> RouterClient? {
        let host = UserDefaults.standard.string(forKey: "routerHost")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let username = UserDefaults.standard.string(forKey: "routerUsername")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !host.isEmpty, !username.isEmpty, let password = Keychain.password(), !password.isEmpty else { return nil }
        return RouterClient(host: host, username: username, password: password)
    }

    func counters() async throws -> (sent: UInt64, received: UInt64) {
        async let sent = counter(action: "GetTotalBytesSent", field: "NewTotalBytesSent")
        async let received = counter(action: "GetTotalBytesReceived", field: "NewTotalBytesReceived")
        return try await (sent, received)
    }

    func lineRates() async throws -> DSLLineRates {
        guard let url = URL(string: "http://\(host):49000/upnp/control/wandslifconfig1") else { throw RouterAPIError.invalidHost }
        let xml = """
        <?xml version=\"1.0\" encoding=\"utf-8\"?>
        <s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\"><s:Body><u:GetInfo xmlns:u=\"\(Self.dslService)\"/></s:Body></s:Envelope>
        """
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data(xml.utf8)
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\"\(Self.dslService)#GetInfo\"", forHTTPHeaderField: "SOAPAction")
        let delegate = DigestDelegate(username: username, password: password)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw RouterAPIError.requestFailed }
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

    private func counter(action: String, field: String) async throws -> UInt64 {
        guard let url = URL(string: "http://\(host):49000/upnp/control/wancommonifconfig1") else { throw RouterAPIError.invalidHost }
        let xml = """
        <?xml version=\"1.0\" encoding=\"utf-8\"?>
        <s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\"><s:Body><u:\(action) xmlns:u=\"\(Self.service)\"/></s:Body></s:Envelope>
        """
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data(xml.utf8)
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\"\(Self.service)#\(action)\"", forHTTPHeaderField: "SOAPAction")
        let delegate = DigestDelegate(username: username, password: password)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw RouterAPIError.requestFailed }
        let root = try XMLDocument(data: data, options: [])
        guard let text = try root.nodes(forXPath: "//*[local-name() = '\(field)']").first?.stringValue, let value = UInt64(text) else { throw RouterAPIError.invalidResponse }
        return value
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
