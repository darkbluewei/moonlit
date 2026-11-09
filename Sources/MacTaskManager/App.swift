import SwiftUI

enum Tab: String, CaseIterable, Identifiable {
    case processes = "进程"
    case performance = "性能"
    case startup = "启动项"
    case details = "详细信息"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .processes: return "list.bullet.rectangle"
        case .performance: return "waveform.path.ecg"
        case .startup: return "power.circle"
        case .details: return "tablecells"
        }
    }
}

@main
struct MacTaskManagerApp: App {
    @StateObject private var monitor = Monitor()
    @AppStorage("theme") private var themeRaw: String = ThemeID.glass.rawValue

    private var theme: Theme { themeRaw == ThemeID.dashboard.rawValue ? .dashboard : .glass }

    var body: some Scene {
        WindowGroup("任务管理器") {
            ContentView(themeRaw: $themeRaw)
                .environmentObject(monitor)
                .environment(\.theme, theme)
                .preferredColorScheme(theme.scheme)
                .frame(minWidth: 1140, minHeight: 660)
                .onAppear { monitor.start() }
        }
    }
}

struct ContentView: View {
    @Binding var themeRaw: String
    @Environment(\.theme) private var theme
    @State private var tab: Tab = .processes

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(tab: $tab, themeRaw: $themeRaw)
                .frame(width: 212)
            Rectangle().fill(theme.stroke).frame(width: 1)
            Group {
                switch tab {
                case .processes: ProcessesView(grouped: true)
                case .performance: PerformanceView()
                case .startup: StartupView()
                case .details: ProcessesView(grouped: false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(AppBackground().ignoresSafeArea())
        .foregroundStyle(theme.text)
        .animation(.easeInOut(duration: 0.25), value: themeRaw)
    }
}

struct Sidebar: View {
    @Binding var tab: Tab
    @Binding var themeRaw: String
    @EnvironmentObject private var monitor: Monitor
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(LinearGradient(colors: [theme.cpu, theme.memory], startPoint: .topLeading, endPoint: .bottomTrailing))
                    Image(systemName: "speedometer").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                }
                .frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 0) {
                    Text("任务管理器").font(.system(size: 14, weight: .semibold))
                    Text("macOS").font(.system(size: 10)).foregroundStyle(theme.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)
            .padding(.bottom, 16)

            ForEach(Tab.allCases) { t in item(t) }

            Spacer()
            miniStats
            refreshMenu
            themeSwitch
        }
        .padding(12)
    }

    private func item(_ t: Tab) -> some View {
        let on = tab == t
        return Button { tab = t } label: {
            HStack(spacing: 10) {
                Image(systemName: t.icon).font(.system(size: 14)).frame(width: 20)
                Text(t.rawValue).font(.system(size: 13, weight: on ? .semibold : .regular))
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .foregroundStyle(on ? theme.accent : theme.text)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(on ? theme.accent.opacity(0.16) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var miniStats: some View {
        let s = monitor.snap
        let mem = s.memTotal > 0 ? Double(s.memUsed) / Double(s.memTotal) : 0
        return VStack(spacing: 10) {
            meter("CPU", s.cpuTotal, theme.cpu)
            meter("内存", mem, theme.memory)
        }
        .padding(12)
        .card()
        .padding(.bottom, 8)
    }

    private func meter(_ title: String, _ v: Double, _ c: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title).font(.system(size: 11)).foregroundStyle(theme.secondary)
                Spacer()
                Text(pct0(v)).font(.system(size: 11, weight: .semibold).monospacedDigit())
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(theme.surfaceStrong)
                    Capsule().fill(c).frame(width: geo.size.width * CGFloat(min(max(v, 0), 1)))
                        .shadow(color: theme.glow ? c.opacity(0.8) : .clear, radius: 4)
                }
            }
            .frame(height: 5)
        }
    }

    private var refreshMenu: some View {
        Menu {
            ForEach(RefreshSpeed.allCases) { s in
                Button {
                    monitor.speed = s
                } label: {
                    if monitor.speed == s { Label(s.rawValue, systemImage: "checkmark") } else { Text(s.rawValue) }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "timer")
                Text("刷新：\(monitor.speed.rawValue)").lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.system(size: 11.5))
            .foregroundStyle(theme.secondary)
        }
        .menuStyle(.borderlessButton)
        .padding(.horizontal, 6)
        .padding(.bottom, 8)
    }

    private var themeSwitch: some View {
        HStack(spacing: 4) {
            ForEach(ThemeID.allCases) { id in
                let on = theme.id == id
                Button { themeRaw = id.rawValue } label: {
                    Text(id.label)
                        .font(.system(size: 11.5, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .foregroundStyle(on ? theme.onAccent : theme.secondary)
                        .background(Capsule().fill(on ? theme.accent : Color.clear))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Capsule().fill(theme.surfaceStrong))
    }
}
