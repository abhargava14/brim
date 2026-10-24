import Darwin
import Foundation
import IOKit
import IOKit.ps

/// One reading of this Mac: CPU, memory, disk, network, battery and the busiest processes.
public struct SystemSample: Sendable {
    public var cpuPercent: Double = 0
    public var cores = ProcessInfo.processInfo.activeProcessorCount
    public var loadAverage: Double = 0

    public var memoryTotal = ProcessInfo.processInfo.physicalMemory
    public var memoryApp: UInt64 = 0
    public var memoryWired: UInt64 = 0
    public var memoryCompressed: UInt64 = 0
    public var memoryCached: UInt64 = 0
    public var memoryPressure = "normal"
    public var memoryUsed: UInt64 { memoryApp + memoryWired + memoryCompressed }

    public var diskTotal: Int64 = 0
    public var diskFree: Int64 = 0
    public var diskPurgeable: Int64 = 0

    /// Bytes per second since the previous sample.
    public var netDown: Double = 0
    public var netUp: Double = 0

    public var battery: BatteryInfo?
    public var processes: [ProcessUsage] = []

    public init() {}
}

public struct BatteryInfo: Sendable, Equatable {
    public var percent: Int
    public var charging: Bool
    public var onPower: Bool
    /// Minutes to full while charging, or to empty on battery; nil while macOS is still estimating.
    public var minutesLeft: Int?
    public var healthPercent: Int?
    public var cycles: Int?
    public var temperature: Double?
}

public struct ProcessUsage: Sendable, Identifiable, Equatable {
    public let pid: Int32
    public let name: String
    public let cpuPercent: Double
    public let memory: UInt64
    public var id: Int32 { pid }
}

/// Takes samples; CPU, network and process figures are deltas against the previous call.
public final class SystemMonitor {
    private var lastTicks: [UInt32]?
    private var lastNet: (down: UInt64, up: UInt64, at: Date)?
    private var lastProcTimes: [Int32: UInt64] = [:]
    private var lastProcAt: Date?
    private let timebase: Double

    public init() {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        timebase = Double(info.numer) / Double(max(info.denom, 1))
    }

    /// `processes: false` skips the process scan, the expensive part.
    public func sample(processes: Bool = true) -> SystemSample {
        var sample = SystemSample()
        sample.cpuPercent = cpu()
        var load = [Double](repeating: 0, count: 3)
        if getloadavg(&load, 3) > 0 { sample.loadAverage = load[0] }
        memory(into: &sample)
        disk(into: &sample)
        network(into: &sample)
        sample.battery = Self.battery()
        if processes { sample.processes = topProcesses() }
        return sample
    }

    // MARK: CPU

    private func cpu() -> Double {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info else { return 0 }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride)) }
        let ticks = (0..<Int(infoCount)).map { UInt32(bitPattern: info[$0]) }
        defer { lastTicks = ticks }
        guard let last = lastTicks, last.count == ticks.count else { return 0 }
        var busy: UInt64 = 0, total: UInt64 = 0
        let states = Int(CPU_STATE_MAX)
        for core in 0..<Int(count) {
            for state in 0..<states {
                let index = core * states + state
                let delta = UInt64(ticks[index] &- last[index])
                total += delta
                if state != Int(CPU_STATE_IDLE) { busy += delta }
            }
        }
        return total > 0 ? Double(busy) / Double(total) * 100 : 0
    }

    // MARK: Memory

    private func memory(into sample: inout SystemSample) {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return }
        let page = UInt64(vm_kernel_page_size)
        let internalPages = UInt64(stats.internal_page_count), purgeable = UInt64(stats.purgeable_count)
        sample.memoryApp = (internalPages > purgeable ? internalPages - purgeable : 0) * page
        sample.memoryWired = UInt64(stats.wire_count) * page
        sample.memoryCompressed = UInt64(stats.compressor_page_count) * page
        sample.memoryCached = (UInt64(stats.external_page_count) + purgeable) * page
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 {
            sample.memoryPressure = level >= 4 ? "critical" : level >= 2 ? "warning" : "normal"
        }
    }

    // MARK: Disk

    private func disk(into sample: inout SystemSample) {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys) else { return }
        sample.diskTotal = Int64(values.volumeTotalCapacity ?? 0)
        let plain = Int64(values.volumeAvailableCapacity ?? 0)
        let important = values.volumeAvailableCapacityForImportantUsage ?? plain
        sample.diskFree = important
        sample.diskPurgeable = max(0, important - plain)
    }

    // MARK: Network

    private func network(into sample: inout SystemSample) {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let first = addresses else { return }
        defer { freeifaddrs(addresses) }
        var down: UInt64 = 0, up: UInt64 = 0
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            let name = String(cString: entry.pointee.ifa_name)
            if let addr = entry.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK), !name.hasPrefix("lo"),
               let data = entry.pointee.ifa_data?.assumingMemoryBound(to: if_data.self) {
                down += UInt64(data.pointee.ifi_ibytes)
                up += UInt64(data.pointee.ifi_obytes)
            }
            cursor = entry.pointee.ifa_next
        }
        let now = Date()
        if let last = lastNet {
            let seconds = max(now.timeIntervalSince(last.at), 0.1)
            // 32-bit counters wrap; skip that sample instead of showing a spike.
            sample.netDown = down >= last.down ? Double(down - last.down) / seconds : 0
            sample.netUp = up >= last.up ? Double(up - last.up) / seconds : 0
        }
        lastNet = (down, up, now)
    }

    // MARK: Battery

    public static func battery() -> BatteryInfo? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  (description[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
            let current = description[kIOPSCurrentCapacityKey] as? Int ?? 0
            let max = description[kIOPSMaxCapacityKey] as? Int ?? 100
            let charging = description[kIOPSIsChargingKey] as? Bool ?? false
            let onPower = (description[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            let minutes = charging ? description[kIOPSTimeToFullChargeKey] as? Int : description[kIOPSTimeToEmptyKey] as? Int
            var info = BatteryInfo(percent: max > 0 ? current * 100 / max : current, charging: charging, onPower: onPower,
                                   minutesLeft: (minutes ?? -1) > 0 ? minutes : nil)
            smartBattery(into: &info)
            return info
        }
        return nil
    }

    private static func smartBattery(into info: inout BatteryInfo) {
        let service = IOServiceGetMatchingService(0, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }
        func number(_ key: String) -> Int? {
            IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int
        }
        info.cycles = number("CycleCount")
        if let design = number("DesignCapacity"), design > 0,
           let max = number("AppleRawMaxCapacity") ?? number("NominalChargeCapacity") {
            info.healthPercent = min(100, max * 100 / design)
        }
        if let raw = number("Temperature") { info.temperature = Double(raw) / 100 }
    }

    // MARK: Processes

    private func topProcesses(limit: Int = 5) -> [ProcessUsage] {
        let capacity = Int(proc_listallpids(nil, 0)) + 32
        guard capacity > 32 else { return [] }
        var pids = [Int32](repeating: 0, count: capacity)
        let found = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<Int32>.size)))
        let now = Date()
        let seconds = lastProcAt.map { max(now.timeIntervalSince($0), 0.1) }
        var times: [Int32: UInt64] = [:]
        var rows: [ProcessUsage] = []
        for pid in pids.prefix(found) where pid > 0 {
            var usage = rusage_info_v2()
            let ok = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
            }
            guard ok == 0 else { continue }
            let cpuTime = UInt64(Double(usage.ri_user_time + usage.ri_system_time) * timebase)
            times[pid] = cpuTime
            guard let seconds, let before = lastProcTimes[pid], cpuTime >= before else { continue }
            let percent = Double(cpuTime - before) / (seconds * 1_000_000_000) * 100
            let label = Self.appName(pid)
            guard !label.isEmpty else { continue }
            rows.append(ProcessUsage(pid: pid, name: label, cpuPercent: percent, memory: usage.ri_phys_footprint))
        }
        lastProcTimes = times
        lastProcAt = now
        // Helpers count towards their app ("Google Chrome Helper (Renderer)" → "Google Chrome").
        var grouped: [String: ProcessUsage] = [:]
        for row in rows {
            let previous = grouped[row.name]
            grouped[row.name] = ProcessUsage(pid: previous?.pid ?? row.pid, name: row.name,
                                             cpuPercent: (previous?.cpuPercent ?? 0) + row.cpuPercent,
                                             memory: (previous?.memory ?? 0) + row.memory)
        }
        return Array(grouped.values.sorted { $0.cpuPercent > $1.cpuPercent }.prefix(limit))
    }

    /// The outermost app bundle a process belongs to, else its executable name.
    static func appName(_ pid: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: 4096)
        if proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 {
            let path = String(cString: buffer)
            if let app = path.components(separatedBy: "/").first(where: { $0.hasSuffix(".app") }) {
                return String(app.dropLast(4))
            }
            if let last = path.components(separatedBy: "/").last, !last.isEmpty { return last }
        }
        var name = [CChar](repeating: 0, count: 256)
        proc_name(pid, &name, UInt32(name.count))
        return String(cString: name)
    }
}
