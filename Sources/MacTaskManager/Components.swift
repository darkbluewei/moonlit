import SwiftUI
import AppKit

// MARK: - 格式化

private func formatBytes(_ n: Int64, _ style: ByteCountFormatter.CountStyle) -> String {
    let f = ByteCountFormatter()
    f.countStyle = style
    f.allowsNonnumericFormatting = false   // 0 显示为 “0 KB”，而不是 “Zero KB”
    return f.string(fromByteCount: n)
}

func fmtBytes(_ b: UInt64) -> String { formatBytes(Int64(b), .memory) }

func fmtRate(_ b: Double) -> String { formatBytes(Int64(max(b, 0)), .file) + "/s" }

func fmtTemp(_ t: Double?) -> String { t.map { String(format: "%.0f ℃", $0) } ?? "—" }

func pct0(_ v: Double) -> String { String(format: "%.0f%%", v * 100) }
func pct1(_ v: Double) -> String { String(format: "%.1f%%", v * 100) }

func fmtUptime(_ t: TimeInterval) -> String {
    let s = Int(t)
    let d = s / 86400, h = s % 86400 / 3600, m = s % 3600 / 60
    return d > 0 ? "\(d) 天 \(h) 时 \(m) 分" : String(format: "%d:%02d:%02d", h, m, s % 60)
}

// MARK: - 应用图标缓存

enum IconCache {
    private static let lock = NSLock()
    private static var cache: [String: NSImage] = [:]

    static func icon(_ path: String) -> NSImage {
        lock.lock()
        defer { lock.unlock() }
        if let i = cache[path] { return i }
        let i = NSWorkspace.shared.icon(forFile: path)
        i.size = NSSize(width: 18, height: 18)
        cache[path] = i
        return i
    }
}

// MARK: - 卡片与按钮

struct CardStyle: ViewModifier {
    @Environment(\.theme) private var t
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: t.radius, style: .continuous).fill(t.surface))
            .overlay(RoundedRectangle(cornerRadius: t.radius, style: .continuous).strokeBorder(t.stroke, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: t.radius, style: .continuous))
    }
}

extension View {
    func card() -> some View { modifier(CardStyle()) }
}

struct PillButton: View {
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var enabled
    var title: String
    var icon: String? = nil
    var prominent = false
    var destructive = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon { Image(systemName: icon) }
                Text(title)
            }
            .font(.system(size: 12.5, weight: .medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .foregroundStyle(prominent ? theme.onAccent : (destructive ? Color.red : theme.text))
            .background(Capsule().fill(prominent ? theme.accent : theme.surfaceStrong))
            .overlay(Capsule().strokeBorder(theme.stroke))
            .opacity(enabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
    }
}

struct PageHeader: View {
    @Environment(\.theme) private var theme
    var title: String
    var subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 28, weight: .semibold, design: theme.id == .glass ? .default : .rounded))
            Text(subtitle)
                .font(.system(size: 12.5))
                .foregroundStyle(theme.secondary)
        }
    }
}

struct StatTile: View {
    @Environment(\.theme) private var theme
    var title: String
    var value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11.5)).foregroundStyle(theme.secondary)
            Text(value).font(.system(size: 19, weight: .semibold).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .card()
    }
}

// MARK: - 圆环仪表

struct RingGauge: View {
    @Environment(\.theme) private var theme
    var value: Double       // 0...1
    var color: Color
    var label: String

    var body: some View {
        ZStack {
            Circle().stroke(theme.surfaceStrong, lineWidth: 10)
            Circle()
                .trim(from: 0, to: CGFloat(min(max(value, 0.004), 1)))
                .stroke(AngularGradient(colors: [color.opacity(0.4), color], center: .center,
                                        startAngle: .degrees(0), endAngle: .degrees(360)),
                        style: StrokeStyle(lineWidth: 10, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: theme.glow ? color.opacity(0.7) : .clear, radius: 6)
                .animation(.easeOut(duration: 0.5), value: value)
            Text(label)
                .font(.system(size: 17, weight: .semibold, design: .rounded).monospacedDigit())
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .padding(.horizontal, 16)
        }
    }
}

// MARK: - 折线图

struct GridLines: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        for i in 1..<4 {
            let y = r.height * CGFloat(i) / 4
            p.move(to: CGPoint(x: 0, y: y))
            p.addLine(to: CGPoint(x: r.width, y: y))
        }
        for i in 1..<10 {
            let x = r.width * CGFloat(i) / 10
            p.move(to: CGPoint(x: x, y: 0))
            p.addLine(to: CGPoint(x: x, y: r.height))
        }
        return p
    }
}

struct LineGraph: View {
    @Environment(\.theme) private var theme
    var series: [[Double]]      // 每条曲线的取值范围 0...1
    var colors: [Color]
    var length: Int = 60
    var grid: Bool = true
    var fill: Bool = true

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if grid { GridLines().stroke(theme.stroke, lineWidth: 0.5) }
                ForEach(0..<series.count, id: \.self) { i in
                    let pts = points(series[i], in: geo.size)
                    if fill && i == 0 {
                        areaPath(pts, size: geo.size)
                            .fill(LinearGradient(colors: [colors[i].opacity(0.38), colors[i].opacity(0.02)],
                                                 startPoint: .top, endPoint: .bottom))
                    }
                    linePath(pts)
                        .stroke(colors[i], style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                        .shadow(color: theme.glow ? colors[i].opacity(0.8) : .clear, radius: theme.glow ? 5 : 0)
                }
            }
        }
        .clipped()
    }

    private func points(_ v: [Double], in size: CGSize) -> [CGPoint] {
        let padded: [Double] = Array(repeating: 0.0, count: max(0, length - v.count)) + Array(v.suffix(length))
        let n = max(padded.count - 1, 1)
        return padded.enumerated().map { item in
            let x = size.width * CGFloat(item.offset) / CGFloat(n)
            let y = size.height * (1 - CGFloat(min(max(item.element, 0), 1)))
            return CGPoint(x: x, y: y)
        }
    }

    private func linePath(_ p: [CGPoint]) -> Path {
        var path = Path()
        guard let first = p.first, let last = p.last else { return path }
        path.move(to: first)
        if p.count > 1 {
            for i in 1..<p.count {
                let mid = CGPoint(x: (p[i - 1].x + p[i].x) / 2, y: (p[i - 1].y + p[i].y) / 2)
                path.addQuadCurve(to: mid, control: p[i - 1])
            }
        }
        path.addLine(to: last)
        return path
    }

    private func areaPath(_ p: [CGPoint], size: CGSize) -> Path {
        var path = linePath(p)
        guard let first = p.first, let last = p.last else { return path }
        path.addLine(to: CGPoint(x: last.x, y: size.height))
        path.addLine(to: CGPoint(x: first.x, y: size.height))
        path.closeSubpath()
        return path
    }
}
