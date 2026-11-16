import Foundation
import IOKit

/// Flat mirror of AppleSMC's 80-byte SMCKeyData_t struct.
/// Kept flat with explicit padding so Swift lays it out exactly like the C struct.
struct SMCParam {
    var key: UInt32 = 0              // 0
    var versMajor: UInt8 = 0         // 4
    var versMinor: UInt8 = 0         // 5
    var versBuild: UInt8 = 0         // 6
    var versReserved: UInt8 = 0      // 7
    var versRelease: UInt16 = 0      // 8
    var pad0: UInt16 = 0             // 10
    var pLimitVersion: UInt16 = 0    // 12
    var pLimitLength: UInt16 = 0     // 14
    var cpuPLimit: UInt32 = 0        // 16
    var gpuPLimit: UInt32 = 0        // 20
    var memPLimit: UInt32 = 0        // 24
    var dataSize: UInt32 = 0         // 28
    var dataType: UInt32 = 0         // 32
    var dataAttributes: UInt8 = 0    // 36
    var pad1: UInt8 = 0              // 37
    var pad2: UInt8 = 0              // 38
    var pad3: UInt8 = 0              // 39
    var result: UInt8 = 0            // 40
    var status: UInt8 = 0            // 41
    var data8: UInt8 = 0             // 42
    var pad4: UInt8 = 0              // 43
    var data32: UInt32 = 0           // 44
    var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
        (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
         0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0) // 48..80
}

enum SMCError: Error, CustomStringConvertible {
    case notOpen
    case kern(String, kern_return_t)
    case smc(String, UInt8)
    case keyMissing(String)
    case sizeMismatch(String, expected: Int, got: Int)

    var description: String {
        switch self {
        case .notOpen: return "SMC connection not open (daemon must run as root)"
        case let .kern(k, kr): return "\(k): IOKit error 0x\(String(UInt32(bitPattern: kr), radix: 16))"
        case let .smc(k, r): return "\(k): SMC result \(r)"
        case let .keyMissing(k): return "\(k): key not present"
        case let .sizeMismatch(k, e, g): return "\(k): expected \(e) bytes, got \(g)"
        }
    }
}

final class SMC {
    private var conn: io_connect_t = 0

    private static let kSMCHandleYPCEvent: UInt32 = 2
    private static let kSMCReadKey: UInt8 = 5
    private static let kSMCWriteKey: UInt8 = 6
    private static let kSMCGetKeyInfo: UInt8 = 9

    struct KeyInfo { let size: Int; let type: String }

    init() throws {
        precondition(MemoryLayout<SMCParam>.size == 80, "SMCParam layout is wrong: \(MemoryLayout<SMCParam>.size)")
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { throw SMCError.notOpen }
        defer { IOObjectRelease(service) }
        let kr = IOServiceOpen(service, mach_task_self_, 0, &conn)
        guard kr == KERN_SUCCESS else { throw SMCError.kern("open", kr) }
    }

    deinit { if conn != 0 { IOServiceClose(conn) } }

    static func fourCC(_ s: String) -> UInt32 {
        s.utf8.prefix(4).reduce(0) { ($0 << 8) | UInt32($1) }
    }

    static func string(_ v: UInt32) -> String {
        let b = [UInt8((v >> 24) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]
        return String(bytes: b, encoding: .ascii) ?? "????"
    }

    private func call(_ input: SMCParam) -> (kern_return_t, SMCParam) {
        var inp = input
        var out = SMCParam()
        var outSize = MemoryLayout<SMCParam>.stride
        let kr = IOConnectCallStructMethod(conn, SMC.kSMCHandleYPCEvent,
                                           &inp, MemoryLayout<SMCParam>.stride,
                                           &out, &outSize)
        return (kr, out)
    }

    /// nil = key does not exist on this firmware.
    func keyInfo(_ key: String) -> KeyInfo? {
        var p = SMCParam()
        p.key = SMC.fourCC(key)
        p.data8 = SMC.kSMCGetKeyInfo
        let (kr, out) = call(p)
        guard kr == KERN_SUCCESS, out.result == 0 else { return nil }
        return KeyInfo(size: Int(out.dataSize), type: SMC.string(out.dataType))
    }

    func read(_ key: String) throws -> [UInt8] {
        guard let info = keyInfo(key) else { throw SMCError.keyMissing(key) }
        guard info.size > 0 else { throw SMCError.sizeMismatch(key, expected: 1, got: 0) }
        var p = SMCParam()
        p.key = SMC.fourCC(key)
        p.dataSize = UInt32(info.size)
        p.data8 = SMC.kSMCReadKey
        let (kr, out) = call(p)
        guard kr == KERN_SUCCESS else { throw SMCError.kern(key, kr) }
        guard out.result == 0 else { throw SMCError.smc(key, out.result) }
        var o = out
        return withUnsafeBytes(of: &o.bytes) { Array($0.prefix(min(info.size, 32))) }
    }

    func write(_ key: String, _ value: [UInt8]) throws {
        guard let info = keyInfo(key) else { throw SMCError.keyMissing(key) }
        guard info.size == value.count else {
            throw SMCError.sizeMismatch(key, expected: info.size, got: value.count)
        }
        var p = SMCParam()
        p.key = SMC.fourCC(key)
        p.dataSize = UInt32(info.size)
        p.data8 = SMC.kSMCWriteKey
        withUnsafeMutableBytes(of: &p.bytes) { buf in
            for (i, b) in value.enumerated() where i < 32 { buf[i] = b }
        }
        let (kr, out) = call(p)
        guard kr == KERN_SUCCESS else { throw SMCError.kern(key, kr) }
        guard out.result == 0 else { throw SMCError.smc(key, out.result) }
    }

    /// Writes only when the current value differs. Returns true if a write happened.
    @discardableResult
    func ensure(_ key: String, _ value: [UInt8]) throws -> Bool {
        if let cur = try? read(key), cur == value { return false }
        try write(key, value)
        return true
    }
}

extension Array where Element == UInt8 {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

// MARK: - Live sensor readings (reading the SMC works without root)

struct LivePower {
    var systemW: Double?     // whole Mac (PSTR)
    var inW: Double?         // coming in from the charger (PDTR)
    var tempC: Double?       // battery temperature (TB0T/TB1T/TB2T)
}

extension SMC {
    /// Reads a numeric SMC key, whatever its encoding.
    func number(_ key: String) -> Double? {
        guard let info = keyInfo(key), let b = try? read(key) else { return nil }
        switch info.type {
        case "flt ":
            guard b.count >= 4 else { return nil }
            let bits = UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
            let v = Double(Float(bitPattern: bits))
            return v.isFinite ? v : nil
        case "sp78":
            guard b.count >= 2 else { return nil }
            return Double(Int16(bitPattern: UInt16(b[0]) << 8 | UInt16(b[1]))) / 256.0
        case "ui8 ":
            return b.first.map { Double($0) }
        case "ui16":
            guard b.count >= 2 else { return nil }
            return Double(UInt16(b[0]) << 8 | UInt16(b[1]))
        case "ui32":
            guard b.count >= 4 else { return nil }
            return Double(UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3]))
        default:
            return nil
        }
    }

    func batteryTemp() -> Double? {
        let vals = ["TB0T", "TB1T", "TB2T"].compactMap { number($0) }.filter { $0 > 5 && $0 < 90 }
        return vals.isEmpty ? nil : vals.reduce(0, +) / Double(vals.count)
    }

    func livePower() -> LivePower {
        var p = LivePower()
        if let v = number("PSTR"), v >= 0, v < 300 { p.systemW = v }
        if let v = number("PDTR"), v >= 0, v < 300 { p.inW = v }
        p.tempC = batteryTemp()
        return p
    }
}

// MARK: - Which apps use the most power

enum AppPowerSampler {
    /// Friendly names for macOS system processes that aren't inside an .app.
    static let friendly: [String: String] = [
        "WindowServer": "WindowServer (draws the screen)",
        "kernel_task": "macOS kernel",
        "mds": "Spotlight",
        "mds_stores": "Spotlight indexing",
        "mdworker_shared": "Spotlight indexing",
        "mdworker": "Spotlight indexing",
        "backupd": "Time Machine",
        "photoanalysisd": "Photos analysis",
        "mediaanalysisd": "Photos analysis",
        "coreaudiod": "Audio system",
        "bluetoothd": "Bluetooth",
        "cloudd": "iCloud",
        "bird": "iCloud Drive",
        "softwareupdated": "Software Update",
        "corespotlightd": "Spotlight",
        "trustd": "macOS security",
        "syspolicyd": "macOS security",
        "XprotectService": "macOS security",
        "launchd": "macOS launchd",
        "logd": "macOS logging",
        "powerd": "macOS power management",
        "batterykitd": "BatteryKit service",
        "VTDecoderXPCService": "Video decoding",
        "com.apple.WebKit.WebContent": "Safari / web content",
        "com.apple.WebKit.GPU": "Safari / web content",
    ]

    /// Turns an executable path into an app name. Helper processes inside an
    /// app bundle (e.g. "Brave Browser Helper (Renderer)") count as the app.
    static func appName(fromPath path: String) -> String {
        let comps = path.split(separator: "/")
        if let app = comps.first(where: { $0.hasSuffix(".app") }) {
            return String(app.dropLast(4))
        }
        let base = comps.last.map(String.init) ?? path
        return friendly[base] ?? base
    }

    /// Only real apps the user opened: no macOS background processes.
    /// Helpers inside an app bundle (e.g. Brave's renderers) count as that app.
    static func userAppName(fromPath path: String) -> String? {
        if path.contains("com.apple.WebKit") { return "Safari" }
        let systemPrefixes = ["/System/Library/", "/usr/", "/Library/Apple/", "/sbin/", "/bin/"]
        if systemPrefixes.contains(where: { path.hasPrefix($0) }) { return nil }
        let comps = path.split(separator: "/")
        guard let app = comps.first(where: { $0.hasSuffix(".app") }) else { return nil }
        let name = String(app.dropLast(4))
        return name == "BatteryKit" ? nil : name
    }

    private static func run(_ tool: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// Takes about a second. Call off the main thread.
    static func sample(systemW: Double?) -> [AppUse] {
        // Energy impact per process from top's second sample.
        let topOut = run("/usr/bin/top", ["-l", "2", "-s", "1", "-n", "60", "-o", "power", "-stats", "pid,power"])
        guard let r = topOut.range(of: "PID", options: .backwards) else { return [] }
        var power: [Int: Double] = [:]
        for line in topOut[r.lowerBound...].split(separator: "\n").dropFirst() {
            let parts = line.split(separator: " ")
            guard parts.count >= 2,
                  let pid = Int(parts[0].filter(\.isNumber)),
                  let pw = Double(parts[1]), pw > 0 else { continue }
            power[pid] = pw
        }
        guard !power.isEmpty else { return [] }

        // Full executable paths so helpers can be grouped under their app.
        let pids = power.keys.map(String.init).joined(separator: ",")
        let psOut = run("/bin/ps", ["-o", "pid=,comm=", "-p", pids])
        var byApp: [String: Double] = [:]
        var total = 0.0      // everything, so each app's share of the Mac's power stays realistic
        for line in psOut.split(separator: "\n") {
            let trimmed = line.drop(while: { $0 == " " })
            guard let space = trimmed.firstIndex(of: " "),
                  let pid = Int(trimmed[..<space]),
                  let pw = power[pid] else { continue }
            let path = trimmed[trimmed.index(after: space)...].trimmingCharacters(in: .whitespaces)
            total += pw
            guard let name = userAppName(fromPath: path) else { continue }
            byApp[name, default: 0] += pw
        }

        let load = systemW ?? 0
        return byApp.sorted { $0.value > $1.value }
            .prefix(6)
            .map { AppUse(name: $0.key, watts: total > 0 && load > 0 ? load * $0.value / total : 0) }
    }
}
