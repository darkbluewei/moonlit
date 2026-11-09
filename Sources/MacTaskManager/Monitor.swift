import Foundation
import Darwin
import IOKit
import AppKit
import SwiftUI

enum Category: String, CaseIterable, Hashable {
    case apps = "应用"
    case background = "后台进程"
    case system = "系统进程"
}

struct ProcRow: Identifiable, Hashable {
    let pid: Int32
    let ppid: Int32
    let user: String
    let name: String
    let path: String
    let appPath: String?
    let category: Category
    var cpu: Double      // 0...1，占整机 CPU 的比例
    var mem: UInt64      // 字节
    var threads: Int
    var disk: Double = 0   // 字节/秒（仅能读取到的进程）
    var net: Double = 0    // 字节/秒（来自 nettop）
    var id: Int32 { pid }
    var groupKey: String {
        if let a = appPath { return URL(fileURLWithPath: a).deletingPathExtension().lastPathComponent }
        return name
    }
}

struct BatteryInfo {
    var percent: Double
    var isCharging: Bool
    var pluggedIn: Bool
    var cycles: Int
    var tempC: Double?
    var watts: Double?      // 正数 = 充电，负数 = 放电
    var health: Double?
}

struct Snapshot {
    var procs: [ProcRow] = []
    var cpuTotal: Double = 0
    var cores: [Double] = []
    var memTotal: UInt64 = 0
    var memUsed: UInt64 = 0
    var memApp: UInt64 = 0
    var memWired: UInt64 = 0
    var memCompressed: UInt64 = 0
    var memCached: UInt64 = 0
    var swapUsed: UInt64 = 0
    var swapTotal: UInt64 = 0
    var diskRead: Double = 0
    var diskWrite: Double = 0
    var netIn: Double = 0
    var netOut: Double = 0
    var gpu: Double? = nil
    var battery: BatteryInfo? = nil
    var perProcNet = false
}

enum RefreshSpeed: String, CaseIterable, Identifiable {
    case high = "高（0.5 秒）"
    case normal = "正常（1 秒）"
    case low = "低（3 秒）"
    case paused = "已暂停"
    var id: String { rawValue }
    var seconds: Double {
        switch self {
        case .high: return 0.5
        case .normal: return 1
        case .low: return 3
        case .paused: return 1
        }
    }
}

// MARK: - 对界面公开的数据模型

final class Monitor: ObservableObject {
    @Published var snap = Snapshot()
    @Published var cpuHist: [Double] = []
    @Published var coreHist: [[Double]] = []
    @Published var memHist: [Double] = []
    @Published var diskReadHist: [Double] = []
    @Published var diskWriteHist: [Double] = []
    @Published var netInHist: [Double] = []
    @Published var netOutHist: [Double] = []
    @Published var gpuHist: [Double] = []
    @Published var batteryHist: [Double] = []
    @Published var speed: RefreshSpeed = .normal

    static let shared = Monitor()
    var active = true      // 窗口不可见（关闭 / 最小化 / 被遮挡 / 隐藏）时为 false，停止采集

    let cpuName: String = Monitor.brand()
    private let sampler = Sampler()
    private var started = false
    private let histLen = 60

    static func brand() -> String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("machdep.cpu.brand_string", &buf, &size, nil, 0)
        let s = String(cString: buf)
        return s.isEmpty ? "处理器" : s
    }

    func start() {
        guard !started else { return }
        started = true
        let sampler = self.sampler
        Task.detached(priority: .utility) { [weak self] in
            var idle = false
            var warm = true
            while true {
                guard let self else { return }
                let sp = self.speed
                if sp == .paused || !self.active {      // 手动暂停 / 窗口不可见：不采集
                    if !idle { idle = true; sampler.setSuspended(true) }
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    continue
                }
                if idle { idle = false; warm = true; sampler.setSuspended(false) }
                let s = sampler.sample()
                await MainActor.run { self.apply(s) }
                let wait = warm ? 0.4 : sp.seconds       // 恢复后很快再采一次，避免数值先显示为 0
                warm = false
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
        }
    }

    private func push(_ arr: inout [Double], _ v: Double) {
        arr.append(v)
        if arr.count > histLen { arr.removeFirst(arr.count - histLen) }
    }

    private func apply(_ s: Snapshot) {
        snap = s
        push(&cpuHist, s.cpuTotal)
        if coreHist.count != s.cores.count { coreHist = Array(repeating: [], count: s.cores.count) }
        for i in s.cores.indices { push(&coreHist[i], s.cores[i]) }
        push(&memHist, s.memTotal > 0 ? Double(s.memUsed) / Double(s.memTotal) : 0)
        push(&diskReadHist, s.diskRead)
        push(&diskWriteHist, s.diskWrite)
        push(&netInHist, s.netIn)
        push(&netOutHist, s.netOut)
        if let g = s.gpu { push(&gpuHist, g) }
        if let b = s.battery { push(&batteryHist, b.percent) }
    }
}

// MARK: - 结束进程

enum Killer {
    static let protectedNames: Set<String> = ["launchd", "kernel_task", "WindowServer", "loginwindow"]

    /// 返回 nil 表示成功，否则返回要展示给用户的错误说明
    static func kill(_ pids: [Int32], force: Bool, procs: [ProcRow]) -> String? {
        let byPid = Dictionary(procs.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        var denied: [String] = []
        for pid in pids {
            let name = byPid[pid]?.name ?? String(pid)
            if pid <= 1 || protectedNames.contains(name) {
                return "“\(name)” 是系统关键进程，为避免系统崩溃，已禁止结束。"
            }
            if Darwin.kill(pid, force ? SIGKILL : SIGTERM) != 0 && errno != ESRCH {
                denied.append(name)
            }
        }
        if denied.isEmpty { return nil }
        return "没有权限结束：\(Set(denied).sorted().joined(separator: "、"))。这些进程属于系统或其它用户，普通权限无法结束。"
    }
}

// MARK: - 采样器（在后台线程运行）

final class Sampler: @unchecked Sendable {
    private var prevCPU: [[UInt32]] = []
    private var prevNet: (UInt64, UInt64)?
    private var prevDisk: (UInt64, UInt64)?
    private var prevWall: UInt64 = 0
    private var prevProc: [Int32: (UInt64, UInt64, UInt64)] = [:]
    private let netTop = NetTop()
    private var users: [UInt32: String] = [:]
    private var tb = mach_timebase_info_data_t()

    init() {
        mach_timebase_info(&tb)
        netTop.start()
    }

    /// 暂停 / 恢复：暂停时挂起 nettop；恢复时清空所有“上一次”的基线，避免把暂停期间的累计量算成瞬时速率
    func setSuspended(_ suspended: Bool) {
        if suspended {
            netTop.suspend()
        } else {
            prevCPU = []
            prevNet = nil
            prevDisk = nil
            prevWall = 0
            prevProc = [:]
            netTop.resume()
        }
    }

    func sample() -> Snapshot {
        var s = Snapshot()
        let wall = DispatchTime.now().uptimeNanoseconds
        let dt = prevWall == 0 ? 0 : Double(wall - prevWall) / 1e9

        let (cpu, cores) = readCPU()
        s.cpuTotal = cpu
        s.cores = cores
        readMemory(into: &s)

        let net = readNet()
        if let p = prevNet, dt > 0 {
            s.netIn = Double(net.0 >= p.0 ? net.0 - p.0 : 0) / dt
            s.netOut = Double(net.1 >= p.1 ? net.1 - p.1 : 0) / dt
        }
        prevNet = net

        let disk = readDisk()
        if let p = prevDisk, dt > 0 {
            s.diskRead = Double(disk.0 >= p.0 ? disk.0 - p.0 : 0) / dt
            s.diskWrite = Double(disk.1 >= p.1 ? disk.1 - p.1 : 0) / dt
        }
        prevDisk = disk

        s.gpu = readGPU()
        s.battery = readBattery()
        s.perProcNet = netTop.hasData
        s.procs = readProcs(wall: wall, cores: max(cores.count, 1))
        prevWall = wall
        return s
    }

    // CPU
    private func readCPU() -> (Double, [Double]) {
        var count: natural_t = 0
        var info: processor_info_array_t? = nil
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info else { return (0, []) }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)),
                          vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride))
        }
        var cur: [[UInt32]] = []
        for i in 0..<Int(count) {
            let b = i * 4   // user, system, idle, nice
            cur.append([UInt32(bitPattern: info[b]), UInt32(bitPattern: info[b + 1]),
                        UInt32(bitPattern: info[b + 2]), UInt32(bitPattern: info[b + 3])])
        }
        var cores: [Double] = []
        var busyAll: UInt64 = 0
        var totalAll: UInt64 = 0
        for (i, c) in cur.enumerated() {
            guard i < prevCPU.count else { cores.append(0); continue }
            let p = prevCPU[i]
            let d = (0..<4).map { UInt64(c[$0] &- p[$0]) }
            let total = d.reduce(0, +)
            let busy = total - d[2]
            cores.append(total > 0 ? Double(busy) / Double(total) : 0)
            busyAll += busy
            totalAll += total
        }
        prevCPU = cur
        return (totalAll > 0 ? Double(busyAll) / Double(totalAll) : 0, cores)
    }

    // 内存
    private func readMemory(into s: inout Snapshot) {
        var st = vm_statistics64()
        var cnt = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let capacity = Int(cnt)
        let kr = withUnsafeMutablePointer(to: &st) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: capacity) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &cnt)
            }
        }
        s.memTotal = ProcessInfo.processInfo.physicalMemory
        if kr == KERN_SUCCESS {
            let page = UInt64(sysconf(_SC_PAGESIZE))
            let internalPages = UInt64(st.internal_page_count)
            let purgeable = UInt64(st.purgeable_count)
            let app = (internalPages - min(internalPages, purgeable)) * page
            let wired = UInt64(st.wire_count) * page
            let comp = UInt64(st.compressor_page_count) * page
            s.memApp = app
            s.memWired = wired
            s.memCompressed = comp
            s.memCached = (UInt64(st.external_page_count) + purgeable) * page
            s.memUsed = min(app + wired + comp, s.memTotal)
        }
        var sw = xsw_usage()
        var sz = MemoryLayout<xsw_usage>.stride
        if sysctlbyname("vm.swapusage", &sw, &sz, nil, 0) == 0 {
            s.swapUsed = sw.xsu_used
            s.swapTotal = sw.xsu_total
        }
    }

    // 网络（累计字节数）
    private func readNet() -> (UInt64, UInt64) {
        var rx: UInt64 = 0
        var tx: UInt64 = 0
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0 else { return (0, 0) }
        var ptr = ifap
        while let p = ptr {
            let ifa = p.pointee
            if let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK),
               (ifa.ifa_flags & UInt32(IFF_LOOPBACK)) == 0, let data = ifa.ifa_data {
                let d = data.assumingMemoryBound(to: if_data.self).pointee
                rx += UInt64(d.ifi_ibytes)
                tx += UInt64(d.ifi_obytes)
            }
            ptr = ifa.ifa_next
        }
        freeifaddrs(ifap)
        return (rx, tx)
    }

    // 磁盘（累计字节数）
    private func readDisk() -> (UInt64, UInt64) {
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iter) == KERN_SUCCESS
        else { return (0, 0) }
        defer { IOObjectRelease(iter) }
        var r: UInt64 = 0
        var w: UInt64 = 0
        var e = IOIteratorNext(iter)
        while e != 0 {
            var props: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(e, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let d = props?.takeRetainedValue() as? [String: Any],
               let st = d["Statistics"] as? [String: Any] {
                r += (st["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
                w += (st["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
            }
            IOObjectRelease(e)
            e = IOIteratorNext(iter)
        }
        return (r, w)
    }

    // GPU 利用率（读不到时返回 nil，界面会隐藏 GPU）
    private func readGPU() -> Double? {
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iter) == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(iter) }
        var best: Double?
        var e = IOIteratorNext(iter)
        while e != 0 {
            if let ps = IORegistryEntryCreateCFProperty(e, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any],
               let u = (ps["Device Utilization %"] as? NSNumber)?.doubleValue {
                best = max(best ?? 0, u)
            }
            IOObjectRelease(e)
            e = IOIteratorNext(iter)
        }
        return best.map { min($0 / 100, 1) }
    }

    // 电池与电源（无电池的 Mac 返回 nil）
    private func readBattery() -> BatteryInfo? {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard svc != 0 else { return nil }
        defer { IOObjectRelease(svc) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let d = props?.takeRetainedValue() as? [String: Any] else { return nil }
        func num(_ k: String) -> Double? { (d[k] as? NSNumber)?.doubleValue }
        let cur = num("CurrentCapacity") ?? 0
        let maxCap = num("MaxCapacity") ?? 100
        let design = num("DesignCapacity") ?? 0
        let rawMax = num("AppleRawMaxCapacity") ?? maxCap
        var watts: Double?
        if let v = num("Voltage"), let n = (d["InstantAmperage"] ?? d["Amperage"]) as? NSNumber {
            let amps = Double(Int64(bitPattern: n.uint64Value))
            watts = v / 1000 * amps / 1000
        }
        return BatteryInfo(
            percent: maxCap > 0 ? min(cur / maxCap, 1) : 0,
            isCharging: (d["IsCharging"] as? Bool) ?? false,
            pluggedIn: (d["ExternalConnected"] as? Bool) ?? false,
            cycles: Int(num("CycleCount") ?? 0),
            tempC: num("Temperature").map { $0 / 100 },
            watts: watts,
            health: design > 100 ? min(rawMax / design, 1.2) : nil)
    }

    // 进程
    private struct PSEntry { let pid: Int32; let ppid: Int32; let uid: UInt32; let cpu: Double; let rss: UInt64; let path: String }

    private func listPS() -> [PSEntry] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-axo", "pid=,ppid=,uid=,%cpu=,rss=,comm="]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        var out: [PSEntry] = []
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 5, omittingEmptySubsequences: true)
            guard parts.count == 6, let pid = Int32(parts[0]), let ppid = Int32(parts[1]),
                  let uid = UInt32(parts[2]), let cpu = Double(parts[3].replacingOccurrences(of: ",", with: ".")),
                  let rss = UInt64(parts[4]) else { continue }
            out.append(PSEntry(pid: pid, ppid: ppid, uid: uid, cpu: cpu, rss: rss,
                               path: String(parts[5]).trimmingCharacters(in: .whitespaces)))
        }
        return out
    }

    private func rusage(_ pid: Int32) -> (cpuNs: UInt64, footprint: UInt64, diskBytes: UInt64)? {
        var ru = rusage_info_v2()
        let r = withUnsafeMutablePointer(to: &ru) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
        }
        guard r == 0 else { return nil }
        let t = ru.ri_user_time &+ ru.ri_system_time
        let ns = t &* UInt64(tb.numer) / UInt64(max(tb.denom, 1))
        return (ns, ru.ri_phys_footprint, ru.ri_diskio_bytesread &+ ru.ri_diskio_byteswritten)
    }

    private func threadCount(_ pid: Int32) -> Int {
        var ti = proc_taskinfo()
        let r = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &ti, Int32(MemoryLayout<proc_taskinfo>.size))
        return r > 0 ? Int(ti.pti_threadnum) : 0
    }

    private func userName(_ uid: UInt32) -> String {
        if let u = users[uid] { return u }
        var n = String(uid)
        if let pw = getpwuid(uid), let c = pw.pointee.pw_name { n = String(cString: c) }
        if n.hasPrefix("_") { n.removeFirst() }
        users[uid] = n
        return n
    }

    private func appBundle(_ path: String) -> String? {
        if let r = path.range(of: ".app/") { return String(path[..<r.upperBound].dropLast()) }
        return path.hasSuffix(".app") ? path : nil
    }

    private func category(path: String, uid: UInt32, app: String?) -> Category {
        if let a = app, a.contains("/Applications/") || a == "/System/Library/CoreServices/Finder.app" { return .apps }
        if uid == 0 || path.hasPrefix("/System/") || path.hasPrefix("/usr/") || path.hasPrefix("/sbin/")
            || path.hasPrefix("/bin/") || path.hasPrefix("/Library/Apple/") { return .system }
        return .background
    }

    private func readProcs(wall: UInt64, cores: Int) -> [ProcRow] {
        var rows: [ProcRow] = []
        var newPrev: [Int32: (UInt64, UInt64, UInt64)] = [:]
        let netRates = netTop.rates()
        for e in listPS() {
            let name = (e.path as NSString).lastPathComponent
            let app = appBundle(e.path)
            var cpu = e.cpu / 100.0 / Double(cores)
            var mem = e.rss * 1024
            var threads = 0
            var disk = 0.0
            if let r = rusage(e.pid) {
                mem = r.footprint
                if let p = prevProc[e.pid], wall > p.1 {
                    if r.cpuNs >= p.0 {
                        cpu = Double(r.cpuNs - p.0) / Double(wall - p.1) / Double(cores)
                    }
                    if r.diskBytes >= p.2 {
                        disk = Double(r.diskBytes - p.2) / (Double(wall - p.1) / 1e9)
                    }
                }
                newPrev[e.pid] = (r.cpuNs, wall, r.diskBytes)
                threads = threadCount(e.pid)
            }
            rows.append(ProcRow(pid: e.pid, ppid: e.ppid, user: userName(e.uid), name: name.isEmpty ? e.path : name,
                                path: e.path, appPath: app, category: category(path: e.path, uid: e.uid, app: app),
                                cpu: min(max(cpu, 0), 1), mem: mem, threads: threads,
                                disk: disk, net: netRates[e.pid] ?? 0))
        }
        prevProc = newPrev
        return rows
    }
}

// MARK: - 每进程网络速率（后台常驻 nettop，解析 CSV 输出）

final class NetTop: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var buffer = Data()
    private var currentStamp = ""
    private var current: [Int32: UInt64] = [:]
    private var latest: [Int32: UInt64] = [:]
    private var latestAt = Date()
    private var rateMap: [Int32: Double] = [:]
    private var colIn = -1
    private var colOut = -1
    private var gotData = false
    private var ignoreUntil = Date.distantPast

    var hasData: Bool {
        lock.lock()
        defer { lock.unlock() }
        return gotData
    }

    func rates() -> [Int32: Double] {
        lock.lock()
        defer { lock.unlock() }
        return rateMap
    }

    func suspend() { process?.suspend() }

    func resume() {
        lock.lock()
        latest = [:]
        current = [:]
        currentStamp = ""
        buffer.removeAll()
        ignoreUntil = Date().addingTimeInterval(1.5)   // 丢弃恢复瞬间涌出的旧数据
        lock.unlock()
        process?.resume()
    }

    func start() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        p.arguments = ["-P", "-L", "0", "-s", "2", "-n", "-x", "-J", "bytes_in,bytes_out"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            self?.consume(d)
        }
        do { try p.run() } catch { return }
        process = p
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: nil) { [weak self] _ in
            self?.process?.terminate()
        }
    }

    private func consume(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        if Date() < ignoreUntil { buffer.removeAll(); return }
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            if let line = String(data: lineData, encoding: .utf8) { handle(line) }
        }
    }

    private func handle(_ line: String) {
        let f = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        if line.contains("bytes_in") {
            colIn = f.firstIndex(of: "bytes_in") ?? -1
            colOut = f.firstIndex(of: "bytes_out") ?? -1
            return
        }
        guard colIn >= 0, colOut >= 0, f.count > max(colIn, colOut), f.count > 1 else { return }
        if f[0] != currentStamp {
            finishBlock()
            currentStamp = f[0]
        }
        guard let dot = f[1].lastIndex(of: "."),
              let pid = Int32(f[1][f[1].index(after: dot)...]),
              let bi = UInt64(f[colIn]), let bo = UInt64(f[colOut]) else { return }
        current[pid, default: 0] += bi + bo
    }

    private func finishBlock() {
        guard !current.isEmpty else { return }
        let now = Date()
        let dt = now.timeIntervalSince(latestAt)
        var map: [Int32: Double] = [:]
        for (pid, v) in current {
            if let old = latest[pid], dt >= 0.5 { map[pid] = Double(v >= old ? v - old : v) / dt }
        }
        rateMap = map
        latest = current
        latestAt = now
        current = [:]
        gotData = true
    }
}
