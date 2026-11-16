import Foundation
import SwiftUI
import AppKit
import IOKit.ps

enum HistoryRange: String, CaseIterable, Identifiable {
    case day = "24h"
    case week = "7 days"
    var id: String { rawValue }
    var seconds: Double { self == .day ? 24 * 3600 : 7 * 24 * 3600 }
}

@MainActor
final class Model: ObservableObject {
    @Published var battery: BatterySnapshot?
    @Published var status: BKStatus?
    @Published var config = BKConfig()
    @Published var history: [HistorySample] = []
    @Published var saveError: String?
    @Published var limitDraft: Double?          // slider value while dragging
    @Published var historyRange: HistoryRange = .day
    @Published var selectedMetric: Metric? = nil {
        didSet { chartSelection = nil; chartPinned = false }
    }
    @Published var chartSelection: Date? = nil
    @Published var chartPinned = false
    @Published var showSettings = false {
        didSet { if showSettings { checkForUpdate() } }
    }
    @Published var showWelcome = !UserDefaults.standard.bool(forKey: "onboarded")
    @Published var latestVersion: String?
    @Published var updateCheckFailed = false
    @Published var theme: AppTheme = AppTheme(rawValue: UserDefaults.standard.string(forKey: "theme") ?? "") ?? .color {
        didSet {
            UserDefaults.standard.set(theme.rawValue, forKey: "theme")
            applyAppearance()
        }
    }

    /// The Mac's own light/dark setting, used by Color and Liquid Glass.
    var systemScheme: ColorScheme {
        NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
    }

    /// Forces the whole app (menu bar panel included) into dark or light for those themes.
    func applyAppearance() {
        switch theme {
        case .dark: NSApp?.appearance = NSAppearance(named: .darkAqua)
        case .light: NSApp?.appearance = NSAppearance(named: .aqua)
        default: NSApp?.appearance = nil
        }
    }
    @Published var live = LivePower()
    @Published var liveApps: [AppUse] = []
    @Published var onAC = false

    private let smc = try? SMC()
    private var visible = false
    private var ticks = 0
    private var lastApps = Date.distantPast
    private var appsBusy = false

    private var lastLocalEdit = Date.distantPast
    private var timer: Timer?
    private var historyTimer: Timer?

    init() {
        if let c = BKConfig.load() { config = c }
        refresh()
        loadHistory()
        // Every 2 s while the panel is open; every 20 s (menu bar % only) when it's closed.
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.timerTick() }
        }
        historyTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.loadHistory() }
        }
        watchPowerSource()
        DispatchQueue.main.async { [weak self] in self?.applyAppearance() }
    }

    /// macOS calls this the moment a charger is connected or removed.
    private func watchPowerSource() {
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOPowerSourceCallbackType = { ctx in
            guard let ctx else { return }
            let model = Unmanaged<Model>.fromOpaque(ctx).takeUnretainedValue()
            Task { @MainActor in model.powerChanged() }
        }
        if let src = IOPSNotificationCreateRunLoopSource(callback, ctx)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
        }
    }

    func powerChanged() {
        refresh()
        // The service reacts ~1 s after a plug event; catch its updated state right away.
        for delay in [0.6, 1.5, 3.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.refresh() }
        }
    }

    func setVisible(_ v: Bool) {
        visible = v
        if v {
            refresh()
            lastApps = .distantPast
            sampleApps()
        }
    }

    private func timerTick() {
        ticks += 1
        if visible {
            refresh()
            if Date().timeIntervalSince(lastApps) >= 5 { sampleApps() }
        } else if ticks % 10 == 0 {
            refresh()
        }
    }

    private func sampleApps() {
        guard !appsBusy else { return }
        appsBusy = true
        lastApps = Date()
        let sysW = live.systemW ?? battery?.systemLoadW
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let apps = AppPowerSampler.sample(systemW: sysW)
            DispatchQueue.main.async {
                guard let self else { return }
                if !apps.isEmpty { self.liveApps = apps }
                self.appsBusy = false
            }
        }
    }

    func refresh() {
        if let smc { live = smc.livePower() }
        onAC = Model.powerSourceIsAC()
        battery = BatterySnapshot.read()
        status = BKStatus.load()
        if Date().timeIntervalSince(lastLocalEdit) > 5, let c = BKConfig.load(), c != config {
            config = c
        }
    }

    func loadHistory() {
        history = HistorySample.loadAll(since: Date().timeIntervalSince1970 - HistoryRange.week.seconds)
    }

    func samples(in range: HistoryRange) -> [HistorySample] {
        let since = Date().timeIntervalSince1970 - range.seconds
        return history.filter { $0.t >= since }
    }

    func update(_ change: (inout BKConfig) -> Void) {
        var c = config
        change(&c)
        c = c.sanitized()
        config = c
        lastLocalEdit = Date()
        do {
            try c.save()
            saveError = nil
        } catch {
            saveError = "Couldn't save settings. Changing them needs an admin account; if you are an admin, re-run install.sh."
        }
    }

    // MARK: Derived values

    var daemonAlive: Bool {
        guard let s = status else { return false }
        return Date().timeIntervalSince1970 - s.updated < 45 && s.mode != "Stopped"
    }

    static func powerSourceIsAC() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
        return (type as String) == kIOPMACPowerKey
    }

    /// Watts coming in from the charger right now.
    var chargerW: Double? { live.inW ?? battery?.systemInW }

    /// Watts the whole Mac is using right now.
    var systemW: Double? {
        if let w = live.systemW { return w }
        if let w = battery?.systemLoadW { return w }
        if let b = battery, b.batteryWatts < -0.1 { return -b.batteryWatts }
        return nil
    }

    var pluggedIn: Bool {
        if let w = live.inW { return w > 0.5 || onAC }
        return onAC || (battery?.externalConnected ?? false)
    }

    var topApps: [AppUse] { liveApps.isEmpty ? (status?.topApps ?? []) : liveApps }

    /// Prefer the live sensor; then the service's reading; then ioreg.
    var temperature: Double? {
        if let t = live.tempC { return t }
        if daemonAlive, let t = status?.batteryTempC, t > 0 { return t }
        if let b = battery, b.temperatureValid { return b.temperatureC }
        return nil
    }

    var health: Double? {
        guard let b = battery, b.healthValid else { return nil }
        return b.healthPercent
    }

    var banner: (text: String, color: Color)? {
        if let e = saveError { return (e, .red) }
        if !daemonAlive { return ("The background service isn't running. Re-run install.sh.", .red) }
        if let s = status, !s.canInhibit && !s.canCutAdapter {
            return ("This macOS version blocks charge control. Analytics still work. Use System Settings › Battery › Charge Limit for the limit.", .orange)
        }
        if let e = status?.lastError { return ("Control error: \(e)", .orange) }
        return nil
    }

    var mode: String { daemonAlive ? (status?.mode ?? "") : "Service offline" }

    var stateColor: Color {
        let m = mode
        if !daemonAlive { return .red }
        if m.hasPrefix("Paused") || m.hasPrefix("Monitoring") || m.hasPrefix("Not charging") { return .orange }
        if m.hasPrefix("Charging") || m.hasPrefix("Topping") || m.hasPrefix("Starting") { return .green }
        if m.hasPrefix("Holding") || m.hasPrefix("Sailing") { return .teal }
        if m.hasPrefix("Draining") { return .purple }
        if m.hasPrefix("On battery") { return .blue }
        return .gray
    }

    var stateSymbol: String {
        let m = mode
        if !daemonAlive { return "exclamationmark.triangle.fill" }
        if m.hasPrefix("Paused") { return "thermometer.sun.fill" }
        if m.hasPrefix("Charging") || m.hasPrefix("Topping") { return "bolt.fill" }
        if m.hasPrefix("Holding") { return "pause.fill" }
        if m.hasPrefix("Sailing") { return "sailboat.fill" }
        if m.hasPrefix("Draining") { return "arrow.down" }
        if m.hasPrefix("Limiter off") { return "power" }
        if m.hasPrefix("On battery") { return "battery.75percent" }
        return "powerplug.fill"
    }

    /// Menu bar icon reflects what BatteryKit is doing.
    var menuSymbol: String {
        let m = mode
        if daemonAlive {
            if m.hasPrefix("Paused") { return "thermometer.sun.fill" }
            if m.hasPrefix("Holding") || m.hasPrefix("Sailing") { return "leaf.fill" }
        }
        guard let b = battery else { return "battery.0percent" }
        if b.isCharging { return "battery.100percent.bolt" }
        switch b.percent {
        case 88...: return "battery.100percent"
        case 63..<88: return "battery.75percent"
        case 38..<63: return "battery.50percent"
        case 13..<38: return "battery.25percent"
        default: return "battery.0percent"
        }
    }

    var lastCalibrated: Date? {
        let t = UserDefaults.standard.double(forKey: "lastCalibrated")
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    /// Calibration = one full charge to 100%, then back to the limit.
    func calibrate() {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastCalibrated")
        update { $0.topUp = true }
        objectWillChange.send()
    }

    func diagnostics() -> String {
        var out = "BatteryKit \(bkVersion)\n"
        out += (try? String(contentsOfFile: BKPaths.status, encoding: .utf8)) ?? "no status file"
        out += "\n"
        out += (try? String(contentsOfFile: BKPaths.config, encoding: .utf8)) ?? "no config file"
        return out
    }
}

// MARK: - Setup, updates, uninstall

let bkRepoURL = URL(string: "https://github.com/preston100/BatteryKit")!

extension Model {
    func finishWelcome() {
        UserDefaults.standard.set(true, forKey: "onboarded")
        showWelcome = false
    }

    func openBatterySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    var updateAvailable: Bool {
        guard let latest = latestVersion else { return false }
        return Model.isNewer(latest, than: bkVersion)
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ v: String) -> [Int] {
            v.trimmingCharacters(in: CharacterSet(charactersIn: "vV")).split(separator: ".").map { Int($0) ?? 0 }
        }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    /// Looks at the latest GitHub release. Nothing is sent except a normal web request.
    func checkForUpdate() {
        let api = URL(string: "https://api.github.com/repos/preston100/BatteryKit/releases/latest")!
        var req = URLRequest(url: api, timeoutInterval: 10)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { [weak self] data, _, error in
            let tag = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["tag_name"] as? String
            DispatchQueue.main.async {
                // No releases published yet counts as "up to date".
                self?.latestVersion = tag ?? (error == nil ? bkVersion : nil)
                self?.updateCheckFailed = (tag == nil && error != nil)
            }
        }.resume()
    }

    /// Removes everything BatteryKit installed and hands charging back to macOS.
    func uninstall() {
        let alert = NSAlert()
        alert.messageText = "Uninstall BatteryKit?"
        alert.informativeText = "This removes the app and its background service, and charging goes back to normal. You'll be asked for your password."
        alert.addButton(withTitle: "Uninstall")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let support = "/Library/Application Support/BatteryKit"
        let shell = [
            "launchctl bootout system/com.batterykit.daemon 2>/dev/null",
            "sleep 2",
            "'\(support)/bin/batterykitd' release >/dev/null 2>&1",
            "rm -f /Library/LaunchDaemons/com.batterykit.daemon.plist /usr/local/bin/batterykitd",
            "rm -rf '\(support)' /Applications/BatteryKit.app",
        ].joined(separator: "; ")
        let script = "do shell script \"\(shell)\" with administrator privileges"
        var err: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&err)
        if err != nil { return }   // cancelled the password prompt

        let agent = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.batterykit.app.plist")
        try? FileManager.default.removeItem(at: agent)
        UserDefaults.standard.removePersistentDomain(forName: Bundle.main.bundleIdentifier ?? "com.batterykit.app")
        NSApp.terminate(nil)
    }
}

// MARK: - Appearance

enum AppTheme: String, CaseIterable, Identifiable {
    case dark, light, color, glass
    var id: String { rawValue }

    var title: String {
        switch self {
        case .dark: return "Dark"
        case .light: return "Light"
        case .color: return "Color"
        case .glass: return "Liquid Glass"
        }
    }

    var symbol: String {
        switch self {
        case .dark: return "moon.fill"
        case .light: return "sun.max.fill"
        case .color: return "paintpalette.fill"
        case .glass: return "drop.fill"
        }
    }

    var scheme: ColorScheme? {
        switch self {
        case .dark: return .dark
        case .light: return .light
        default: return nil
        }
    }
}

// MARK: - Metrics shown in the tile grid

enum Metric: String, CaseIterable, Identifiable {
    case health, temperature, charging, using, apps, cycles, voltage, capacity
    var id: String { rawValue }

    var title: String {
        switch self {
        case .health: return "Health"
        case .temperature: return "Temperature"
        case .charging: return "Charging"
        case .using: return "Using"
        case .apps: return "Top App"
        case .cycles: return "Cycles"
        case .voltage: return "Voltage"
        case .capacity: return "Capacity"
        }
    }

    var symbol: String {
        switch self {
        case .health: return "heart.fill"
        case .temperature: return "thermometer.medium"
        case .charging: return "powerplug.fill"
        case .using: return "bolt.fill"
        case .apps: return "square.grid.2x2.fill"
        case .cycles: return "arrow.triangle.2.circlepath"
        case .voltage: return "waveform.path.ecg"
        case .capacity: return "battery.100percent"
        }
    }

    /// Smallest y-axis span so a flat line doesn't look like a cliff.
    var minSpan: Double {
        switch self {
        case .health: return 1
        case .temperature: return 2
        case .charging, .using, .apps: return 1
        case .cycles: return 1
        case .voltage: return 0.1
        case .capacity: return 20
        }
    }

    func value(_ s: HistorySample) -> Double? {
        switch self {
        case .health: return s.health
        case .temperature: return s.temp > 0 ? s.temp : nil
        case .charging: return s.inW
        case .using: return s.loadW ?? (s.watts < 0 ? -s.watts : nil)
        case .apps: return s.apps.first?.watts
        case .cycles: return s.cycles
        case .voltage: return s.voltage
        case .capacity: return s.capacity
        }
    }

    func format(_ v: Double) -> String {
        switch self {
        case .health: return String(format: "%.1f%%", v)
        case .temperature: return String(format: "%.1f°C", v)
        case .charging, .using, .apps: return String(format: "%.1f W", v)
        case .cycles: return String(format: "%.0f", v)
        case .voltage: return String(format: "%.2f V", v)
        case .capacity: return String(format: "%.0f mAh", v)
        }
    }
}

extension Model {
    /// Green at 100 %, fading through yellow and orange to red at 1 %.
    func levelColor(_ pct: Int) -> Color {
        let p = Double(min(100, max(1, pct))) / 100
        return Color(hue: 0.33 * p, saturation: 0.85, brightness: 0.92)
    }

    func tint(for metric: Metric) -> Color {
        switch metric {
        case .health:
            guard let h = health else { return .gray }
            return h >= 85 ? .green : (h >= 80 ? .orange : .red)
        case .temperature:
            guard let t = temperature else { return .gray }
            return t >= 40 ? .red : (t >= 35 ? .orange : .teal)
        case .charging: return .green
        case .using: return .yellow
        case .apps: return .pink
        case .cycles: return .blue
        case .voltage: return .indigo
        case .capacity: return .mint
        }
    }

    /// Big value + small caption for each tile.
    func tileText(for metric: Metric) -> (value: String, caption: String) {
        let b = battery
        let nf = NumberFormatter()
        nf.numberStyle = .decimal
        func n(_ v: Int) -> String { nf.string(from: NSNumber(value: v)) ?? "\(v)" }

        switch metric {
        case .health:
            return (health.map { String(format: "%.0f%%", $0) } ?? "—", "Health")
        case .temperature:
            return (temperature.map { String(format: "%.1f°", $0) } ?? "—", "Temperature")
        case .charging:
            if daemonAlive, status?.adapterEnabled == false { return ("0 W", "Charger paused") }
            guard pluggedIn else { return ("—", "Unplugged") }
            return (String(format: "%.1f W", chargerW ?? 0), "From charger")
        case .using:
            return (systemW.map { String(format: "%.1f W", $0) } ?? "—", "Mac using")
        case .apps:
            guard let top = topApps.first else { return ("—", "Top app") }
            return (top.name, top.watts > 0 ? String(format: "≈ %.1f W", top.watts) : "Top app")
        case .cycles:
            return (b.map { "\($0.cycleCount)" } ?? "—", "Cycles")
        case .voltage:
            return (b.map { String(format: "%.2f V", $0.voltageV) } ?? "—", "Voltage")
        case .capacity:
            guard let b, b.healthValid else { return ("—", "mAh now") }
            return (n(b.maxCapacity), "of \(n(b.designCapacity)) mAh")
        }
    }
}

func formatMinutes(_ m: Int) -> String {
    let h = m / 60, mm = m % 60
    return h > 0 ? "\(h)h \(mm)m" : "\(mm)m"
}
