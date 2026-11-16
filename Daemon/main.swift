import Foundation
import IOKit
import IOKit.pwr_mgt
import IOKit.ps

// batterykitd — root LaunchDaemon that enforces BatteryKit's charge limit.
// Starts at boot, restarts if it ever dies, re-applies its settings every 10 s.

func bklog(_ s: String) {
    let f = ISO8601DateFormatter()
    print("[\(f.string(from: Date()))] \(s)")
    fflush(stdout)
}

enum InhibitMethod { case chte, ch0c(alsoCH0B: Bool), none }
enum CutMethod { case chie, ch0i, none }

final class Controller {
    var smc: SMC?
    var inhibit: InhibitMethod = .none
    var cut: CutMethod = .none
    var keyReport: [String: String] = [:]
    var smcOpenError: String?

    var cfg = BKConfig()
    var holding = false
    var hot = false
    var adapterCutByUs = false
    var lastHistory: Double = 0
    var lastTrim: Double = 0
    var lastProbe: Double = 0
    var lastError: String?
    var topApps: [AppUse] = []
    var appsSampling = false
    var lastAppsSample: Double = 0
    var scheduledWake: Date?
    var wasExternal = false
    var pluggedSince: Double = 0

    var hasInhibit: Bool { if case .none = inhibit { return false }; return true }
    var hasCut: Bool { if case .none = cut { return false }; return true }

    var methodName: String {
        switch inhibit {
        case .chte: return hasCut ? "Charge inhibit (CHTE) + adapter cutoff" : "Charge inhibit (CHTE)"
        case .ch0c: return hasCut ? "Charge inhibit (CH0C) + adapter cutoff" : "Charge inhibit (CH0C)"
        case .none:
            switch cut {
            case .chie: return "Adapter cutoff (CHIE)"
            case .ch0i: return "Adapter cutoff (CH0I)"
            case .none: return "None available"
            }
        }
    }

    init() {
        do { smc = try SMC() } catch { smc = nil; smcOpenError = "\(error)" }
        probe()
    }

    // MARK: Probe which SMC controls this firmware still allows

    func probe() {
        lastProbe = Date().timeIntervalSince1970
        keyReport = [:]
        inhibit = .none
        cut = .none
        guard let smc else {
            bklog("SMC unavailable: \(smcOpenError ?? "unknown")")
            return
        }

        for k in ["CHTE", "CH0B", "CH0C", "CH0I", "CHIE", "CH0J"] {
            if let info = smc.keyInfo(k) {
                let val = (try? smc.read(k))?.hex ?? "unreadable"
                keyReport[k] = "size \(info.size), type \(info.type), value \(val)"
            } else {
                keyReport[k] = "missing"
            }
        }

        // A key counts as usable only if it has the expected size and accepts a
        // write of its own current value (a no-op that proves write access).
        func writable(_ k: String, size: Int) -> Bool {
            guard let info = smc.keyInfo(k), info.size == size, let cur = try? smc.read(k) else { return false }
            do {
                try smc.write(k, cur)
                return true
            } catch {
                keyReport[k, default: ""] += " — write blocked (\(error))"
                return false
            }
        }

        if writable("CHTE", size: 4) {
            inhibit = .chte
        } else if writable("CH0C", size: 1) {
            inhibit = .ch0c(alsoCH0B: writable("CH0B", size: 1))
        }
        if writable("CHIE", size: 1) {
            cut = .chie
        } else if writable("CH0I", size: 1) {
            cut = .ch0i
        }
        bklog("Probe: method = \(methodName)")
        for (k, v) in keyReport.sorted(by: { $0.key < $1.key }) { bklog("  \(k): \(v)") }
    }

    // MARK: Hardware actions

    func setCharging(_ allowed: Bool) throws {
        guard let smc else { return }
        switch inhibit {
        case .chte:
            try smc.ensure("CHTE", allowed ? [0, 0, 0, 0] : [1, 0, 0, 0])
        case .ch0c(let alsoB):
            try smc.ensure("CH0C", [allowed ? 0x00 : 0x02])
            if alsoB { try smc.ensure("CH0B", [allowed ? 0x00 : 0x02]) }
        case .none:
            break
        }
    }

    func setAdapter(_ on: Bool) throws {
        guard let smc else { return }
        switch cut {
        case .chie: try smc.ensure("CHIE", [on ? 0x00 : 0x08])
        case .ch0i: try smc.ensure("CH0I", [on ? 0x00 : 0x01])
        case .none: break
        }
    }

    func smcBatteryTemp() -> Double? { smc?.batteryTemp() }

    /// Which apps use the most power (estimate), refreshed every 30 s for history.
    func sampleTopApps(systemLoadW: Double?) {
        guard !appsSampling else { return }
        appsSampling = true
        let sysW = smc?.livePower().systemW ?? systemLoadW
        DispatchQueue.global(qos: .utility).async {
            let result = AppPowerSampler.sample(systemW: sysW)
            DispatchQueue.main.async {
                self.topApps = result
                self.appsSampling = false
            }
        }
    }

    func restoreNormal() {
        try? setCharging(true)
        try? setAdapter(true)
        adapterCutByUs = false
    }

    // Never sleep with the charger cut off, or the battery drains overnight.
    /// Sleep handling, so the limit holds overnight:
    /// - If the charger is cut (holding at the limit), it stays cut while asleep.
    ///   A sleeping Mac only uses ~1–2% overnight; below 20% it's reconnected to be safe.
    /// - If it's still charging below the limit, schedule a wake for about when it
    ///   reaches the limit, so the service can stop charging instead of going to 100%.
    func prepareForSleep() {
        guard let b = BatterySnapshot.read() else { return }

        if adapterCutByUs && b.percent <= 20 {
            try? setAdapter(true)
            adapterCutByUs = false
            bklog("Sleep: battery low, charger reconnected")
        } else if adapterCutByUs {
            bklog("Sleep: keeping charger cut at \(b.percent)%")
        }

        if cfg.enabled && !cfg.topUp && b.isCharging && b.percent < cfg.limit && b.amperageA > 0.05 {
            let mAhNeeded = Double(cfg.limit - b.percent) / 100 * Double(max(b.maxCapacity, 3000))
            let minutes = min(240, max(5, mAhNeeded / (b.amperageA * 1000) * 60 * 0.9))
            let when = Date().addingTimeInterval(minutes * 60)
            cancelScheduledWake()
            let r = IOPMSchedulePowerEvent(when as CFDate, "com.batterykit.daemon" as CFString, "wake" as CFString)
            if r == kIOReturnSuccess {
                scheduledWake = when
                bklog(String(format: "Sleep: charging, wake scheduled in %.0f min to stop at %d%%", minutes, cfg.limit))
            } else {
                bklog("Sleep: could not schedule wake (\(r))")
            }
        }
    }

    func cancelScheduledWake() {
        if let w = scheduledWake {
            IOPMCancelScheduledPowerEvent(w as CFDate, "com.batterykit.daemon" as CFString, "wake" as CFString)
            scheduledWake = nil
        }
    }

    func didWake() {
        cancelScheduledWake()
        tick()
        // Still charging below the limit and the Mac goes back to sleep? prepareForSleep schedules the next check.
    }

    func shutdown() {
        bklog("Stopping — restoring normal charging")
        restoreNormal()
        var st = BKStatus()
        st.updated = Date().timeIntervalSince1970
        st.method = methodName
        st.mode = "Stopped"
        st.detail = "Background service is not running"
        writeStatus(st)
    }

    // MARK: Main loop

    func tick() {
        let now = Date().timeIntervalSince1970
        if !hasInhibit && !hasCut && now - lastProbe > 600 { probe() }

        if let c = BKConfig.load() {
            cfg = c
        } else {
            try? cfg.save()
            ensurePermissions()
        }

        var st = BKStatus()
        st.updated = now
        st.method = methodName
        st.canInhibit = hasInhibit
        st.canCutAdapter = hasCut
        st.keys = keyReport
        st.topApps = topApps

        guard let b = BatterySnapshot.read() else {
            st.mode = "No battery data"
            writeStatus(st)
            return
        }

        if b.externalConnected && !wasExternal { pluggedSince = now }
        let tempC = smcBatteryTemp() ?? (b.temperatureValid ? b.temperatureC : 0)
        st.batteryTempC = tempC > 0 ? tempC : nil

        var allow = true
        var adapterOn = true
        var mode = ""
        var detail = ""
        let gap = hasInhibit ? cfg.sailingGap : max(3, cfg.sailingGap)
        let pluggedIn = b.externalConnected || adapterCutByUs

        if !hasInhibit && !hasCut {
            mode = "Monitoring only"
            detail = "This macOS version blocks charge control. Analytics still work."
            holding = false; hot = false
        } else if !cfg.enabled {
            mode = "Limiter off"
            detail = "Charging normally to 100%"
            holding = false; hot = false
        } else if cfg.topUp {
            if b.percent >= 100 || b.fullyCharged {
                cfg.topUp = false
                try? cfg.save()
                bklog("Top-up finished")
            } else {
                mode = "Topping up to 100%"
                detail = "Goes back to the \(cfg.limit)% limit afterwards"
                holding = false; hot = false
            }
        }

        if (hasInhibit || hasCut) && cfg.enabled && !cfg.topUp {
            if cfg.heatProtection && tempC > 0 {
                if tempC >= cfg.maxTempC { hot = true }
                else if tempC <= cfg.maxTempC - 2 { hot = false }
            } else {
                hot = false
            }

            // Plugging the charger in always charges up to the limit (the recharge gap
            // only applies while it stays plugged in).
            if b.externalConnected && !wasExternal && !adapterCutByUs { holding = false }

            if b.percent >= cfg.limit { holding = true }
            else if b.percent <= cfg.limit - gap { holding = false }

            allow = !holding && !hot

            if cfg.dischargeToLimit && hasCut && b.percent > cfg.limit && pluggedIn {
                adapterOn = false
            }
            // Without an inhibit key, the only way to stop charging is to cut the charger.
            if !allow && !hasInhibit && pluggedIn {
                adapterOn = false
            }
        }

        // Safety floor: never run the battery down below 10% on our own.
        if b.percent <= 10 {
            allow = true
            adapterOn = true
        }

        do {
            try setCharging(allow)
            try setAdapter(adapterOn)
            adapterCutByUs = hasCut && !adapterOn
            if lastError != nil { bklog("Recovered") }
            lastError = nil
        } catch {
            if lastError != "\(error)" { bklog("Apply failed: \(error)") }
            lastError = "\(error)"
        }

        if mode.isEmpty {
            if !adapterOn && cfg.dischargeToLimit && b.percent > cfg.limit {
                mode = "Draining to \(cfg.limit)%"
                detail = "Charger disconnected in software, running on battery"
            } else if !pluggedIn {
                mode = "On battery"
                detail = "Limit \(cfg.limit)%"
            } else if hot {
                mode = "Paused — battery hot"
                detail = String(format: "%.1f°C · resumes below %.0f°C", tempC, cfg.maxTempC - 2)
            } else if holding {
                if hasInhibit {
                    mode = "Holding at \(cfg.limit)%"
                    detail = "Mac runs on charger power. Recharges below \(cfg.limit - gap)%"
                } else {
                    mode = "Sailing"
                    detail = "On battery until \(cfg.limit - gap)%, then charges back to \(cfg.limit)%"
                }
            } else if b.isCharging {
                mode = "Charging to \(cfg.limit)%"
            } else if allow && adapterOn && b.externalConnected && b.percent < cfg.limit && b.percent < 99 {
                if now - pluggedSince < 180 {
                    mode = "Starting to charge…"
                    detail = "macOS can take a minute or two to start charging after you plug in"
                } else {
                    mode = "Not charging"
                    detail = "Check the charger (it needs enough watts) and that Optimized Battery Charging is off"
                }
            } else {
                mode = "Plugged in"
                detail = "Limit \(cfg.limit)%"
            }
        }

        st.chargingAllowed = allow
        st.adapterEnabled = adapterOn
        wasExternal = b.externalConnected
        st.mode = mode
        st.detail = detail
        st.lastError = lastError
        writeStatus(st)

        if now - lastHistory >= 120 {
            lastHistory = now
            var h = HistorySample(t: now, pct: b.percent, temp: tempC,
                                  watts: b.batteryWatts, charging: b.isCharging)
            h.health = b.healthValid ? b.healthPercent : nil
            h.cycles = Double(b.cycleCount)
            h.voltage = b.voltageV > 0 ? b.voltageV : nil
            h.capacity = b.maxCapacity > 0 ? Double(b.maxCapacity) : nil
            let live = smc?.livePower()
            h.inW = live?.inW ?? b.systemInW
            h.loadW = live?.systemW ?? b.systemLoadW
            h.apps = topApps
            appendHistory(h)
        }
        if now - lastAppsSample >= 30 {
            lastAppsSample = now
            sampleTopApps(systemLoadW: b.systemLoadW)
        }
        if now - lastTrim >= 3600 {
            lastTrim = now
            trimHistory()
        }
    }

    // MARK: Files

    func ensurePermissions() {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: BKPaths.dir, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o755])
        if !fm.fileExists(atPath: BKPaths.config) { try? BKConfig().save() }
        // Only admin accounts may change charging settings (the menu bar app runs as the user).
        try? fm.setAttributes([.posixPermissions: 0o664, .ownerAccountName: "root",
                               .groupOwnerAccountName: "admin"], ofItemAtPath: BKPaths.config)
    }

    func writeStatus(_ st: BKStatus) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(st) else { return }
        try? data.write(to: URL(fileURLWithPath: BKPaths.status), options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: BKPaths.status)
    }

    func appendHistory(_ s: HistorySample) {
        let line = s.csvLine + "\n"
        guard let data = line.data(using: .utf8) else { return }
        if let h = FileHandle(forWritingAtPath: BKPaths.history) {
            h.seekToEndOfFile()
            h.write(data)
            h.closeFile()
        } else {
            FileManager.default.createFile(atPath: BKPaths.history, contents: data,
                                           attributes: [.posixPermissions: 0o644])
        }
    }

    func trimHistory() {
        let cutoff = Date().timeIntervalSince1970 - 7 * 24 * 3600
        let kept = HistorySample.loadAll(since: cutoff)
        let text = kept.map { $0.csvLine }.joined(separator: "\n") + (kept.isEmpty ? "" : "\n")
        try? text.data(using: .utf8)?.write(to: URL(fileURLWithPath: BKPaths.history), options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: BKPaths.history)
    }
}

// MARK: - Command line

let args = CommandLine.arguments
if args.count > 1 {
    switch args[1] {
    case "probe":
        guard getuid() == 0 else { print("Run with sudo: sudo batterykitd probe"); exit(1) }
        let c = Controller()
        print("BatteryKit \(bkVersion) — SMC probe")
        if let e = c.smcOpenError { print("SMC error: \(e)") }
        for (k, v) in c.keyReport.sorted(by: { $0.key < $1.key }) { print("  \(k): \(v)") }
        print("Control method: \(c.methodName)")
    case "status":
        print((try? String(contentsOfFile: BKPaths.status, encoding: .utf8)) ?? "No status file yet")
    case "release":
        guard getuid() == 0 else { print("Run with sudo"); exit(1) }
        Controller().restoreNormal()
        print("Normal charging restored (the service will re-apply your limit on its next cycle if still running).")
    case "version":
        print(bkVersion)
    default:
        print("Usage: batterykitd [probe|status|release|version]")
    }
    exit(0)
}

// MARK: - Daemon

guard getuid() == 0 else {
    print("batterykitd must run as root (it is started by launchd).")
    exit(1)
}

bklog("batterykitd \(bkVersion) starting")
var gController = Controller()
gController.ensurePermissions()

// Sleep / wake handling
var gRootPort: io_connect_t = 0
var gNotifyPort: IONotificationPortRef?
var gNotifier: io_object_t = 0
let msgCanSleep: UInt32 = 0xE0000270
let msgWillSleep: UInt32 = 0xE0000280
let msgPoweredOn: UInt32 = 0xE0000300

let powerCallback: IOServiceInterestCallback = { _, _, messageType, messageArgument in
    switch messageType {
    case msgCanSleep:
        IOAllowPowerChange(gRootPort, Int(bitPattern: messageArgument))
    case msgWillSleep:
        gController.prepareForSleep()
        IOAllowPowerChange(gRootPort, Int(bitPattern: messageArgument))
    case msgPoweredOn:
        bklog("Wake")
        gController.tick()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { gController.didWake() }
    default:
        break
    }
}

gRootPort = IORegisterForSystemPower(nil, &gNotifyPort, powerCallback, &gNotifier)
if gRootPort != 0, let port = gNotifyPort {
    CFRunLoopAddSource(CFRunLoopGetMain(),
                       IONotificationPortGetRunLoopSource(port).takeUnretainedValue(),
                       .defaultMode)
} else {
    bklog("Warning: could not register for sleep notifications")
}

// React within a second when the charger is plugged in or pulled out.
let psCallback: IOPowerSourceCallbackType = { _ in
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { gController.tick() }
}
if let src = IOPSNotificationCreateRunLoopSource(psCallback, nil)?.takeRetainedValue() {
    CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
}

// Clean exit: always hand charging back to macOS.
signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)
var gSignalSources: [DispatchSourceSignal] = []
for sig in [SIGTERM, SIGINT] {
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    src.setEventHandler {
        gController.shutdown()
        exit(0)
    }
    src.resume()
    gSignalSources.append(src)
}

gController.tick()
let gTimer = Timer(timeInterval: 10, repeats: true) { _ in gController.tick() }
RunLoop.main.add(gTimer, forMode: .common)
RunLoop.main.run()
