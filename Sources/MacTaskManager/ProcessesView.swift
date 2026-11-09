import SwiftUI
import AppKit

enum SortKey { case name, pid, user, cpu, mem, disk, net, threads }

struct KillTarget {
    var title: String
    var pids: [Int32]
    var force: Bool
}

struct DRow: Identifiable {
    enum Kind { case section, group, proc }
    let id: String
    let kind: Kind
    let title: String
    var depth = 0
    var appPath: String? = nil
    var cpu: Double = 0
    var mem: UInt64 = 0
    var threads: Int = 0
    var disk: Double = 0
    var net: Double = 0
    var pid: Int32? = nil
    var user = ""
    var path = ""
    var pids: [Int32] = []
    var count = 0
    var category: Category? = nil
}

/// grouped = true 时是“进程”页（按应用分组，仿 Win11）；false 时是“详细信息”页（平铺）
struct ProcessesView: View {
    let grouped: Bool
    @EnvironmentObject private var monitor: Monitor
    @Environment(\.theme) private var theme

    @State private var sortKey: SortKey = .cpu
    @State private var ascending = false
    @State private var collapsed: Set<String> = []
    @State private var expanded: Set<String> = []
    @State private var selection: String?
    @State private var search = ""
    @State private var target: KillTarget?
    @State private var showKill = false
    @State private var errorText: String?

    private let wPid: CGFloat = 56
    private let wUser: CGFloat = 80
    private let wCpu: CGFloat = 84
    private let wMem: CGFloat = 104
    private let wDisk: CGFloat = 92
    private let wNet: CGFloat = 92
    private let wThr: CGFloat = 70

    var body: some View {
        let rows = buildRows()
        VStack(alignment: .leading, spacing: 14) {
            topBar(rows)
            VStack(spacing: 0) {
                headerRow
                Rectangle().fill(theme.stroke).frame(height: 1)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(rows) { r in rowView(r) }
                    }
                }
            }
            .card()
        }
        .padding(.horizontal, 22)
        .padding(.top, 8)
        .padding(.bottom, 18)
        .confirmationDialog(target.map { "结束 “\($0.title)”？" } ?? "", isPresented: $showKill, presenting: target) { t in
            Button(t.force ? "强制结束" : "结束任务", role: .destructive) { perform(t) }
            Button("取消", role: .cancel) {}
        } message: { t in
            Text(t.force ? "将立即终止，未保存的数据会丢失。" : "程序会收到正常的退出请求，未保存的数据可能丢失。")
        }
        .alert("无法结束进程", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("好") {}
        } message: {
            Text(errorText ?? "")
        }
    }

    // MARK: 顶部栏

    private func topBar(_ rows: [DRow]) -> some View {
        let procs = monitor.snap.procs
        let threads = procs.reduce(0) { $0 + $1.threads }
        let sel = rows.first { $0.id == selection && $0.kind != .section }
        return HStack(alignment: .bottom, spacing: 12) {
            PageHeader(title: grouped ? "进程" : "详细信息",
                       subtitle: "共 \(procs.count) 个进程 · \(threads) 个线程")
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(theme.secondary)
                TextField("搜索进程名或 PID", text: $search).textFieldStyle(.plain).frame(width: 150)
            }
            .font(.system(size: 12.5))
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Capsule().fill(theme.surfaceStrong))
            .overlay(Capsule().strokeBorder(theme.stroke))
            PillButton(title: "结束任务", icon: "xmark.circle", prominent: true) { if let s = sel { ask(s, force: false) } }
                .disabled(sel == nil)
            PillButton(title: "强制结束", icon: "bolt.slash", destructive: true) { if let s = sel { ask(s, force: true) } }
                .disabled(sel == nil)
        }
    }

    // MARK: 表头

    private var headerRow: some View {
        HStack(spacing: 0) {
            head("名称", key: .name, w: nil, align: .leading)
            head("PID", key: .pid, w: wPid)
            head("用户", key: .user, w: wUser, align: .leading)
            head("CPU", sub: pct0(monitor.snap.cpuTotal), key: .cpu, w: wCpu)
            head("内存", sub: monitor.snap.memTotal > 0 ? pct0(Double(monitor.snap.memUsed) / Double(monitor.snap.memTotal)) : "", key: .mem, w: wMem)
            head("磁盘", key: .disk, w: wDisk)
            head("网络", key: .net, w: wNet)
            head("线程", key: .threads, w: wThr)
            if !grouped {
                Text("路径").font(.system(size: 11, weight: .medium)).foregroundStyle(theme.secondary)
                    .padding(.horizontal, 10).frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
            }
        }
        .padding(.leading, 6)
    }

    @ViewBuilder
    private func head(_ title: String, sub: String? = nil, key: SortKey, w: CGFloat?, align: Alignment = .trailing) -> some View {
        let label = Button {
            if sortKey == key { ascending.toggle() } else { sortKey = key; ascending = (key == .name || key == .pid || key == .user) }
        } label: {
            VStack(alignment: align == .leading ? .leading : .trailing, spacing: 1) {
                if let sub { Text(sub).font(.system(size: 15, weight: .semibold).monospacedDigit()) }
                HStack(spacing: 3) {
                    Text(title)
                    if sortKey == key { Image(systemName: ascending ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .bold)) }
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.secondary)
            }
            .padding(.horizontal, 10)
        }
        .buttonStyle(.plain)
        if let w {
            label.frame(width: w, height: 46, alignment: align)
        } else {
            label.frame(maxWidth: .infinity, minHeight: 46, alignment: align)
        }
    }

    // MARK: 行

    @ViewBuilder
    private func rowView(_ r: DRow) -> some View {
        if r.kind == .section { sectionRow(r) } else { procRowView(r) }
    }

    private func sectionRow(_ r: DRow) -> some View {
        let key = r.category?.rawValue ?? r.title
        return HStack(spacing: 8) {
            Image(systemName: collapsed.contains(key) ? "chevron.right" : "chevron.down")
                .font(.system(size: 10, weight: .bold)).frame(width: 12).foregroundStyle(theme.secondary)
            Text(r.title).font(.system(size: 12.5, weight: .semibold))
            Text("(\(r.count))").font(.system(size: 12)).foregroundStyle(theme.secondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(height: 34)
        .background(theme.surface)
        .contentShape(Rectangle())
        .onTapGesture {
            if collapsed.contains(key) { collapsed.remove(key) } else { collapsed.insert(key) }
        }
    }

    private func procRowView(_ r: DRow) -> some View {
        let total = Double(max(monitor.snap.memTotal, 1))
        let heatCpu = theme.cpu.opacity(min(1, r.cpu / 0.35) * 0.40)
        let heatMem = theme.memory.opacity(min(1, Double(r.mem) / total / 0.12) * 0.40)
        let heatDisk = theme.disk.opacity(min(1, r.disk / 5_000_000) * 0.40)
        let heatNet = theme.network.opacity(min(1, r.net / 2_000_000) * 0.40)
        let selected = selection == r.id
        return HStack(spacing: 0) {
            HStack(spacing: 8) {
                Color.clear.frame(width: CGFloat(r.depth) * 22, height: 1)
                if r.kind == .group {
                    Image(systemName: expanded.contains(r.id) ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .bold)).frame(width: 12).foregroundStyle(theme.secondary)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if expanded.contains(r.id) { expanded.remove(r.id) } else { expanded.insert(r.id) }
                        }
                } else {
                    Color.clear.frame(width: 12, height: 1)
                }
                icon(r)
                Text(r.title).font(.system(size: 12.5)).lineLimit(1)
                if r.kind == .group { Text("(\(r.count))").font(.system(size: 12)).foregroundStyle(theme.secondary) }
            }
            .padding(.leading, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            cell(r.pid.map { String($0) } ?? "", wPid)
            cell(r.user, wUser, align: .leading)
            cell(r.cpu < 0.0005 ? "0%" : pct1(r.cpu), wCpu, heat: heatCpu)
            cell(r.mem > 0 ? fmtBytes(r.mem) : "—", wMem, heat: heatMem)
            cell(rateText(r.disk, known: r.threads > 0), wDisk, heat: heatDisk)
            cell(rateText(r.net, known: monitor.snap.perProcNet), wNet, heat: heatNet)
            cell(r.threads > 0 ? "\(r.threads)" : "—", wThr)
            if !grouped {
                Text(r.path).font(.system(size: 11)).foregroundStyle(theme.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .padding(.horizontal, 10).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.leading, 6)
        .frame(height: 34)
        .background(selected ? theme.accent.opacity(0.20) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { selection = r.id }
        .contextMenu {
            Button("结束任务") { ask(r, force: false) }
            Button("强制结束") { ask(r, force: true) }
            if !r.path.isEmpty {
                Button("在 Finder 中显示") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: r.appPath ?? r.path)])
                }
            }
            if let pid = r.pid {
                Button("复制 PID") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(String(pid), forType: .string)
                }
            }
        }
    }

    private func rateText(_ v: Double, known: Bool) -> String {
        if !known { return "—" }
        return v < 1 ? "0 B/s" : fmtRate(v)
    }

    private func cell(_ text: String, _ w: CGFloat, heat: Color = .clear, align: Alignment = .trailing) -> some View {
        Text(text)
            .font(.system(size: 12).monospacedDigit())
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(width: w, height: 34, alignment: align)
            .background(heat)
    }

    @ViewBuilder
    private func icon(_ r: DRow) -> some View {
        if let a = r.appPath {
            Image(nsImage: IconCache.icon(a)).resizable().frame(width: 18, height: 18)
        } else {
            Image(systemName: r.kind == .group ? "square.stack.3d.up.fill" : "gearshape.fill")
                .font(.system(size: 12)).foregroundStyle(theme.secondary).frame(width: 18, height: 18)
        }
    }

    // MARK: 结束进程

    private func ask(_ r: DRow, force: Bool) {
        selection = r.id
        target = KillTarget(title: r.title, pids: r.pids, force: force)
        showKill = true
    }

    private func perform(_ t: KillTarget) {
        if let err = Killer.kill(t.pids, force: t.force, procs: monitor.snap.procs) { errorText = err }
    }

    // MARK: 构建 / 排序

    private func leaf(_ p: ProcRow, depth: Int, useApp: Bool) -> DRow {
        DRow(id: "p:\(p.pid)", kind: .proc, title: useApp ? p.groupKey : p.name, depth: depth, appPath: p.appPath,
             cpu: p.cpu, mem: p.mem, threads: p.threads, disk: p.disk, net: p.net,
             pid: p.pid, user: p.user, path: p.path, pids: [p.pid])
    }

    private func buildRows() -> [DRow] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        let procs = monitor.snap.procs.filter {
            q.isEmpty || $0.name.lowercased().contains(q) || $0.groupKey.lowercased().contains(q) || String($0.pid) == q
        }
        if !grouped { return sorted(procs.map { leaf($0, depth: 0, useApp: false) }) }

        var out: [DRow] = []
        for cat in Category.allCases {
            let inCat = procs.filter { $0.category == cat }
            if inCat.isEmpty { continue }
            var items: [DRow] = []
            var childMap: [String: [DRow]] = [:]
            for (key, list) in Dictionary(grouping: inCat, by: { $0.groupKey }) {
                if list.count == 1 {
                    items.append(leaf(list[0], depth: 0, useApp: true))
                } else {
                    let gid = "g:\(cat.rawValue):\(key)"
                    items.append(DRow(id: gid, kind: .group, title: key, appPath: list.first(where: { $0.appPath != nil })?.appPath,
                                      cpu: list.reduce(0.0) { $0 + $1.cpu },
                                      mem: list.reduce(UInt64(0)) { $0 + $1.mem },
                                      threads: list.reduce(0) { $0 + $1.threads },
                                      disk: list.reduce(0.0) { $0 + $1.disk },
                                      net: list.reduce(0.0) { $0 + $1.net },
                                      user: list[0].user, pids: list.map { $0.pid }, count: list.count))
                    childMap[gid] = sorted(list.map { leaf($0, depth: 1, useApp: false) })
                }
            }
            items = sorted(items)
            out.append(DRow(id: "s:\(cat.rawValue)", kind: .section, title: cat.rawValue, count: inCat.count, category: cat))
            if collapsed.contains(cat.rawValue) { continue }
            for it in items {
                out.append(it)
                if it.kind == .group && expanded.contains(it.id) { out += childMap[it.id] ?? [] }
            }
        }
        return out
    }

    private func cmp<T: Comparable>(_ a: T, _ b: T) -> Int { a < b ? -1 : (a > b ? 1 : 0) }

    private func sorted(_ rows: [DRow]) -> [DRow] {
        rows.sorted { x, y in
            let c: Int
            switch sortKey {
            case .name: c = x.title.localizedCaseInsensitiveCompare(y.title).rawValue
            case .pid: c = cmp(x.pid ?? 0, y.pid ?? 0)
            case .user: c = x.user.localizedCaseInsensitiveCompare(y.user).rawValue
            case .cpu: c = cmp(x.cpu, y.cpu)
            case .mem: c = cmp(x.mem, y.mem)
            case .disk: c = cmp(x.disk, y.disk)
            case .net: c = cmp(x.net, y.net)
            case .threads: c = cmp(x.threads, y.threads)
            }
            if c == 0 { return x.id < y.id }
            return ascending ? c < 0 : c > 0
        }
    }
}
