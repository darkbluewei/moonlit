import SwiftUI
import AppKit

struct StartupItem: Identifiable, Hashable {
    let id: String          // plist 文件路径
    let label: String
    let program: String
    let scope: String
    let runAtLoad: Bool
}

enum StartupScanner {
    static func scan() -> [StartupItem] {
        let home = NSHomeDirectory()
        let dirs: [(String, String)] = [
            (home + "/Library/LaunchAgents", "用户代理"),
            ("/Library/LaunchAgents", "系统代理"),
            ("/Library/LaunchDaemons", "系统守护进程")
        ]
        var out: [StartupItem] = []
        let fm = FileManager.default
        for (dir, scope) in dirs {
            guard let files = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for f in files where f.hasSuffix(".plist") {
                let path = dir + "/" + f
                guard let data = fm.contents(atPath: path),
                      let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
                      let d = obj as? [String: Any] else { continue }
                let label = (d["Label"] as? String) ?? (f as NSString).deletingPathExtension
                let program = (d["Program"] as? String) ?? (d["ProgramArguments"] as? [String])?.first ?? ""
                let run = (d["RunAtLoad"] as? Bool) ?? false
                out.append(StartupItem(id: path, label: label, program: program, scope: scope, runAtLoad: run))
            }
        }
        return out.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }
}

struct StartupView: View {
    @Environment(\.theme) private var theme
    @State private var items: [StartupItem] = []
    @State private var onlyAuto = true
    @State private var loading = true

    private var shown: [StartupItem] { items.filter { !onlyAuto || $0.runAtLoad } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .bottom) {
                PageHeader(title: "启动项", subtitle: "登录或开机时自动运行的 LaunchAgents / LaunchDaemons（只读）")
                Spacer()
                Toggle("仅显示自动运行", isOn: $onlyAuto).toggleStyle(.switch).font(.system(size: 12.5))
                PillButton(title: "重新扫描", icon: "arrow.clockwise") { reload() }
            }
            if loading {
                ProgressView().frame(maxWidth: .infinity, minHeight: 160)
            } else if shown.isEmpty {
                Text("没有找到启动项").foregroundStyle(theme.secondary).frame(maxWidth: .infinity, minHeight: 160)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(shown) { item in row(item) }
                    }
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 8)
        .padding(.bottom, 18)
        .task { reload() }
    }

    private func reload() {
        loading = true
        Task {
            let result = await Task.detached { StartupScanner.scan() }.value
            items = result
            loading = false
        }
    }

    private func row(_ item: StartupItem) -> some View {
        HStack(spacing: 12) {
            Image(systemName: item.scope == "系统守护进程" ? "gearshape.2.fill" : "power.circle.fill")
                .font(.system(size: 20)).foregroundStyle(theme.accent).frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.label).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(item.program.isEmpty ? item.id : item.program)
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(theme.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Text(item.scope).font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Capsule().fill(theme.surfaceStrong))
            Text(item.runAtLoad ? "自动运行" : "按需").font(.system(size: 11))
                .foregroundStyle(item.runAtLoad ? theme.disk : theme.secondary)
            PillButton(title: "在 Finder 中显示") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.id)])
            }
        }
        .padding(12)
        .card()
    }
}
