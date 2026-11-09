import SwiftUI

enum Res: String, CaseIterable, Identifiable {
    case cpu = "CPU"
    case memory = "内存"
    case disk = "磁盘"
    case network = "网络"
    case gpu = "GPU"
    case battery = "电池"
    var id: String { rawValue }
}

struct GraphData {
    var series: [[Double]]
    var top: String
}

struct PerformanceView: View {
    @EnvironmentObject private var monitor: Monitor
    @Environment(\.theme) private var theme
    @State private var selected: Res = .cpu
    @State private var perCore = false

    private var resources: [Res] {
        var r: [Res] = [.cpu, .memory, .disk, .network]
        if monitor.snap.gpu != nil { r.append(.gpu) }
        if monitor.snap.battery != nil { r.append(.battery) }
        return r
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageHeader(title: "性能", subtitle: "最近 60 秒的实时使用情况")
            if theme.id == .dashboard {
                dashboard
            } else {
            HStack(alignment: .top, spacing: 18) {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(resources) { r in resourceCard(r) }
                    }
                    .padding(.vertical, 2)
                }
                .frame(width: 256)
                ScrollView { detail }
                    .frame(maxWidth: .infinity)
            }
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 8)
        .padding(.bottom, 18)
    }

    // MARK: 数据

    private func color(_ r: Res) -> Color {
        switch r {
        case .cpu: return theme.cpu
        case .memory: return theme.memory
        case .disk: return theme.disk
        case .network: return theme.network
        case .gpu: return theme.gpu
        case .battery: return theme.disk
        }
    }

    private func colors(_ r: Res) -> [Color] {
        switch r {
        case .disk: return [theme.disk, theme.cpu]
        case .network: return [theme.network, theme.memory]
        default: return [color(r)]
        }
    }

    private func graphData(_ r: Res) -> GraphData {
        switch r {
        case .cpu: return GraphData(series: [monitor.cpuHist], top: "100%")
        case .memory: return GraphData(series: [monitor.memHist], top: fmtBytes(monitor.snap.memTotal))
        case .gpu: return GraphData(series: [monitor.gpuHist], top: "100%")
        case .battery: return GraphData(series: [monitor.batteryHist], top: "100%")
        case .disk: return rateData(monitor.diskReadHist, monitor.diskWriteHist)
        case .network: return rateData(monitor.netInHist, monitor.netOutHist)
        }
    }

    private func rateData(_ a: [Double], _ b: [Double]) -> GraphData {
        let m = max(1_000_000, a.max() ?? 0, b.max() ?? 0)
        return GraphData(series: [a.map { $0 / m }, b.map { $0 / m }], top: fmtRate(m))
    }

    private func summary(_ r: Res) -> String {
        let s = monitor.snap
        switch r {
        case .cpu: return "\(pct0(s.cpuTotal))  ·  \(s.cores.count) 核"
        case .memory: return "\(fmtBytes(s.memUsed)) / \(fmtBytes(s.memTotal))"
        case .disk: return "读 \(fmtRate(s.diskRead))\n写 \(fmtRate(s.diskWrite))"
        case .network: return "↓ \(fmtRate(s.netIn))\n↑ \(fmtRate(s.netOut))"
        case .gpu: return pct0(s.gpu ?? 0)
        case .battery: return batteryLine(s.battery)
        }
    }

    private func subtitle(_ r: Res) -> String {
        switch r {
        case .cpu: return monitor.cpuName
        case .memory: return "总量 \(fmtBytes(monitor.snap.memTotal))"
        case .disk: return "存储读写"
        case .network: return "所有网络接口合计"
        case .gpu: return "图形处理器"
        case .battery: return "电池与电源"
        }
    }

    private func stats(_ r: Res) -> [(String, String)] {
        let s = monitor.snap
        switch r {
        case .cpu:
            return [("利用率", pct1(s.cpuTotal)), ("进程", "\(s.procs.count)"),
                    ("线程", "\(s.procs.reduce(0) { $0 + $1.threads })"),
                    ("逻辑核心", "\(s.cores.count)"), ("已运行", fmtUptime(ProcessInfo.processInfo.systemUptime))]
        case .memory:
            return [("使用中", fmtBytes(s.memUsed)), ("总量", fmtBytes(s.memTotal)),
                    ("App 内存", fmtBytes(s.memApp)), ("固定内存", fmtBytes(s.memWired)),
                    ("已压缩", fmtBytes(s.memCompressed)), ("已缓存文件", fmtBytes(s.memCached)),
                    ("交换已用", fmtBytes(s.swapUsed))]
        case .disk:
            return [("读取速度", fmtRate(s.diskRead)), ("写入速度", fmtRate(s.diskWrite))]
        case .network:
            return [("接收 ↓", fmtRate(s.netIn)), ("发送 ↑", fmtRate(s.netOut))]
        case .gpu:
            return [("利用率", pct1(s.gpu ?? 0))]
        case .battery:
            return batteryStats(s.battery)
        }
    }

    private func batteryState(_ b: BatteryInfo) -> String {
        if b.isCharging { return "充电中" }
        if b.pluggedIn { return b.percent >= 0.99 ? "已充满" : "已接通电源" }
        return "使用电池"
    }

    private func batteryLine(_ b: BatteryInfo?) -> String {
        guard let b else { return "—" }
        return "\(pct0(b.percent))  ·  \(batteryState(b))"
    }

    private func batteryStats(_ b: BatteryInfo?) -> [(String, String)] {
        guard let b else { return [] }
        var out: [(String, String)] = [("电量", pct1(b.percent)), ("状态", batteryState(b))]
        if let h = b.health { out.append(("电池健康", pct0(h))) }
        out.append(("循环次数", "\(b.cycles)"))
        if let t = b.tempC { out.append(("电池温度", String(format: "%.1f ℃", t))) }
        if let w = b.watts { out.append((w >= 0 ? "充电功率" : "放电功率", String(format: "%.1f W", abs(w)))) }
        return out
    }

    // MARK: 监控大屏（仪表盘风格）

    private var dashboard: some View {
        GeometryReader { geo in
            let items = resources
            let total = items.count + (items.count == 5 ? 1 : 0)
            let cols = total <= 4 ? 2 : 3
            let rows = (total + cols - 1) / cols
            let gap: CGFloat = 14
            let cardH = max(210, (geo.size.height - gap * CGFloat(rows - 1)) / CGFloat(rows))
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: gap), count: cols), spacing: gap) {
                    ForEach(items) { r in bigCard(r).frame(height: cardH) }
                    if items.count == 5 { sysCard.frame(height: cardH) }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func ringValue(_ r: Res) -> Double {
        let s = monitor.snap
        switch r {
        case .cpu: return s.cpuTotal
        case .memory: return s.memTotal > 0 ? Double(s.memUsed) / Double(s.memTotal) : 0
        case .disk:
            let scale = max(1_000_000, (monitor.diskReadHist.max() ?? 0) + (monitor.diskWriteHist.max() ?? 0))
            return min(1, (s.diskRead + s.diskWrite) / scale)
        case .network:
            let scale = max(1_000_000, (monitor.netInHist.max() ?? 0) + (monitor.netOutHist.max() ?? 0))
            return min(1, (s.netIn + s.netOut) / scale)
        case .gpu: return s.gpu ?? 0
        case .battery: return s.battery?.percent ?? 0
        }
    }

    private func ringLabel(_ r: Res) -> String {
        let s = monitor.snap
        switch r {
        case .disk: return fmtRate(s.diskRead + s.diskWrite)
        case .network: return fmtRate(s.netIn + s.netOut)
        default: return pct0(ringValue(r))
        }
    }

    private func cardStats(_ r: Res) -> [(String, String)] {
        let all = stats(r)
        switch r {
        case .cpu: return Array(all.dropFirst().prefix(3))
        case .memory: return all.filter { ["总量", "App 内存", "已压缩"].contains($0.0) }
        default: return Array(all.prefix(3))
        }
    }

    private func bigCard(_ r: Res) -> some View {
        let g = graphData(r)
        let c = color(r)
        let shape = RoundedRectangle(cornerRadius: theme.radius, style: .continuous)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(c).frame(width: 8, height: 8).shadow(color: c, radius: 4)
                Text(r.rawValue).font(.system(size: 15, weight: .semibold, design: .rounded))
                Spacer()
                Text(subtitle(r)).font(.system(size: 11)).foregroundStyle(theme.secondary).lineLimit(1)
            }
            HStack(spacing: 14) {
                RingGauge(value: ringValue(r), color: c, label: ringLabel(r))
                    .frame(width: 98, height: 98)
                VStack(spacing: 6) {
                    ForEach(Array(cardStats(r).enumerated()), id: \.offset) { item in
                        HStack {
                            Text(item.element.0).foregroundStyle(theme.secondary)
                            Spacer(minLength: 6)
                            Text(item.element.1).monospacedDigit().lineLimit(1)
                        }
                        .font(.system(size: 12))
                    }
                }
            }
            LineGraph(series: g.series, colors: colors(r))
                .frame(maxHeight: .infinity)
                .background(Color.black.opacity(0.22))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .padding(14)
        .background(shape.fill(theme.surface))
        .overlay(shape.strokeBorder(LinearGradient(colors: [c.opacity(0.55), theme.stroke],
                                                    startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1))
        .shadow(color: c.opacity(0.12), radius: 14)
    }

    private var sysCard: some View {
        let s = monitor.snap
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Circle().fill(theme.accent).frame(width: 8, height: 8).shadow(color: theme.accent, radius: 4)
                Text("系统").font(.system(size: 15, weight: .semibold, design: .rounded))
                Spacer()
            }
            Text(monitor.cpuName).font(.system(size: 13, weight: .medium)).lineLimit(2)
            Text("macOS · \(ProcessInfo.processInfo.operatingSystemVersionString)")
                .font(.system(size: 11)).foregroundStyle(theme.secondary).lineLimit(2)
            Spacer(minLength: 0)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                StatTile(title: "进程", value: "\(s.procs.count)")
                StatTile(title: "线程", value: "\(s.procs.reduce(0) { $0 + $1.threads })")
                StatTile(title: "逻辑核心", value: "\(s.cores.count)")
                StatTile(title: "已运行", value: fmtUptime(ProcessInfo.processInfo.systemUptime))
            }
        }
        .padding(14)
        .card()
    }

    // MARK: 左侧卡片

    private func resourceCard(_ r: Res) -> some View {
        let g = graphData(r)
        let on = selected == r
        let shape = RoundedRectangle(cornerRadius: theme.radius, style: .continuous)
        return Button { selected = r } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Circle().fill(color(r)).frame(width: 7, height: 7)
                        Text(r.rawValue).font(.system(size: 13, weight: .semibold))
                    }
                    Text(summary(r)).font(.system(size: 11)).foregroundStyle(theme.secondary).lineLimit(2)
                }
                Spacer(minLength: 0)
                LineGraph(series: g.series, colors: colors(r), grid: false)
                    .frame(width: 74, height: 40)
            }
            .padding(12)
            .background(shape.fill(on ? theme.surfaceStrong : theme.surface))
            .overlay(shape.strokeBorder(on ? color(r).opacity(0.85) : theme.stroke, lineWidth: on ? 1.5 : 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: 右侧详情

    @ViewBuilder
    private var detail: some View {
        let g = graphData(selected)
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text(selected.rawValue).font(.system(size: 26, weight: .semibold))
                Spacer()
                Text(subtitle(selected)).font(.system(size: 13)).foregroundStyle(theme.secondary)
            }
            if selected == .cpu {
                Picker("", selection: $perCore) {
                    Text("整体").tag(false)
                    Text("逻辑处理器").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 240)
            }
            if selected == .cpu && perCore {
                coreGrid
            } else {
                bigGraph(g)
            }
            if selected == .memory { memoryBar }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                ForEach(Array(stats(selected).enumerated()), id: \.offset) { item in
                    StatTile(title: item.element.0, value: item.element.1)
                }
            }
        }
        .padding(20)
        .card()
    }

    private func bigGraph(_ g: GraphData) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("利用率 / 速度").font(.system(size: 11)).foregroundStyle(theme.secondary)
                Spacer()
                Text(g.top).font(.system(size: 11).monospacedDigit()).foregroundStyle(theme.secondary)
            }
            LineGraph(series: g.series, colors: colors(selected))
                .frame(height: 250)
                .background(shape.fill(Color.black.opacity(theme.id == .glass ? 0.04 : 0.28)))
                .overlay(shape.strokeBorder(theme.stroke))
                .clipShape(shape)
            HStack {
                Text("60 秒前").font(.system(size: 11)).foregroundStyle(theme.secondary)
                Spacer()
                if selected == .disk || selected == .network {
                    legend(selected == .disk ? "读取" : "接收", colors(selected)[0])
                    legend(selected == .disk ? "写入" : "发送", colors(selected)[1])
                }
                Spacer()
                Text("现在").font(.system(size: 11)).foregroundStyle(theme.secondary)
            }
        }
    }

    private func legend(_ text: String, _ c: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(c).frame(width: 7, height: 7)
            Text(text).font(.system(size: 11)).foregroundStyle(theme.secondary)
        }
    }

    private var coreGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
            ForEach(monitor.coreHist.indices, id: \.self) { i in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("核心 \(i + 1)").font(.system(size: 11.5, weight: .medium))
                        Spacer()
                        Text(pct0(monitor.coreHist[i].last ?? 0)).font(.system(size: 11.5).monospacedDigit())
                            .foregroundStyle(theme.secondary)
                    }
                    LineGraph(series: [monitor.coreHist[i]], colors: [theme.cpu], grid: false)
                        .frame(height: 56)
                }
                .padding(10)
                .card()
            }
        }
    }

    private var memoryBar: some View {
        let s = monitor.snap
        let total = Double(max(s.memTotal, 1))
        let segs: [(String, UInt64, Color)] = [
            ("App", s.memApp, theme.memory), ("固定", s.memWired, theme.cpu),
            ("压缩", s.memCompressed, theme.network), ("缓存", s.memCached, theme.disk.opacity(0.65))
        ]
        return VStack(alignment: .leading, spacing: 8) {
            Text("内存组成").font(.system(size: 11)).foregroundStyle(theme.secondary)
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(0..<segs.count, id: \.self) { i in
                        Rectangle().fill(segs[i].2)
                            .frame(width: max(0, geo.size.width * CGFloat(Double(segs[i].1) / total)))
                    }
                    Rectangle().fill(theme.surfaceStrong)
                }
                .clipShape(Capsule())
            }
            .frame(height: 14)
            HStack(spacing: 14) {
                ForEach(0..<segs.count, id: \.self) { i in legend(segs[i].0, segs[i].2) }
                legend("可用", theme.surfaceStrong)
            }
        }
    }
}
