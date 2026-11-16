import Foundation
import IOKit

// MARK: - Paths & version

enum BKPaths {
    static let dir = "/Library/Application Support/BatteryKit"
    static let config = dir + "/config.json"
    static let status = dir + "/status.json"
    static let history = dir + "/history.csv"
    static let log = "/Library/Logs/BatteryKit.log"
}

let bkVersion = "2.9"

// MARK: - Config (written by the app, read by the daemon)

struct BKConfig: Codable, Equatable {
    var enabled: Bool = true
    var limit: Int = 80
    var sailingGap: Int = 5
    var heatProtection: Bool = true
    var maxTempC: Double = 35
    var topUp: Bool = false
    var dischargeToLimit: Bool = false

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = BKConfig()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        limit = try c.decodeIfPresent(Int.self, forKey: .limit) ?? d.limit
        sailingGap = try c.decodeIfPresent(Int.self, forKey: .sailingGap) ?? d.sailingGap
        heatProtection = try c.decodeIfPresent(Bool.self, forKey: .heatProtection) ?? d.heatProtection
        maxTempC = try c.decodeIfPresent(Double.self, forKey: .maxTempC) ?? d.maxTempC
        topUp = try c.decodeIfPresent(Bool.self, forKey: .topUp) ?? d.topUp
        dischargeToLimit = try c.decodeIfPresent(Bool.self, forKey: .dischargeToLimit) ?? d.dischargeToLimit
    }

    func sanitized() -> BKConfig {
        var c = self
        c.limit = min(100, max(50, c.limit))
        c.sailingGap = min(20, max(1, c.sailingGap))
        c.maxTempC = min(50, max(25, c.maxTempC))
        return c
    }

    static func load() -> BKConfig? {
        guard let data = FileManager.default.contents(atPath: BKPaths.config),
              let cfg = try? JSONDecoder().decode(BKConfig.self, from: data) else { return nil }
        return cfg.sanitized()
    }

    /// Non-atomic write on purpose: the file lives in a root-owned folder, so the
    /// app can rewrite the existing file but cannot create a replacement file.
    func save() throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(self.sanitized())
        try data.write(to: URL(fileURLWithPath: BKPaths.config), options: [])
    }
}

// MARK: - Status (written by the daemon, read by the app)

struct BKStatus: Codable {
    var updated: Double = 0              // epoch seconds
    var daemonVersion: String = bkVersion
    var method: String = "none"          // human-readable control method
    var canInhibit: Bool = false         // can stop charging while staying on charger power
    var canCutAdapter: Bool = false      // can disconnect the charger in software
    var chargingAllowed: Bool = true
    var adapterEnabled: Bool = true
    var mode: String = "Starting…"
    var detail: String = ""
    var lastError: String? = nil
    var keys: [String: String] = [:]
    var batteryTempC: Double? = nil      // from the SMC sensors, more reliable than ioreg
    var topApps: [AppUse]? = nil         // apps using the most power right now (estimate)

    static func load() -> BKStatus? {
        guard let data = FileManager.default.contents(atPath: BKPaths.status) else { return nil }
        return try? JSONDecoder().decode(BKStatus.self, from: data)
    }
}

// MARK: - History

struct AppUse: Codable, Hashable {
    var name: String
    var watts: Double          // estimated share of system power
}

/// One history row, saved every 2 minutes by the service.
/// Older rows only have the first five columns; the rest are optional.
struct HistorySample: Identifiable {
    var t: Double
    var pct: Int
    var temp: Double
    var watts: Double          // battery power (+ charging, - discharging)
    var charging: Bool
    var health: Double? = nil
    var cycles: Double? = nil
    var voltage: Double? = nil
    var capacity: Double? = nil    // mAh it can hold now
    var inW: Double? = nil         // power pulled from the charger
    var loadW: Double? = nil       // whole-system power use
    var apps: [AppUse] = []

    var id: Double { t }
    var date: Date { Date(timeIntervalSince1970: t) }

    var csvLine: String {
        func f(_ v: Double?, _ fmt: String) -> String { v.map { String(format: fmt, $0) } ?? "" }
        let appText = apps.map { "\(HistorySample.clean($0.name)):\(String(format: "%.2f", $0.watts))" }
            .joined(separator: "|")
        return [String(format: "%.0f", t), "\(pct)", String(format: "%.1f", temp),
                String(format: "%.2f", watts), charging ? "1" : "0",
                f(health, "%.1f"), f(cycles, "%.0f"), f(voltage, "%.3f"), f(capacity, "%.0f"),
                f(inW, "%.2f"), f(loadW, "%.2f"), appText].joined(separator: ",")
    }

    static func clean(_ s: String) -> String {
        String(s.map { ",|:\n".contains($0) ? " " : $0 })
    }

    init(t: Double, pct: Int, temp: Double, watts: Double, charging: Bool) {
        self.t = t; self.pct = pct; self.temp = temp; self.watts = watts; self.charging = charging
    }

    init?(csv: Substring) {
        let p = csv.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard p.count >= 5,
              let t = Double(p[0]), let pct = Int(p[1]),
              let temp = Double(p[2]), let w = Double(p[3]) else { return nil }
        self.init(t: t, pct: pct, temp: temp, watts: w, charging: p[4] == "1")
        func d(_ i: Int) -> Double? { i < p.count ? Double(p[i]) : nil }
        health = d(5); cycles = d(6); voltage = d(7); capacity = d(8); inW = d(9); loadW = d(10)
        if p.count > 11, !p[11].isEmpty {
            apps = p[11].split(separator: "|").compactMap { item in
                let parts = item.split(separator: ":")
                guard parts.count == 2, let w = Double(parts[1]) else { return nil }
                return AppUse(name: String(parts[0]), watts: w)
            }
        }
    }

    static func loadAll(since: Double = 0) -> [HistorySample] {
        guard let data = FileManager.default.contents(atPath: BKPaths.history),
              let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { HistorySample(csv: $0) }.filter { $0.t >= since }
    }
}

// MARK: - Battery readings (no root needed)

struct BatterySnapshot {
    var percent: Int = 0
    var isCharging: Bool = false
    var externalConnected: Bool = false
    var fullyCharged: Bool = false
    var cycleCount: Int = 0
    var designCapacity: Int = 0     // mAh
    var maxCapacity: Int = 0        // mAh (current full-charge capacity)
    var currentCapacity: Int = 0    // mAh
    var temperatureC: Double = 0
    var voltageV: Double = 0
    var amperageA: Double = 0       // + charging, - discharging
    var adapterWatts: Int? = nil
    var adapterName: String? = nil
    var timeRemainingMin: Int? = nil
    var systemInW: Double? = nil    // power coming in from the charger
    var systemLoadW: Double? = nil  // power the whole Mac is using

    var healthPercent: Double {
        guard designCapacity > 0 else { return 0 }
        return min(100, Double(maxCapacity) / Double(designCapacity) * 100)
    }

    var batteryWatts: Double { voltageV * amperageA }

    static func read() -> BatterySnapshot? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = props?.takeRetainedValue() as? [String: Any] else { return nil }
        let nested = dict["BatteryData"] as? [String: Any] ?? [:]

        // Looks in the top level first, then inside BatteryData (newer macOS moved keys there).
        func int(_ keys: String...) -> Int? {
            for k in keys {
                if let n = dict[k] as? NSNumber { return Int(truncatingIfNeeded: n.int64Value) }
            }
            for k in keys {
                if let n = nested[k] as? NSNumber { return Int(truncatingIfNeeded: n.int64Value) }
            }
            return nil
        }
        func bool(_ k: String) -> Bool { (dict[k] as? NSNumber)?.boolValue ?? false }

        var s = BatterySnapshot()
        s.percent = min(100, max(0, int("CurrentCapacity", "UISoc", "StateOfCharge") ?? 0))
        s.isCharging = bool("IsCharging")
        s.externalConnected = bool("ExternalConnected")
        s.fullyCharged = bool("FullyCharged")
        s.cycleCount = int("CycleCount") ?? 0
        s.designCapacity = int("DesignCapacity") ?? 0
        let rawMax = int("AppleRawMaxCapacity", "NominalChargeCapacity", "FccComp1") ?? 0
        s.maxCapacity = rawMax > 200 ? rawMax : 0   // values <= 200 are percentages, not mAh
        s.currentCapacity = int("AppleRawCurrentCapacity") ?? 0

        if let raw = int("Temperature", "VirtualTemperature") {
            s.temperatureC = BatterySnapshot.decodeTemperature(raw)
        }
        s.voltageV = Double(int("Voltage", "AppleRawBatteryVoltage") ?? 0) / 1000.0
        let amps = int("InstantAmperage", "Amperage") ?? 0
        s.amperageA = Double(Int32(truncatingIfNeeded: amps)) / 1000.0

        if let adapter = dict["AdapterDetails"] as? [String: Any] {
            if let w = (adapter["Watts"] as? NSNumber)?.intValue, w > 0 { s.adapterWatts = w }
            s.adapterName = (adapter["Name"] as? String) ?? (adapter["Description"] as? String)
        }

        let t = s.isCharging ? int("AvgTimeToFull", "TimeRemaining") : int("AvgTimeToEmpty", "TimeRemaining")
        if let t, t > 0, t < 65535 { s.timeRemainingMin = t }

        if let tel = dict["PowerTelemetryData"] as? [String: Any] {
            if let v = (tel["SystemPowerIn"] as? NSNumber)?.int64Value, v >= 0, v < 500_000 { s.systemInW = Double(v) / 1000 }
            if let v = (tel["SystemLoad"] as? NSNumber)?.int64Value, v > 0, v < 500_000 { s.systemLoadW = Double(v) / 1000 }
        }
        return s
    }

    /// Battery temperature arrives as hundredths of °C, or on some firmware as tenths of Kelvin.
    static func decodeTemperature(_ raw: Int) -> Double {
        let centi = Double(raw) / 100.0
        if centi > 5 && centi < 90 { return centi }
        let deciK = Double(raw) / 10.0 - 273.15
        if deciK > 5 && deciK < 90 { return deciK }
        return 0
    }

    var temperatureValid: Bool { temperatureC > 5 && temperatureC < 90 }
    var healthValid: Bool { designCapacity > 0 && maxCapacity > 0 }
}
