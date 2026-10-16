import AppKit
import SwiftUI
#if SWIFT_PACKAGE
import SpeedCore
#endif

@MainActor
final class Monitor: ObservableObject {
    @Published var sessions: [SessionSnapshot] = [] { didSet { invalidateStatistics() } }
    @Published var selectedID = "automatic" { didSet { invalidateStatistics() } }
    @Published var now = Date() { didSet { invalidateStatistics() } }
    @Published var message: String?
    @Published var folder: URL
    @Published var pinned = false
    @Published var history: [SpeedPoint] = []
    @Published var metric: SpeedMetric = .continuousOutput { didSet { invalidateStatistics() } }
    @Published var includeSubagents = true { didSet { invalidateStatistics() } }
    @Published var includeAutoReview = false { didSet { invalidateStatistics() } }
    @Published var showDailyHistory = false
    @Published var dailySelectedDay = "today"
    @Published var dailyResult: DailyScanResult?
    @Published var language = L10n.preference {
        didSet {
            guard language != oldValue else { return }
            L10n.preference = language
            localizationChanged()
        }
    }
    private let dailyWorker = DispatchQueue(label: "local.codexspeed.daily-reader", qos: .utility)
    private var dailyScanner: DailyStatisticsScanner
    private var dailyBusy = false
    private var lastDailyScan = Date.distantPast
    private let worker = DispatchQueue(label: "local.codexspeed.log-reader", qos: .utility)
    private var scanner: LogScanner
    private var timer: Timer?
    private var timerInterval: TimeInterval = 0
    private var started = false
    private var observer: SessionDirectoryObserver?
    private var eventRefresh: DispatchWorkItem?
    private var eventNeedsDiscovery = false
    private var eventLogPaths = Set<String>()
    private var pendingLogPaths = Set<String>()
    private var lastLiveScan = Date.distantPast
    private var refreshPending = false
    private var pendingForce = false
    private var dailyRevision = 0
    private var appliedDailyRevision = -1
    private(set) var detailsVisible = false
    private var cachedSession: SessionSnapshot?
    private var sessionResolved = false
    private var cachedGlobal: GlobalSpeed?
    private var cachedCurrent: GlobalSpeed?
    private var cachedRound: FamilyRound?
    private var cachedCountedAgents: [AgentSnapshot]?
    private let dayFormatter: DateFormatter = {
        let value = DateFormatter()
        value.calendar = Calendar(identifier: .gregorian)
        value.locale = Locale(identifier: "en_US_POSIX")
        value.dateFormat = "yyyy-MM-dd"
        return value
    }()
    private var busy = false
    private var generation = 0
    private var historyTurn = ""
    private var historySampleAt: Date?
    var didUpdate: (() -> Void)?

    init() {
        let saved = UserDefaults.standard.string(forKey: "sessionsPath")
        let base = ProcessInfo.processInfo.environment["CODEX_HOME"]
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path
        let directory = URL(fileURLWithPath: saved ?? URL(fileURLWithPath: base).appendingPathComponent("sessions").path)
        folder = directory
        scanner = LogScanner(directory: directory)
        dailyScanner = DailyStatisticsScanner(directory: directory)
        selectedID = UserDefaults.standard.string(forKey: "selectedSessionID") ?? "automatic"
        includeSubagents = UserDefaults.standard.object(forKey: "includeSubagents") as? Bool ?? true
        includeAutoReview = UserDefaults.standard.bool(forKey: "includeAutoReview")
        // Adopt the requested output-only default once when upgrading. Further
        // launches keep the user's explicit choice among the three modes.
        if UserDefaults.standard.bool(forKey: "outputTimingDefaultApplied") {
            if let savedMetric = UserDefaults.standard.string(forKey: "speedMetric"),
               let metric = SpeedMetric(rawValue: savedMetric) { self.metric = metric }
        } else {
            UserDefaults.standard.set(true, forKey: "outputTimingDefaultApplied")
            UserDefaults.standard.set(SpeedMetric.continuousOutput.rawValue, forKey: "speedMetric")
        }
    }
    private func invalidateStatistics() {
        sessionResolved = false; cachedSession = nil
        cachedGlobal = nil; cachedCurrent = nil; cachedRound = nil
        cachedCountedAgents = nil
    }
    var session: SessionSnapshot? {
        if sessionResolved { return cachedSession }
        let value = selectedID != "automatic" ? sessions.first { $0.id == selectedID }
            : sessions.first { $0.isActive(at: now, includeSubagents: includeSubagents, includeAutoReview: includeAutoReview) } ?? sessions.first
        cachedSession = value; sessionResolved = true
        return value
    }
    var turn: Turn? { session?.latest?.filteringAutoReview(includeAutoReview) }
    var round: FamilyRound? {
        if let cachedRound { return cachedRound }
        guard let session, let turn else { return nil }
        // Use the original turn: projecting the same turn twice would subtract
        // review tokens twice. The round owns the single projection.
        let value = session.round(for: session.latest ?? turn, includeSubagents: includeSubagents, includeAutoReview: includeAutoReview)
        cachedRound = value
        return value
    }
    var totalUsage: Usage { session?.usage(includeSubagents: includeSubagents, includeAutoReview: includeAutoReview) ?? Usage() }
    var countedAgents: [AgentSnapshot] {
        if let cachedCountedAgents { return cachedCountedAgents }
        guard let session else { return [] }
        let value = (includeSubagents ? session.participants : [session.own])
            .map { $0.filteringAutoReview(includeAutoReview) }.filter { !$0.isCompletelyExcluded }
        cachedCountedAgents = value
        return value
    }
    var mainUsage: Usage { session?.own.usage(includeAutoReview: includeAutoReview) ?? Usage() }
    var childUsage: Usage { session?.childUsage(includeAutoReview: includeAutoReview) ?? Usage() }
    var activeSubagentCount: Int { session?.agents.filter { $0.isActive(at: now, includeAutoReview: includeAutoReview) }.count ?? 0 }
    var totalsAreComplete: Bool { countedAgents.allSatisfy { !$0.isLoading && $0.hasCumulativeUsage && $0.error == nil } }
    var isLoading: Bool { countedAgents.contains { $0.isLoading } }
    var scopeText: String {
        let agents = includeSubagents ? L10n.text("含子 agent") : L10n.text("仅主 agent")
        return includeAutoReview ? agents : agents + " · " + L10n.text("不含 auto review")
    }
    var global: GlobalSpeed {
        if let cachedGlobal { return cachedGlobal }
        let value = GlobalSpeed(sessions: sessions, at: now, metric: metric, includeSubagents: includeSubagents, includeAutoReview: includeAutoReview)
        cachedGlobal = value; return value
    }
    var currentSpeed: GlobalSpeed {
        if let cachedCurrent { return cachedCurrent }
        let value = GlobalSpeed(sessions: session.map { [$0] } ?? [], at: now, metric: metric, includeSubagents: includeSubagents, includeAutoReview: includeAutoReview)
        cachedCurrent = value; return value
    }
    func agentRate(_ agent: AgentSnapshot) -> Double? {
        guard !agent.isLoading, let turn = agent.latest else { return nil }
        let sampleAt = turn.end ?? (agent.isActive(at: now) ? now : turn.lastUsageAt ?? agent.modifiedAt)
        return turn.rate(at: sampleAt, metric: metric)
    }
    var isLive: Bool { global.activeAgents > 0 }
    var rate: Double? { global.sum }
    var metricTitle: String {
        switch metric {
        case .continuousOutput: return L10n.text("连续输出（估算）")
        case .excludingTools: return L10n.text("扣工具均速（估算）")
        case .wholeTurn: return L10n.text("本轮均速")
        }
    }
    var metricExplanation: String {
        let globalNote = L10n.text("菜单栏上行是所有活动聊天的速度合计，下行是当前选中会话的速度。两行均为%@；完成或空闲 agent 不参与当前速度。启用子 agent 时，其历史 token 仍计入累计。\n", scopeText)
        if metric == .continuousOutput {
            if global.sampledAgents == 0 {
                return globalNote + L10n.text("等待有完整输出起止记录的活跃调用；缺少样本时显示 —。")
            }
            return globalNote + L10n.text("连续输出按每个 agent 的有效输出阶段估算，排除段前等待与段间工具时间。含推理及工具参数；日志起点未精确到首个 token。")
        }
        if metric == .wholeTurn {
            return globalNote + L10n.text("每个 agent 的整轮均速 = 已统计输出 ÷ 本轮耗时，含工具与等待时间。")
        }
        return globalNote + L10n.text("扣工具模式仍含网络、输入处理等开销，无法表示纯模型解码速度。")
    }
    var status: String {
        if message != nil, session == nil { return L10n.text("等待日志") }
        if !isLive { return L10n.text("暂无活动") }
        return global.sampledAgents > 0 ? L10n.text("全局运行中") : L10n.text("等待首次统计")
    }
    var sampleAge: String {
        let sampleAt = global.sampleAt
        guard let time = sampleAt else { return L10n.text("等待可计算的输出记录") }
        let seconds = max(0, Int(now.timeIntervalSince(time)))
        return seconds < 2 ? L10n.text("刚刚更新") : L10n.text("统计更新于 %@前", durationText(Double(seconds)))
    }
    var firstVisibleDelayText: String {
        if let delay = turn?.firstVisibleOutputDelay { return String(format: L10n.text("≈ %.2f秒"), delay) }
        guard let turn, turn.hasKnownStart, turn.hasCompleteTimeline else { return L10n.text("无完整记录") }
        return session?.own.isActive(at: now) == true ? L10n.text("等待首段文字记录") : L10n.text("未记录可见文字")
    }
    func start() {
        started = true
        observeDirectory()
        refresh(force: true)
    }
    func stop() {
        started = false; detailsVisible = false; generation += 1
        timer?.invalidate(); timer = nil
        eventRefresh?.cancel(); eventRefresh = nil
        observer = nil
    }
    private func observeDirectory() {
        eventRefresh?.cancel(); eventRefresh = nil; eventNeedsDiscovery = false
        eventLogPaths.removeAll(); pendingLogPaths.removeAll()
        let currentGeneration = generation
        observer = SessionDirectoryObserver(directory: folder) { [weak self] change in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.started, self.generation == currentGeneration else { return }
                self.dailyRevision += 1
                self.eventNeedsDiscovery = self.eventNeedsDiscovery || change.requiresDiscovery
                self.eventLogPaths.formUnion(change.modifiedLogs)
                guard self.eventRefresh == nil else { return }
                let work = DispatchWorkItem { [weak self] in
                    guard let self, self.started, self.generation == currentGeneration else { return }
                    self.eventRefresh = nil
                    let force = self.eventNeedsDiscovery; self.eventNeedsDiscovery = false
                    self.refresh(force: force)
                }
                self.eventRefresh = work
                let delay = max(0.15, 1 - Date().timeIntervalSince(self.lastLiveScan))
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            }
        }
    }
    private func scheduleTimer() {
        guard started else { timer?.invalidate(); timer = nil; return }
        let interval = sessions.contains(where: \.isLoading) ? 0.25 : RefreshPolicy.interval(isActive: isLive, isVisible: detailsVisible,
                                              isObserving: observer?.isWatching == true)
        // File events must not keep postponing the timer: history refresh and
        // elapsed-time updates still need a steady cadence during busy streams.
        if timer?.isValid == true, timerInterval == interval { return }
        timer?.invalidate(); timerInterval = interval
        let next = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        next.tolerance = min(3, interval * 0.1)
        timer = next
        RunLoop.main.add(next, forMode: .common)
    }
    func setDetailsVisible(_ visible: Bool) {
        guard detailsVisible != visible else { return }
        detailsVisible = visible
        if visible {
            now = Date()
            if detailsVisible && showDailyHistory { refreshDaily() }
            refresh()
        } else { scheduleTimer() }
    }
    func systemDidWake() {
        dailyRevision += 1
        refresh(force: true)
        if detailsVisible && showDailyHistory { refreshDaily(force: true) }
    }
    func localizationChanged() {
        objectWillChange.send()
        didUpdate?()
        refresh(force: true)
        if detailsVisible && showDailyHistory { refreshDaily() }
    }
    private func tick() {
        refresh()
        if detailsVisible && showDailyHistory {
            let elapsed = Date().timeIntervalSince(lastDailyScan)
            let changed = dailyRevision != appliedDailyRevision || observer?.isWatching != true || elapsed >= 60
            if dailyResult?.isLoading != false || (changed && elapsed >= 10) { refreshDaily() }
        }
    }
    var todayKey: String {
        dayFormatter.timeZone = TimeZone(identifier: dailyResult?.timeZoneIdentifier ?? TimeZone.current.identifier) ?? .current
        return dayFormatter.string(from: now)
    }
    var selectedDailyUsage: DailyUsage? {
        dailyResult?.days.first { $0.day == (dailySelectedDay == "today" ? todayKey : dailySelectedDay) }
    }
    func refreshDaily(force: Bool = false) {
        guard !dailyBusy else { return }
        dailyBusy = true
        lastDailyScan = Date()
        let revision = dailyRevision
        let scanner = dailyScanner
        let currentGeneration = generation
        let include = includeSubagents
        let includeReview = includeAutoReview
        let languageCode = L10n.current.languageCode
        dailyWorker.async { [weak self] in
            let result = scanner.scan(includeSubagents: include, includeAutoReview: includeReview, force: force)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.dailyBusy = false
                guard self.generation == currentGeneration, self.includeSubagents == include,
                      self.includeAutoReview == includeReview,
                      L10n.current.languageCode == languageCode else {
                    if self.detailsVisible && self.showDailyHistory { self.refreshDaily(force: true) }; return
                }
                self.dailyResult = result
                self.appliedDailyRevision = revision
                if result.isLoading && self.detailsVisible && self.showDailyHistory {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                        if self?.detailsVisible == true && self?.showDailyHistory == true { self?.refreshDaily() }
                    }
                }
            }
        }
    }
    func refresh(force: Bool = false) {
        let requestedForce = force || eventNeedsDiscovery
        let changedPaths = eventLogPaths
        eventLogPaths.removeAll()
        eventNeedsDiscovery = false
        eventRefresh?.cancel(); eventRefresh = nil
        guard !busy else {
            refreshPending = true; pendingForce = pendingForce || requestedForce
            pendingLogPaths.formUnion(changedPaths); return
        }
        let force = requestedForce || pendingForce
        let paths = changedPaths.union(pendingLogPaths)
        pendingLogPaths.removeAll()
        pendingForce = false; refreshPending = false
        busy = true
        lastLiveScan = Date()
        let discoveryInterval = RefreshPolicy.discoveryInterval(isObserving: observer?.isWatching == true)
        let scanner = scanner
        let currentGeneration = generation
        let preferredID = selectedID
        let includeReview = includeAutoReview
        let languageCode = L10n.current.languageCode
        worker.async { [weak self] in
            let result = scanner.scan(force: force, preferredID: preferredID, discoveryInterval: discoveryInterval,
                                      changedLogPaths: paths, includeAutoReview: includeReview)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.busy = false
                guard self.generation == currentGeneration, L10n.current.languageCode == languageCode,
                      self.includeAutoReview == includeReview else {
                    if self.started { self.refresh(force: true) }; return
                }
                self.sessions = result.sessions
                self.message = result.message
                self.now = Date()
                self.updateHistory()
                self.didUpdate?()
                if self.refreshPending { self.refresh() }
                else { self.scheduleTimer() }
            }
        }
    }
    func selectionChanged() {
        UserDefaults.standard.set(selectedID, forKey: "selectedSessionID")
        refresh(force: true); didUpdate?()
    }
    func aggregationChanged() {
        UserDefaults.standard.set(includeSubagents, forKey: "includeSubagents")
        dailyResult = nil; lastDailyScan = .distantPast
        if detailsVisible && showDailyHistory { refreshDaily() }
        historyTurn = ""; history.removeAll(); historySampleAt = nil
        updateHistory(); didUpdate?()
    }
    func autoReviewChanged() {
        UserDefaults.standard.set(includeAutoReview, forKey: "includeAutoReview")
        dailyResult = nil; lastDailyScan = .distantPast
        if detailsVisible && showDailyHistory { refreshDaily() }
        historyTurn = ""; history.removeAll(); historySampleAt = nil
        updateHistory(); didUpdate?(); refresh()
    }
    func metricChanged() {
        UserDefaults.standard.set(metric.rawValue, forKey: "speedMetric")
        historyTurn = ""; history.removeAll(); historySampleAt = nil
        updateHistory(); didUpdate?()
    }
    func explainCloudSessions() {
        let alert = NSAlert()
        alert.messageText = L10n.text("云端会话暂时无法统计速度")
        alert.informativeText = L10n.text("当前应用读取本机 Codex 日志。云端聊天没有写入本机日志时不会出现在列表中。聊天内容和工具记录不能代替输出 token 用量与模型请求计时；缺少这些数据时无法计算 tok/s。")
        alert.addButton(withTitle: L10n.text("知道了"))
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
    private func updateHistory() {
        let key = metric.rawValue + ":global:" + String(includeSubagents) + ":review:" + String(includeAutoReview)
        if key != historyTurn {
            historyTurn = key; history.removeAll(); historySampleAt = nil
        }
        let latestSample = global.sampleAt
        guard let sampleAt = latestSample, sampleAt != historySampleAt,
              let value = global.sum else { return }
        historySampleAt = sampleAt
        history.append(SpeedPoint(time: sampleAt, value: value))
        if history.count > 36 { history.removeFirst(history.count - 36) }
    }
    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = L10n.text("选择 Codex 的 sessions 日志文件夹")
        panel.message = L10n.text("通常位于 ~/.codex/sessions；也可以选择自定义的 Codex 日志目录。")
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = folder.deletingLastPathComponent()
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, var url = panel.url else { return }
        if FileManager.default.fileExists(atPath: url.appendingPathComponent("sessions").path) {
            url.appendPathComponent("sessions")
        }
        folder = url
        UserDefaults.standard.set(url.path, forKey: "sessionsPath")
        scanner = LogScanner(directory: url); generation += 1
        dailyScanner = DailyStatisticsScanner(directory: url)
        dailyResult = nil; dailySelectedDay = "today"; lastDailyScan = .distantPast
        observeDirectory()
        if detailsVisible && showDailyHistory { refreshDaily(force: true) }
        sessions = []; selectedID = "automatic"; history = []
        message = nil; didUpdate?(); refresh(force: true)
    }
    func exportCSV() {
        guard let csv = csvContents() else { return }
        let panel = NSSavePanel()
        panel.title = L10n.text("导出最近的速度记录")
        panel.nameFieldStringValue = "Codex-Speed.csv"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try csv.write(to: url, atomically: true, encoding: .utf8) }
        catch { message = L10n.text("导出失败：%@", error.localizedDescription) }
    }
    func csvContents() -> String? {
        guard let session else { return nil }
        var csv = "turn_id,model,start,completed,output_tokens,reasoning_tokens,input_tokens,calls,elapsed_seconds,average_tokens_per_second,tool_seconds_to_sample,non_tool_seconds_to_sample,non_tool_average_tokens_per_second,continuous_output_tokens,continuous_output_seconds,continuous_output_calls,continuous_output_estimated_tokens_per_second,turn_first_token_delay_seconds,first_visible_output_delay_estimated_seconds,selected_metric,thread_id,agent,root_turn_id,row_scope\n"
        let formatter = ISO8601DateFormatter()
        func quote(_ string: String) -> String { "\"" + string.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        func decimal(_ value: Double?) -> String { value.map { String(format: "%.3f", $0) } ?? "" }
        for agent in countedAgents {
          for turn in agent.turns where turn.hasUsage {
            var fields: [String] = [turn.id, turn.model, formatter.string(from: turn.start),
                turn.end.map(formatter.string(from:)) ?? "", String(turn.usage.output),
                String(turn.usage.reasoning), String(turn.usage.input), String(turn.calls)]
            fields += [decimal(turn.duration(at: now)), decimal(turn.rate(at: now)),
                decimal(turn.toolSecondsToSample), decimal(turn.nonToolSecondsToSample),
                decimal(turn.rateExcludingTools)]
            fields += [String(turn.continuousOutputTokens), decimal(turn.continuousOutputSeconds),
                String(turn.continuousOutputCalls),
                decimal(turn.continuousOutputRate), decimal(turn.timeToFirstToken),
                decimal(turn.firstVisibleOutputDelay), metric.rawValue,
                agent.id, agent.id == session.id ? L10n.text("主 agent") : agent.label, turn.rootTurnID ?? "", "agent_turn"]
            csv += fields.map(quote).joined(separator: ",") + "\n"
          }
          var total = Array(repeating: "", count: 24)
          total[4] = String(agent.totalUsage.output); total[5] = String(agent.totalUsage.reasoning)
          total[6] = String(agent.totalUsage.input); total[20] = agent.id; total[21] = agent.label
          total[23] = "agent_lifetime"
          csv += total.map(quote).joined(separator: ",") + "\n"
        }
        var total = Array(repeating: "", count: 24)
        total[4] = String(totalUsage.output); total[5] = String(totalUsage.reasoning)
        total[6] = String(totalUsage.input); total[20] = session.id; total[21] = session.label
        total[23] = "family_lifetime"
        csv += total.map(quote).joined(separator: ",") + "\n"
        return csv
    }
}

struct SpeedPoint { var time: Date; var value: Double }

func rateText(_ value: Double?) -> String {
    guard let value, value.isFinite else { return "—" }
    if value >= 1000 { return String(format: "%.1fk", value / 1000) }
    return String(format: "%.1f", value)
}
func tokenText(_ number: Int) -> String {
    if number >= 1_000_000 { return String(format: "%.1fM", Double(number) / 1_000_000) }
    if number >= 1000 { return String(format: "%.1fk", Double(number) / 1000) }
    return String(number)
}
func durationText(_ seconds: Double) -> String {
    let value = max(0, Int(seconds))
    if value >= 3600 { return L10n.text("%@小时%@分", value / 3600, value % 3600 / 60) }
    if value >= 60 { return L10n.text("%@分%@秒", value / 60, value % 60) }
    return L10n.text("%@秒", value)
}
