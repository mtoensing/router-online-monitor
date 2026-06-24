import Charts
import AppKit
import Combine
import Foundation
import Security
import SwiftUI

@main
struct FritzBoxBandwidthMenuBarApp: App {
    @NSApplicationDelegateAdaptor(MenuBarController.self) private var menuBarController

    var body: some Scene {
        Settings {
            SettingsView(monitor: BandwidthMonitor.shared)
        }
    }
}

@MainActor
final class MenuBarController: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var dashboardWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var samplesSubscription: AnyCancellable?
    private var preferencesSubscription: AnyCancellable?
    private var sparkline: MenuBarSparklineView?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.title = "D: —  U: —"
            button.toolTip = "FritzBox bandwidth: waiting for first sample"
            let sparkline = MenuBarSparklineView(frame: button.bounds)
            sparkline.autoresizingMask = [.width, .height]
            button.addSubview(sparkline, positioned: .below, relativeTo: nil)
            self.sparkline = sparkline
        }
        let menu = NSMenu()
        menu.addItem(withTitle: "Open bandwidth graph", action: #selector(openDashboard), keyEquivalent: "")
        menu.addItem(withTitle: "Refresh now", action: #selector(refresh), keyEquivalent: "")
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit FritzBox Bandwidth", action: #selector(quit), keyEquivalent: "q")
        menu.items.forEach { $0.target = self }
        item.menu = menu
        statusItem = item

        Task { @MainActor in
            let monitor = BandwidthMonitor.shared
            samplesSubscription = monitor.$samples.sink { [weak self] _ in self?.updateMenuBar() }
            preferencesSubscription = monitor.$preferencesVersion.sink { [weak self] _ in self?.updateMenuBar() }
            updateMenuBar()
        }
    }

    private func updateMenuBar() {
        guard let button = statusItem?.button else { return }
        let showChart = UserDefaults.standard.object(forKey: "showMenuBarChart") as? Bool ?? true
        sparkline?.isHidden = !showChart
        sparkline?.samples = BandwidthMonitor.shared.samples
        guard let sample = BandwidthMonitor.shared.samples.last else {
            button.title = "D: —  U: —"
            button.toolTip = "FritzBox bandwidth: waiting for first sample"
            return
        }
        let mode = UserDefaults.standard.string(forKey: "menuBarMode") ?? "rate"
        if mode == "percentage" {
            let downCapacity = UserDefaults.standard.double(forKey: "downstreamCapacityMbit") * 1_000_000
            let upCapacity = UserDefaults.standard.double(forKey: "upstreamCapacityMbit") * 1_000_000
            button.title = "D: \(formatPercent(sample.downloadBitsPerSecond, capacity: downCapacity))  U: \(formatPercent(sample.uploadBitsPerSecond, capacity: upCapacity))"
            button.toolTip = "Current FritzBox bandwidth as a percentage of the configured line speed"
        } else {
            button.title = "D: \(formatRate(sample.downloadBitsPerSecond))  U: \(formatRate(sample.uploadBitsPerSecond))"
            button.toolTip = "Current FritzBox download and upload rate"
        }
    }

    private func formatRate(_ bitsPerSecond: Double) -> String {
        bitsPerSecond >= 1_000_000 ? String(format: "%.1f Mbit", bitsPerSecond / 1_000_000) : String(format: "%.0f kbit", bitsPerSecond / 1_000)
    }

    private func formatPercent(_ bitsPerSecond: Double, capacity: Double) -> String {
        guard capacity > 0 else { return "—" }
        return String(format: "%.0f%%", bitsPerSecond / capacity * 100)
    }

    @objc private func openDashboard() {
        Task { @MainActor in
            let monitor = BandwidthMonitor.shared
            if dashboardWindow == nil {
                let controller = NSHostingController(rootView: MonitorView(monitor: monitor))
                let window = NSWindow(contentViewController: controller)
                window.title = "FritzBox bandwidth"
                window.styleMask = [.titled, .closable, .miniaturizable]
                window.setContentSize(NSSize(width: 500, height: 430))
                window.isReleasedWhenClosed = false
                dashboardWindow = window
            }
            dashboardWindow?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    @objc private func refresh() { Task { @MainActor in BandwidthMonitor.shared.poll() } }
    @objc private func openSettings() {
        Task { @MainActor in
            let monitor = BandwidthMonitor.shared
            if settingsWindow == nil {
                let controller = NSHostingController(rootView: SettingsView(monitor: monitor))
                let window = NSWindow(contentViewController: controller)
                window.title = "FritzBox bandwidth settings"
                window.styleMask = [.titled, .closable]
                window.contentMinSize = NSSize(width: 560, height: 420)
                window.setContentSize(NSSize(width: 600, height: 460))
                window.isReleasedWhenClosed = false
                settingsWindow = window
            }
            settingsWindow?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
    @objc private func quit() { NSApp.terminate(nil) }
}

final class MenuBarSparklineView: NSView {
    var samples: [TrafficSample] = [] {
        didSet { needsDisplay = true }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let recentSamples = Array(samples.suffix(30))
        guard recentSamples.count > 1, let context = NSGraphicsContext.current?.cgContext else { return }
        let maximum = max(
            max(recentSamples.map(\.downloadBitsPerSecond).max() ?? 0, recentSamples.map(\.uploadBitsPerSecond).max() ?? 0),
            1
        )
        let plot = bounds.insetBy(dx: 3, dy: 4)

        func drawLine(_ values: [Double], color: NSColor) {
            let path = CGMutablePath()
            for (index, value) in values.enumerated() {
                let progress = CGFloat(index) / CGFloat(values.count - 1)
                let x = plot.minX + plot.width * progress
                let y = plot.minY + plot.height * CGFloat(value / maximum)
                index == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
            }
            context.setStrokeColor(color.withAlphaComponent(0.2).cgColor)
            context.setLineWidth(1)
            context.setLineCap(.round)
            context.addPath(path)
            context.strokePath()
        }

        drawLine(recentSamples.map(\.downloadBitsPerSecond), color: .systemBlue)
        drawLine(recentSamples.map(\.uploadBitsPerSecond), color: .systemOrange)
    }
}

struct MonitorView: View {
    @ObservedObject var monitor: BandwidthMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("FritzBox bandwidth").font(.headline)
                Spacer()
                Text(monitor.status).foregroundStyle(.secondary).font(.caption)
            }

            if monitor.samples.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "chart.xyaxis.line").font(.system(size: 34))
                    Text("Collecting samples").font(.headline)
                    Text("The first traffic rate appears after two polls.").foregroundStyle(.secondary)
                }
                    .frame(width: 460, height: 220)
            } else {
                Chart(monitor.samples) { sample in
                    LineMark(
                        x: .value("Time", sample.recordedAt),
                        y: .value("Mbit/s", sample.downloadBitsPerSecond / 1_000_000),
                        series: .value("Direction", "Download")
                    )
                        .foregroundStyle(.blue)
                        .interpolationMethod(.linear)
                    LineMark(
                        x: .value("Time", sample.recordedAt),
                        y: .value("Mbit/s", sample.uploadBitsPerSecond / 1_000_000),
                        series: .value("Direction", "Upload")
                    )
                        .foregroundStyle(.orange)
                        .interpolationMethod(.linear)
                }
                .chartYAxisLabel("Mbit/s")
                .chartLegend(position: .bottom, alignment: .leading) {
                    HStack { Label("Download", systemImage: "circle.fill").foregroundStyle(.blue); Label("Upload", systemImage: "circle.fill").foregroundStyle(.orange) }
                }
                .frame(width: 460, height: 260)
            }

            if let latest = monitor.samples.last {
                HStack(spacing: 16) {
                    Label(format(latest.downloadBitsPerSecond), systemImage: "arrow.down").foregroundStyle(.blue)
                    Label(format(latest.uploadBitsPerSecond), systemImage: "arrow.up").foregroundStyle(.orange)
                }
                .font(.headline)
            }

            Divider()
            HStack {
                Button("Settings…") { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) }
                Spacer()
                Button("Refresh now") { monitor.poll() }
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
        }
        .padding()
        .frame(width: 500)
    }

    private func format(_ bitsPerSecond: Double) -> String {
        bitsPerSecond >= 1_000_000 ? String(format: "%.2f Mbit/s", bitsPerSecond / 1_000_000) : String(format: "%.0f kbit/s", bitsPerSecond / 1_000)
    }
}

struct SettingsView: View {
    @ObservedObject var monitor: BandwidthMonitor
    @AppStorage("fritzboxHost") private var host = "192.168.178.1"
    @AppStorage("fritzboxUsername") private var username = ""
    @AppStorage("menuBarMode") private var menuBarMode = "rate"
    @AppStorage("showMenuBarChart") private var showMenuBarChart = true
    @AppStorage("downstreamCapacityMbit") private var downstreamCapacityMbit = 0.0
    @AppStorage("upstreamCapacityMbit") private var upstreamCapacityMbit = 0.0
    @State private var password = ""
    @State private var saved = false
    @State private var detectedLineRates: DSLLineRates?
    @State private var detectionError: String?

    var body: some View {
        Form {
            Section("FritzBox connection") {
                TextField("FritzBox host", text: $host)
                TextField("Username", text: $username)
                SecureField("Password", text: $password)
            }

            Section("Menu bar") {
                Picker("Display", selection: $menuBarMode) {
                    Text("Bandwidth").tag("rate")
                    Text("Percentage").tag("percentage")
                }
                Toggle("Show background chart", isOn: $showMenuBarChart)

                if menuBarMode == "percentage" {
                    TextField("Downstream (Mbit/s)", value: $downstreamCapacityMbit, format: .number)
                    TextField("Upstream (Mbit/s)", value: $upstreamCapacityMbit, format: .number)
                    if let rates = detectedLineRates {
                        LabeledContent("Detected downstream") {
                            Text("\(format(rates.currentDownstreamMbit)) Mbit/s (max \(format(rates.maximumDownstreamMbit)))")
                        }
                        LabeledContent("Detected upstream") {
                            Text("\(format(rates.currentUpstreamMbit)) Mbit/s (max \(format(rates.maximumUpstreamMbit)))")
                        }
                        Button("Use FritzBox Line Rate") {
                            downstreamCapacityMbit = rates.currentDownstreamMbit
                            upstreamCapacityMbit = rates.currentUpstreamMbit
                        }
                    } else if let detectionError {
                        Text(detectionError).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("Reading the FritzBox line rate…").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                HStack {
                    Spacer()
                    Button("Save and Connect") {
                    Keychain.save(password: password)
                    saved = true
                    monitor.reconfigure()
                    detectLineRates()
                    }
                    .keyboardShortcut(.defaultAction)
                    if saved { Text("Saved to Keychain").foregroundStyle(.secondary) }
                }
            }
        }
        .padding()
        .frame(minWidth: 560, idealWidth: 600)
        .onAppear {
            password = Keychain.password() ?? ""
            detectLineRates()
        }
    }

    private func detectLineRates() {
        guard let client = FritzBoxClient.fromPreferences() else { return }
        Task {
            do {
                let rates = try await client.lineRates()
                detectedLineRates = rates
                detectionError = nil
                if downstreamCapacityMbit <= 0 { downstreamCapacityMbit = rates.currentDownstreamMbit }
                if upstreamCapacityMbit <= 0 { upstreamCapacityMbit = rates.currentUpstreamMbit }
            } catch {
                detectionError = "Could not read the FritzBox line rate."
            }
        }
    }

    private func format(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
}

struct TrafficSample: Codable, Identifiable {
    var recordedAt: Date
    var uploadBitsPerSecond: Double
    var downloadBitsPerSecond: Double
    var id: Date { recordedAt }
}

struct DSLLineRates {
    let currentDownstreamMbit: Double
    let currentUpstreamMbit: Double
    let maximumDownstreamMbit: Double
    let maximumUpstreamMbit: Double
}

@MainActor
final class BandwidthMonitor: ObservableObject {
    static let shared = BandwidthMonitor()
    @Published private(set) var samples: [TrafficSample] = []
    @Published private(set) var status = "Configure credentials in Settings"
    @Published private(set) var preferencesVersion = 0

    private let storage = SampleStorage()
    private var previous: (date: Date, sent: UInt64, received: UInt64)?
    private var timer: Timer?

    init() {
        samples = storage.load()
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        poll()
    }

    func reconfigure() {
        previous = nil
        preferencesVersion += 1
        poll()
    }

    func poll() {
        guard let client = FritzBoxClient.fromPreferences() else {
            status = "Configure credentials in Settings"
            return
        }
        status = "Refreshing…"
        Task {
            do {
                let counters = try await client.counters()
                let now = Date()
                if let previous {
                    let elapsed = now.timeIntervalSince(previous.date)
                    if elapsed > 0 {
                        let sample = TrafficSample(
                            recordedAt: now,
                            uploadBitsPerSecond: Double(Self.delta(from: previous.sent, to: counters.sent)) * 8 / elapsed,
                            downloadBitsPerSecond: Double(Self.delta(from: previous.received, to: counters.received)) * 8 / elapsed
                        )
                        samples.append(sample)
                        samples.removeAll { $0.recordedAt < now.addingTimeInterval(-12 * 3600) }
                        storage.save(samples)
                    }
                }
                previous = (now, counters.sent, counters.received)
                status = "Updated \(now.formatted(date: .omitted, time: .shortened))"
            } catch {
                status = "FritzBox unavailable: \(error.localizedDescription)"
            }
        }
    }

    private static func delta(from old: UInt64, to new: UInt64) -> UInt64 {
        new >= old ? new - old : new + (1 << 32) - old
    }
}

struct FritzBoxClient {
    let host: String
    let username: String
    let password: String
    private static let service = "urn:dslforum-org:service:WANCommonInterfaceConfig:1"
    private static let dslService = "urn:dslforum-org:service:WANDSLInterfaceConfig:1"

    static func fromPreferences() -> FritzBoxClient? {
        let host = UserDefaults.standard.string(forKey: "fritzboxHost")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let username = UserDefaults.standard.string(forKey: "fritzboxUsername")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !host.isEmpty, !username.isEmpty, let password = Keychain.password(), !password.isEmpty else { return nil }
        return FritzBoxClient(host: host, username: username, password: password)
    }

    func counters() async throws -> (sent: UInt64, received: UInt64) {
        async let sent = counter(action: "GetTotalBytesSent", field: "NewTotalBytesSent")
        async let received = counter(action: "GetTotalBytesReceived", field: "NewTotalBytesReceived")
        return try await (sent, received)
    }

    func lineRates() async throws -> DSLLineRates {
        guard let url = URL(string: "http://\(host):49000/upnp/control/wandslifconfig1") else { throw FritzError.invalidHost }
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
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw FritzError.requestFailed }
        let root = try XMLDocument(data: data, options: [])
        func rate(_ field: String) throws -> Double {
            guard let text = try root.nodes(forXPath: "//*[local-name() = '\(field)']").first?.stringValue, let kbitPerSecond = Double(text) else { throw FritzError.invalidResponse }
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
        guard let url = URL(string: "http://\(host):49000/upnp/control/wancommonifconfig1") else { throw FritzError.invalidHost }
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
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw FritzError.requestFailed }
        let root = try XMLDocument(data: data, options: [])
        guard let text = try root.nodes(forXPath: "//*[local-name() = '\(field)']").first?.stringValue, let value = UInt64(text) else { throw FritzError.invalidResponse }
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

enum FritzError: LocalizedError {
    case invalidHost, requestFailed, invalidResponse
    var errorDescription: String? {
        switch self {
        case .invalidHost: return "Invalid host"
        case .requestFailed: return "Request failed"
        case .invalidResponse: return "Unexpected API response"
        }
    }
}

final class SampleStorage {
    private let url: URL

    init() {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("FritzBoxBandwidth", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        url = folder.appendingPathComponent("samples.json")
    }

    func load() -> [TrafficSample] {
        guard let data = try? Data(contentsOf: url), let samples = try? JSONDecoder().decode([TrafficSample].self, from: data) else { return [] }
        return samples.filter { $0.recordedAt > Date().addingTimeInterval(-12 * 3600) }
    }

    func save(_ samples: [TrafficSample]) {
        guard let data = try? JSONEncoder().encode(samples) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

enum Keychain {
    private static let service = "FritzBoxBandwidth"
    private static let account = "fritzbox-password"

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
