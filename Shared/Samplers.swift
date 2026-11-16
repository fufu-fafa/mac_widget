import Foundation
import Darwin
import IOKit
import IOKit.ps

private let machHost = mach_host_self()

// MARK: - CPU

struct CPUSample {
    var user: Double = 0      // 0...1, includes "nice"
    var system: Double = 0    // 0...1
    var perCore: [Double] = []
    var total: Double { user + system }
}

final class CPUSampler {
    private typealias Ticks = (user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)
    private var prev: [Ticks] = []

    func sample() -> CPUSample? {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(machHost, PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount) == KERN_SUCCESS,
              let info else { return nil }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }

        var cur: [Ticks] = []
        cur.reserveCapacity(Int(cpuCount))
        for i in 0..<Int(cpuCount) {
            let base = Int(CPU_STATE_MAX) * i
            cur.append((UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]),
                        UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]),
                        UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]),
                        UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)])))
        }
        defer { prev = cur }
        guard prev.count == cur.count else { return nil }

        var sumUser = 0.0, sumSys = 0.0, sumAll = 0.0
        var perCore: [Double] = []
        for (c, p) in zip(cur, prev) {
            let u = Double(c.user &- p.user) + Double(c.nice &- p.nice)
            let s = Double(c.system &- p.system)
            let all = u + s + Double(c.idle &- p.idle)
            perCore.append(all > 0 ? (u + s) / all : 0)
            sumUser += u; sumSys += s; sumAll += all
        }
        guard sumAll > 0 else { return nil }
        return CPUSample(user: sumUser / sumAll, system: sumSys / sumAll, perCore: perCore)
    }
}

func loadAverages() -> [Double] {
    var l = [Double](repeating: 0, count: 3)
    getloadavg(&l, 3)
    return l
}

// MARK: - Memory

struct MemSample {
    var total: UInt64
    var app: UInt64
    var wired: UInt64
    var compressed: UInt64
    var cached: UInt64
    var swapUsed: UInt64
    var pressure: Int   // 1 normal, 2 warning, 4 critical
    var used: UInt64 { app + wired + compressed }
    var fraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
}

func sampleMemory() -> MemSample? {
    var stats = vm_statistics64()
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
    let kr = withUnsafeMutablePointer(to: &stats) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            host_statistics64(machHost, HOST_VM_INFO64, $0, &count)
        }
    }
    guard kr == KERN_SUCCESS else { return nil }
    var pageSize: vm_size_t = 0
    host_page_size(machHost, &pageSize)
    let page = UInt64(pageSize)

    // Same breakdown Activity Monitor uses: Used = App + Wired + Compressed.
    let purgeable = UInt64(stats.purgeable_count)
    let app = (UInt64(stats.internal_page_count) &- purgeable) * page
    let cached = (UInt64(stats.external_page_count) + purgeable) * page

    var swap = xsw_usage()
    var swapSize = MemoryLayout<xsw_usage>.size
    sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0)

    var pressure: Int32 = 1
    var pSize = MemoryLayout<Int32>.size
    sysctlbyname("kern.memorystatus_vm_pressure_level", &pressure, &pSize, nil, 0)

    return MemSample(total: ProcessInfo.processInfo.physicalMemory,
                     app: app,
                     wired: UInt64(stats.wire_count) * page,
                     compressed: UInt64(stats.compressor_page_count) * page,
                     cached: cached,
                     swapUsed: swap.xsu_used,
                     pressure: Int(pressure))
}

// MARK: - Network

final class NetSampler {
    private var prev: [String: (rx: UInt32, tx: UInt32)] = [:]
    private var prevTime = Date()
    private(set) var totalDown: UInt64 = 0   // since launch
    private(set) var totalUp: UInt64 = 0

    /// Bytes per second since the previous call.
    func sample() -> (down: Double, up: Double) {
        var cur: [String: (rx: UInt32, tx: UInt32)] = [:]
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0 else { return (0, 0) }
        defer { freeifaddrs(addrs) }
        var p = addrs
        while let ifa = p {
            defer { p = ifa.pointee.ifa_next }
            guard let addr = ifa.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK),
                  let data = ifa.pointee.ifa_data else { continue }
            let name = String(cString: ifa.pointee.ifa_name)
            // Physical interfaces only, so VPN/loopback traffic isn't counted twice.
            guard name.hasPrefix("en") || name.hasPrefix("pdp_ip") else { continue }
            let d = data.assumingMemoryBound(to: if_data.self).pointee
            cur[name] = (d.ifi_ibytes, d.ifi_obytes)
        }

        let now = Date()
        let dt = max(now.timeIntervalSince(prevTime), 0.001)
        var dRx: UInt64 = 0, dTx: UInt64 = 0
        for (name, c) in cur {
            guard let pr = prev[name] else { continue }
            dRx += UInt64(c.rx &- pr.rx)   // counters are 32-bit and wrap
            dTx += UInt64(c.tx &- pr.tx)
        }
        let first = prev.isEmpty
        prev = cur
        prevTime = now
        if first { return (0, 0) }
        totalDown += dRx
        totalUp += dTx
        return (Double(dRx) / dt, Double(dTx) / dt)
    }
}

// MARK: - Disk

struct DiskSpace {
    var total: UInt64
    var free: UInt64
    var used: UInt64 { total > free ? total - free : 0 }
    var fraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
}

func sampleDiskSpace() -> DiskSpace? {
    let url = URL(fileURLWithPath: "/")
    guard let v = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]),
          let total = v.volumeTotalCapacity, let free = v.volumeAvailableCapacityForImportantUsage else { return nil }
    return DiskSpace(total: UInt64(total), free: UInt64(max(free, 0)))
}

final class DiskIOSampler {
    private var prev: (read: UInt64, write: UInt64)?
    private var prevTime = Date()

    private func counters() -> (read: UInt64, write: UInt64) {
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iter) == KERN_SUCCESS else { return (0, 0) }
        defer { IOObjectRelease(iter) }
        var r: UInt64 = 0, w: UInt64 = 0
        while case let svc = IOIteratorNext(iter), svc != 0 {
            defer { IOObjectRelease(svc) }
            guard let stats = IORegistryEntryCreateCFProperty(svc, "Statistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any] else { continue }
            r += (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
            w += (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
        }
        return (r, w)
    }

    /// Bytes per second since the previous call.
    func sample() -> (read: Double, write: Double) {
        let cur = counters()
        let now = Date()
        let dt = max(now.timeIntervalSince(prevTime), 0.001)
        defer { prev = cur; prevTime = now }
        guard let p = prev, cur.read >= p.read, cur.write >= p.write else { return (0, 0) }
        return (Double(cur.read - p.read) / dt, Double(cur.write - p.write) / dt)
    }
}

// MARK: - Processes

struct ProcInfo: Identifiable {
    let id: Int
    var name: String
    var cpu: Double      // percent of one core
    var memBytes: UInt64
}

func sampleTopProcesses(limit: Int) -> [ProcInfo] {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/ps")
    task.arguments = ["-Aceo", "pcpu,rss,comm", "-r"]
    task.environment = ["LC_ALL": "C"]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = FileHandle.nullDevice
    guard (try? task.run()) != nil else { return [] }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    guard let out = String(data: data, encoding: .utf8) else { return [] }

    var result: [ProcInfo] = []
    for line in out.split(separator: "\n").dropFirst() {
        let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count == 3, let cpu = Double(parts[0]), let rssKB = UInt64(parts[1]) else { continue }
        let name = parts[2].trimmingCharacters(in: .whitespaces)
        if name == "ps" { continue }
        result.append(ProcInfo(id: result.count, name: name, cpu: cpu, memBytes: rssKB * 1024))
        if result.count == limit { break }
    }
    return result
}

// MARK: - System

struct BatteryInfo {
    var percent: Int
    var charging: Bool
    var onAC: Bool
}

func sampleBattery() -> BatteryInfo? {
    guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
    for ps in list {
        guard let d = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any],
              (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType,
              let cur = d[kIOPSCurrentCapacityKey] as? Int,
              let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
        return BatteryInfo(percent: Int((Double(cur) / Double(max) * 100).rounded()),
                           charging: (d[kIOPSIsChargingKey] as? Bool) ?? false,
                           onAC: (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue)
    }
    return nil
}

func systemUptime() -> TimeInterval {
    var tv = timeval()
    var size = MemoryLayout<timeval>.size
    guard sysctlbyname("kern.boottime", &tv, &size, nil, 0) == 0 else { return ProcessInfo.processInfo.systemUptime }
    return Date().timeIntervalSince1970 - Double(tv.tv_sec)
}
