import AppKit
import SwiftUI
#if SWIFT_PACKAGE
import SpeedCore
#endif

@MainActor
final class MenuReadout: NSView {
    var speed = "Σ — tok/s"
    var current = "当前 — tok/s"
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .medium),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph
        ]
        (speed as NSString).draw(in: NSRect(x: 0, y: 11.5, width: bounds.width, height: 13), withAttributes: attrs)
        (current as NSString).draw(in: NSRect(x: 0, y: 0, width: bounds.width, height: 13), withAttributes: attrs)
    }
}

@MainActor
final class DropdownPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let monitor = Monitor()
    var dropdown: NSPanel?
    var statusItem: NSStatusItem!
    let readout = MenuReadout(frame: NSRect(x: 0, y: 0, width: 104, height: 25))
    var panel: NSPanel?
    var localClickMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: 104)
        guard let button = statusItem.button else { return }
        readout.frame = button.bounds
        readout.autoresizingMask = [.width, .height]
        button.addSubview(readout)
        button.target = self; button.action = #selector(click)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.setAccessibilityLabel("Codex Speed 速度监测")
        monitor.didUpdate = { [weak self] in self?.updateReadout() }
        monitor.start()
        updateReadout()
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53, self.dropdown?.isVisible == true { self.closeDropdown(); return nil }
                return event
            }
            if let dropdown = self.dropdown, event.window !== dropdown,
               event.window !== self.statusItem.button?.window {
                self.closeDropdown()
            }
            return event
        }
        NotificationCenter.default.addObserver(self, selector: #selector(displaysChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(showDetails),
            name: Notification.Name("local.codexspeed.monitor.showDetails"), object: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.showDetails() }
    }
    private var dashboard: Dashboard {
        Dashboard(monitor: monitor, onPin: { [weak self] in self?.togglePin() })
    }
    private func updateReadout() {
        let global = monitor.global
        readout.speed = "Σ \(rateText(global.sum)) tok/s"
        readout.current = "当前 \(rateText(monitor.currentSpeed.sum)) tok/s"
        readout.needsDisplay = true
        let description = "全局 \(monitor.metricTitle) · \(readout.speed) · \(readout.current)\n\(global.activeChats) 个活跃聊天 · \(global.sampledAgents)/\(global.activeAgents) 个 agent 会话有速度样本（\(monitor.scopeText)）\n当前会话：\(monitor.session?.label ?? "等待会话")"
        statusItem.button?.toolTip = description + "\n点击查看详情；右键退出。"
        statusItem.button?.setAccessibilityValue(description)
    }
    @objc func click() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            menu.addItem(withTitle: "查看速度详情", action: #selector(showDetails), keyEquivalent: "").target = self
            menu.addItem(withTitle: monitor.pinned ? "收起悬浮侧栏" : "显示悬浮侧栏", action: #selector(togglePin), keyEquivalent: "").target = self
            menu.addItem(NSMenuItem.separator())
            menu.addItem(withTitle: "退出 Codex Speed", action: #selector(quit), keyEquivalent: "q").target = self
            // Attaching a menu to NSStatusItem takes over its button tracking.
            // Keep the original click target intact across context-menu use.
            if let button = statusItem.button {
                closeDropdown()
                menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY), in: button)
            }
            return
        }
        if dropdown?.isVisible == true { closeDropdown() }
        else { showDetails() }
    }
    @objc func showDetails() {
        if monitor.pinned, let panel {
            constrainPanel()
            panel.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            return
        }
        monitor.pinned = false
        guard let placement = dropdownPlacement() else { return }
        closeDropdown()
        let window = DropdownPanel(contentRect: placement, styleMask: [.borderless], backing: .buffered, defer: false)
        window.title = "Codex Speed"
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.level = .popUpMenu
        window.hidesOnDeactivate = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        installDashboard(in: window, size: placement.size, rounded: true)
        window.setFrame(placement, display: true)
        dropdown = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
    @objc func togglePin() {
        if monitor.pinned {
            panel?.close(); panel = nil; monitor.pinned = false
            showDetails()
            return
        }
        let sourceFrame = dropdown?.frame
        let screen = anchorScreen() ?? NSScreen.main
        closeDropdown()
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 620),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered, defer: false)
        window.title = "Codex Speed"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.hidesOnDeactivate = false
        window.delegate = self
        if let screen {
            let visible = screen.visibleFrame
            var frame = window.frame
            frame.origin = sourceFrame.map { NSPoint(x: $0.minX, y: $0.maxY - frame.height) }
                ?? NSPoint(x: visible.maxX - frame.width - 16, y: visible.maxY - frame.height - 16)
            window.setFrame(ScreenPlacement.constrained(frame, to: visible), display: false)
        }
        installDashboard(in: window, size: window.contentLayoutRect.size, rounded: false)
        panel = window; monitor.pinned = true
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === panel else { return }
        monitor.pinned = false; panel = nil
    }
    func windowDidChangeScreen(_ notification: Notification) { constrainPanel() }
    func applicationDidResignActive(_ notification: Notification) { closeDropdown() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showDetails(); return true
    }
    private func closeDropdown() {
        dropdown?.orderOut(nil); dropdown = nil
    }
    private func anchorRect() -> NSRect? {
        guard let button = statusItem.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }
    private func anchorScreen() -> NSScreen? {
        guard let anchor = anchorRect() else { return statusItem.button?.window?.screen }
        return NSScreen.screens.first { $0.frame.intersects(anchor) }
            ?? statusItem.button?.window?.screen
    }
    private func dropdownPlacement() -> NSRect? {
        guard let screen = anchorScreen() ?? NSScreen.main ?? NSScreen.screens.first else { return nil }
        let anchor = anchorRect() ?? NSRect(x: screen.visibleFrame.maxX - 224,
            y: screen.visibleFrame.maxY + 6, width: 104, height: 25)
        var stableAnchor = anchor
        if anchor.minY < screen.visibleFrame.maxY - 40 {
            stableAnchor.origin.x = screen.visibleFrame.maxX - 224
            stableAnchor.origin.y = screen.visibleFrame.maxY + 6
        }
        let result = ScreenPlacement.dropdown(anchor: stableAnchor, visible: screen.visibleFrame,
            size: NSSize(width: 360, height: 620))
        NSLog("Codex Speed placement: anchor %@, status window %@, visible %@, result %@",
            NSStringFromRect(anchor), NSStringFromRect(statusItem.button?.window?.frame ?? .zero),
            NSStringFromRect(screen.visibleFrame), NSStringFromRect(result))
        return result
    }
    private func installDashboard(in window: NSWindow, size: NSSize, rounded: Bool) {
        // A bounded scroll container prevents hosting-view intrinsic-size changes
        // from resizing the window upward when history or error rows appear.
        let content = ScrollView(.vertical, showsIndicators: true) {
            dashboard.frame(maxWidth: .infinity, alignment: .top)
        }.frame(width: size.width, height: size.height, alignment: .top)
        let host = NSHostingView(rootView: content)
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: size)
        host.autoresizingMask = [.width, .height]
        let background = NSVisualEffectView(frame: host.frame)
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = rounded ? 16 : 0
        background.layer?.masksToBounds = true
        background.addSubview(host)
        window.contentView = background
    }
    private func constrainPanel() {
        guard let panel, let screen = panel.screen ?? anchorScreen() ?? NSScreen.main else { return }
        let corrected = ScreenPlacement.constrained(panel.frame, to: screen.visibleFrame)
        if corrected != panel.frame {
            panel.setFrame(corrected, display: true)
            installDashboard(in: panel, size: panel.contentLayoutRect.size, rounded: false)
        }
    }
    @objc private func displaysChanged() {
        if dropdown != nil { showDetails() }
        constrainPanel()
    }
    @objc func quit() { NSApp.terminate(nil) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
struct CodexSpeedMain {
    @MainActor
    static func main() {
        let arguments = CommandLine.arguments
        if arguments.count >= 3, arguments[1] == "--inspect-daily" {
            let zoneIndex = arguments.firstIndex(of: "--timezone")
            let zone = zoneIndex.flatMap { $0 + 1 < arguments.count ? TimeZone(identifier: arguments[$0 + 1]) : nil } ?? .current
            let scanner = DailyStatisticsScanner(directory: URL(fileURLWithPath: arguments[2]), timeZone: zone)
            let include = !arguments.contains("--main-only")
            var result = scanner.scan(includeSubagents: include, maxBytes: 32 * 1024 * 1024, force: true)
            for _ in 0..<10000 where result.isLoading {
                result = scanner.scan(includeSubagents: include, maxBytes: 32 * 1024 * 1024)
            }
            func totals(_ t: DailyTotals) -> [String: Any] {
                ["input_tokens": t.inputTokens, "output_tokens": t.outputTokens,
                 "reasoning_output_tokens": t.reasoningTokens, "cached_input_tokens": t.cachedInputTokens,
                 "cache_known_input_tokens": t.cacheKnownInputTokens, "requests": t.requests,
                 "cache_known_requests": t.cacheKnownRequests, "timed_requests": t.timedRequests,
                 "standard_requests": t.standardRequests, "fast_requests": t.fastRequests,
                 "unknown_tier_requests": t.unknownTierRequests,
                 "timed_output_tokens": t.timedOutputTokens, "output_seconds": t.outputSeconds,
                 "average_speed": t.averageSpeed as Any? ?? NSNull(),
                 "cache_hit_ratio": t.cacheHitRate as Any? ?? NSNull(),
                 "api_cost": ["total_usd": t.apiCost.totalUSD as Any? ?? NSNull(),
                     "priced_requests": t.apiCost.pricedRequests, "long_context_requests": t.apiCost.longContextRequests,
                     "uncached_input_usd": t.apiCost.uncachedInputUSD, "cached_input_usd": t.apiCost.cachedInputUSD,
                     "cache_write_usd": t.apiCost.cacheWriteUSD, "output_usd": t.apiCost.outputUSD]]
            }
            let days: [[String: Any]] = result.days.map { day in
                var row = totals(day.totals)
                row["date"] = day.day
                row["models"] = day.models.map { model -> [String: Any] in
                    var row = totals(model.totals); row["model"] = model.model; return row
                }
                return row
            }
            let report: [String: Any] = ["timezone": result.timeZoneIdentifier,
                "include_subagents": include, "is_loading": result.isLoading,
                "files_read": result.filesRead, "total_files": result.totalFiles,
                "message": result.message as Any? ?? NSNull(), "days": days,
                "price_checked_date": ApiPriceCatalog.checkedDate,
                "price_mode": "API equivalent USD by logged Standard/Fast setting; actual tier unverified"]
            let json = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            print(json.flatMap { String(data: $0, encoding: .utf8) } ?? "{}")
            return
        }
        if arguments.count >= 4, arguments[1] == "--inspect-session" {
            let scanner = LogScanner(directory: URL(fileURLWithPath: arguments[3]))
            var result = scanner.scan(force: true, preferredID: arguments[2])
            for _ in 0..<100 where result.sessions.contains(where: \.isLoading) {
                result = scanner.scan(preferredID: arguments[2])
            }
            guard let session = result.sessions.first(where: { $0.id == arguments[2] }) else {
                print("{\"error\":\"session not found\"}"); return
            }
            let includeSubagents = !arguments.contains("--main-only")
            let global = GlobalSpeed(sessions: result.sessions, at: Date(), metric: .continuousOutput, includeSubagents: includeSubagents)
            let current = GlobalSpeed(sessions: [session], at: Date(), metric: .continuousOutput, includeSubagents: includeSubagents)
            let usage = session.usage(includeSubagents: includeSubagents)
            let agents: [[String: Any]] = session.participants.map { agent in
                ["id": agent.id, "label": agent.label, "output": agent.totalUsage.output,
                 "input": agent.totalUsage.input, "reasoning": agent.totalUsage.reasoning,
                 "has_cumulative": agent.hasCumulativeUsage, "loading": agent.isLoading,
                 "active": agent.isActive(at: Date()), "configured_service_tier": agent.serviceTier.rawValue]
            }
            var report: [String: Any] = ["id": session.id, "label": session.label,
                "output": usage.output, "input": usage.input,
                "reasoning": usage.reasoning, "child_count": session.agents.count,
                "active_child_count": session.agents.filter { $0.isActive(at: Date()) }.count,
                "include_subagents": includeSubagents,
                "complete": session.totalsAreComplete, "agents": agents,
                "global_active_chats": global.activeChats, "global_active_agents": global.activeAgents,
                "global_sampled_agents": global.sampledAgents]
            report["global_sum"] = global.sum as Any? ?? NSNull()
            report["global_average"] = global.average as Any? ?? NSNull()
            report["current_sum"] = current.sum as Any? ?? NSNull()
            if let turn = session.latest {
                let round = session.round(for: turn, includeSubagents: includeSubagents)
                report["root_turn_id"] = round.main.id
                report["round_output"] = round.usage.output
                report["round_main_output"] = round.mainUsage.output
                report["round_child_output"] = round.childUsage.output
                report["round_child_count"] = round.childCount
            }
            let json = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            print(json.flatMap { String(data: $0, encoding: .utf8) } ?? "{}")
            return
        }
        if arguments.count >= 3, arguments[1] == "--inspect-log" {
            let log = SessionLog(url: URL(fileURLWithPath: arguments[2]))
            log.refresh(maxBytes: 8 * 1024 * 1024)
            let now = Date()
            let rows: [[String: Any]] = log.turns.map { turn in
                ["id": turn.id, "model": turn.model, "output_tokens": turn.usage.output,
                 "reasoning_tokens": turn.usage.reasoning, "calls": turn.calls,
                 "duration": turn.duration(at: now), "rate": turn.rate(at: now) as Any? ?? NSNull(),
                 "tool_seconds_to_sample": turn.toolSecondsToSample as Any? ?? NSNull(),
                 "non_tool_seconds_to_sample": turn.nonToolSecondsToSample as Any? ?? NSNull(),
                 "rate_excluding_tools": turn.rateExcludingTools as Any? ?? NSNull(),
                 "continuous_output_tokens": turn.continuousOutputTokens,
                 "continuous_output_seconds": turn.continuousOutputSeconds,
                 "continuous_output_calls": turn.continuousOutputCalls,
                 "continuous_output_estimated_rate": turn.continuousOutputRate as Any? ?? NSNull(),
                 "first_visible_output_estimated_delay": turn.firstVisibleOutputDelay as Any? ?? NSNull(),
                 "first_token_delay": turn.timeToFirstToken as Any? ?? NSNull(),
                 "complete_timeline": turn.hasCompleteTimeline,
                 "completed": turn.end != nil, "known_start": turn.hasKnownStart]
            }
            let json = try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
            print(json.flatMap { String(data: $0, encoding: .utf8) } ?? "[]")
            return
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        if arguments.count >= 3, arguments[1] == "--render-preview" {
            renderPreview(to: arguments[2]); return
        }
        if arguments.count >= 3, arguments[1] == "--make-icon" {
            makeIcon(to: arguments[2]); return
        }
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            DistributedNotificationCenter.default().postNotificationName(
                Notification.Name("local.codexspeed.monitor.showDetails"), object: nil,
                userInfo: nil, deliverImmediately: true)
            return
        }
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }

    @MainActor
    static func renderPreview(to path: String) {
        let monitor = Monitor()
        let scanner = LogScanner(directory: monitor.folder)
        let result = scanner.scan(force: true)
        monitor.sessions = result.sessions; monitor.message = result.message
        let view = NSHostingView(rootView: Dashboard(monitor: monitor, onPin: {}))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 650),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .windowBackgroundColor
        window.contentView = view
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.orderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        let size = view.fittingSize
        window.setContentSize(NSSize(width: 360, height: size.height))
        view.layoutSubtreeIfNeeded()
        guard let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: image)
        if let data = image.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
        window.orderOut(nil)
    }

    @MainActor
    static func makeIcon(to path: String) {
        let image = NSImage(size: NSSize(width: 1024, height: 1024))
        image.lockFocus()
        let background = NSBezierPath(roundedRect: NSRect(x: 62, y: 62, width: 900, height: 900),
            xRadius: 210, yRadius: 210)
        NSColor(calibratedRed: 0.075, green: 0.13, blue: 0.16, alpha: 1).setFill()
        background.fill()
        NSColor(calibratedRed: 0.27, green: 0.78, blue: 0.68, alpha: 1).setStroke()
        let signalPath = NSBezierPath()
        signalPath.lineWidth = 48; signalPath.lineCapStyle = .round; signalPath.lineJoinStyle = .round
        signalPath.move(to: NSPoint(x: 225, y: 488))
        for point in [NSPoint(x: 360, y: 488), NSPoint(x: 418, y: 670),
                      NSPoint(x: 506, y: 326), NSPoint(x: 598, y: 594),
                      NSPoint(x: 660, y: 488), NSPoint(x: 797, y: 488)] { signalPath.line(to: point) }
        signalPath.stroke()
        image.unlockFocus()
        guard let data = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: data),
              let png = bitmap.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
    }
}
