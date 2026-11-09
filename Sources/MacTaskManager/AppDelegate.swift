import SwiftUI
import AppKit
import Carbon.HIToolbox

/// 全局快捷键 ⌃⌥/（Control + Option + 斜杠），不需要辅助功能权限
enum HotKey {
    private static var ref: EventHotKeyRef?
    private static var handlerRef: EventHandlerRef?
    static var action: (() -> Void)?

    static func register(_ action: @escaping () -> Void) {
        HotKey.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { HotKey.action?() }
            return noErr
        }, 1, &spec, nil, &handlerRef)
        let id = EventHotKeyID(signature: OSType(0x4D544D31), id: 1)
        RegisterEventHotKey(UInt32(kVK_ANSI_Slash), UInt32(controlKey | optionKey), id,
                            GetApplicationEventTarget(), 0, &ref)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        HotKey.register { [weak self] in self?.showMainWindow() }

        // 窗口状态变化时，决定是否继续采集数据
        let names: [Notification.Name] = [
            NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification,
            NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification, NSWindow.didChangeOcclusionStateNotification,
            NSApplication.didHideNotification, NSApplication.didUnhideNotification
        ]
        for n in names {
            NotificationCenter.default.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self?.updateActive() }
            }
        }
    }

    private func updateActive() {
        let visible = !NSApp.isHidden && NSApp.windows.contains {
            $0.canBecomeMain && $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible)
        }
        Monitor.shared.active = visible
    }

    func showMainWindow() {
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        if let w = NSApp.windows.first(where: { $0.canBecomeMain }) {
            if w.isMiniaturized { w.deminiaturize(nil) }
            w.makeKeyAndOrderFront(nil)
        } else {
            // 窗口已被销毁：向自己发一次“重新打开”，SwiftUI 会新建窗口
            NSWorkspace.shared.open(Bundle.main.bundleURL)
        }
    }
}
