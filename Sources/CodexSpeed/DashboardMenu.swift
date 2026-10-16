import AppKit
import SwiftUI
#if SWIFT_PACKAGE
import SpeedCore
#endif

/// Keep native menu tracking independent of the dashboard's live updates.
/// Build a snapshot only when opened; updating statistics never replaces it.
struct DashboardMenu: NSViewRepresentable {
    let monitor: Monitor

    func makeCoordinator() -> Coordinator { Coordinator(monitor: monitor) }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: true)
        button.isBordered = false
        button.imagePosition = .imageOnly
        (button.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = context.coordinator
        context.coordinator.menuNeedsUpdate(menu)
        button.menu = menu
        button.setAccessibilityLabel(L10n.text("更多"))
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.monitor = monitor
        let label = L10n.text("更多")
        if button.accessibilityLabel() != label { button.setAccessibilityLabel(label) }
    }

    @MainActor
    final class Coordinator: NSObject, NSMenuDelegate {
        var monitor: Monitor
        init(monitor: Monitor) { self.monitor = monitor }

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            // A pull-down button displays its first item as the button label.
            let icon = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            icon.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: nil)
            menu.addItem(icon)
            let heading = NSMenuItem(title: L10n.text("语言"), action: nil, keyEquivalent: "")
            heading.isEnabled = false
            menu.addItem(heading)
            for (language, title) in [(AppLanguage.system, L10n.text("跟随系统")),
                                      (.simplifiedChinese, "简体中文"), (.english, "English")] {
                let item = NSMenuItem(title: title, action: #selector(selectLanguage(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = language.rawValue
                item.state = monitor.language == language ? .on : .off
                menu.addItem(item)
            }
            menu.addItem(.separator())
            add(L10n.text("选择日志文件夹…"), to: menu, action: #selector(chooseFolder))
            add(L10n.text("在 Finder 中查看日志"), to: menu, action: #selector(showLogs))
            add(L10n.text("导出最近记录…"), to: menu, action: #selector(exportCSV), enabled: monitor.session != nil)
            add(L10n.text("重新扫描"), to: menu, action: #selector(rescan))
            add(L10n.text("为什么看不到云端会话…"), to: menu, action: #selector(explainCloud))
            menu.addItem(.separator())
            add(L10n.text("退出 Codex Speed"), to: menu, action: #selector(quit))
        }

        private func add(_ title: String, to menu: NSMenu, action: Selector, enabled: Bool = true) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self; item.isEnabled = enabled
            menu.addItem(item)
        }
        @objc private func selectLanguage(_ sender: NSMenuItem) {
            guard let raw = sender.representedObject as? String, let language = AppLanguage(rawValue: raw) else { return }
            monitor.language = language
        }
        @objc private func chooseFolder() { monitor.chooseFolder() }
        @objc private func showLogs() { NSWorkspace.shared.open(monitor.folder) }
        @objc private func exportCSV() { monitor.exportCSV() }
        @objc private func rescan() {
            monitor.refresh(force: true)
            if monitor.showDailyHistory { monitor.refreshDaily(force: true) }
        }
        @objc private func explainCloud() { monitor.explainCloudSessions() }
        @objc private func quit() { NSApp.terminate(nil) }
    }
}
