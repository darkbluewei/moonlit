import SwiftUI
import AppKit

enum ThemeID: String, CaseIterable, Identifiable {
    case glass, dashboard
    var id: String { rawValue }
    var label: String { self == .glass ? "原生" : "仪表盘" }
}

struct Theme {
    let id: ThemeID
    let text: Color
    let secondary: Color
    let surface: Color
    let surfaceStrong: Color
    let stroke: Color
    let accent: Color
    let onAccent: Color
    let radius: CGFloat
    let cpu: Color
    let memory: Color
    let disk: Color
    let network: Color
    let gpu: Color
    let glow: Bool
    let scheme: ColorScheme?

    /// A. macOS 原生质感：毛玻璃、系统字体与系统强调色，自动跟随浅色 / 深色模式
    static let glass = Theme(
        id: .glass, text: .primary, secondary: .secondary,
        surface: Color.primary.opacity(0.045), surfaceStrong: Color.primary.opacity(0.09),
        stroke: Color.primary.opacity(0.10), accent: .accentColor, onAccent: .white, radius: 10,
        cpu: Color(red: 0.04, green: 0.52, blue: 1.0), memory: Color(red: 0.69, green: 0.32, blue: 0.87),
        disk: Color(red: 0.19, green: 0.78, blue: 0.35), network: Color(red: 1.0, green: 0.62, blue: 0.04),
        gpu: Color(red: 1.0, green: 0.27, blue: 0.23), glow: false, scheme: nil)

    /// B. 深色仪表盘：深色底、渐变光晕、发光曲线
    static let dashboard = Theme(
        id: .dashboard, text: Color(white: 0.93), secondary: Color(white: 0.93).opacity(0.55),
        surface: Color.white.opacity(0.05), surfaceStrong: Color.white.opacity(0.10),
        stroke: Color.white.opacity(0.10), accent: Color(red: 0.30, green: 0.85, blue: 0.95),
        onAccent: Color.black.opacity(0.85), radius: 14,
        cpu: Color(red: 0.30, green: 0.85, blue: 0.95), memory: Color(red: 0.64, green: 0.52, blue: 1.0),
        disk: Color(red: 0.35, green: 0.95, blue: 0.60), network: Color(red: 1.0, green: 0.70, blue: 0.30),
        gpu: Color(red: 1.0, green: 0.40, blue: 0.62), glow: true, scheme: .dark)
}

private struct ThemeKey: EnvironmentKey {
    static let defaultValue = Theme.glass
}

extension EnvironmentValues {
    var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) { v.material = material }
}

struct AppBackground: View {
    @Environment(\.theme) private var theme
    var body: some View {
        if theme.id == .glass {
            VisualEffect(material: .underWindowBackground)
        } else {
            ZStack {
                Color(red: 0.04, green: 0.055, blue: 0.09)
                RadialGradient(colors: [theme.cpu.opacity(0.20), .clear], center: .topTrailing, startRadius: 0, endRadius: 560)
                RadialGradient(colors: [theme.memory.opacity(0.16), .clear], center: .bottomLeading, startRadius: 0, endRadius: 520)
            }
        }
    }
}
