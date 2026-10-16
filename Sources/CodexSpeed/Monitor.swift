import AppKit
import SwiftUI
#if SWIFT_PACKAGE
import SpeedCore
#endif

@MainActor
final class Monitor: ObservableObject {
    @Published var sessions: [SessionSnapshot] = []
    @Published var selectedID = "automatic"
    @Published var now = Date()
    @Published var message: String?
    @Published var folder: URL
    @Published var pinned = false
    @Published var history: [SpeedPoint] = []
    @Published var metric: SpeedMetric = .continuousOutput
    @Published var includeSubagents = true
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
    var session: SessionSnapshot? {
        if selectedID != "automatic" { return sessions.first { $0.id == selectedID } }
        let recentActive = sessions.filter { includeSubagents ? $0.isActive(at: now) : $0.own.isActive(at: now) }
        return recentActive.first ?? sessions.first
    }
    var turn: Turn? { session?.latest }
    var round: FamilyRound? {
        guard let session, let turn else { return nil }
        return session.round(for: turn, includeSubagents: includeSubagents)
    }
    var totalUsage: Usage { session?.usage(includeSubagents: includeSubagents) ?? Usage() }
    var countedAgents: [AgentSnapshot] {
        guard let session else { return [] }
        return includeSubagents ? session.participants : [session.own]
    }
    var totalsAreComplete: Bool { countedAgents.allSatisfy { !$0.isLoading && $0.hasCumulativeUsage && $0.error == nil } }
    var isLoading: Bool { countedAgents.contains { $0.isLoading } }
    var scopeText: String { includeSubagents ? L10n.text("含子 agent") : L10n.text("仅主 agent") }
    var global: GlobalSpeed { GlobalSpeed(sessions: sessions, at: now, metric: metric, includeSubagents: includeSubagents) }
    var currentSpeed: GlobalSpeed { GlobalSpeed(sessions: session.map { [$0] } ?? [], at: now, metric: metric, includeSubagents: includeSubagents) }
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
        refresh(force: true)
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }
    func localizationChanged() {
        objectWillChange.send()
        didUpdate?()
        refresh(force: true)
        if showDailyHistory { refreshDaily() }
    }
    private func tick() {
        now = Date()
        didUpdate?()
        refresh()
        if showDailyHistory && (dailyResult?.isLoading != false || now.timeIntervalSince(lastDailyScan) >= 10) {
            refreshDaily()
        }
    }
    var todayKey: String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: dailyResult?.timeZoneIdentifier ?? TimeZone.current.identifier) ?? .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: now)
    }
    var selectedDailyUsage: DailyUsage? {
        dailyResult?.days.first { $0.day == (dailySelectedDay == "today" ? todayKey : dailySelectedDay) }
    }
    func refreshDaily(force: Bool = false) {
        guard !dailyBusy else { return }
        dailyBusy = true
        lastDailyScan = Date()
        let scanner = dailyScanner
        let currentGeneration = generation
        let include = includeSubagents
        let languageCode = L10n.current.languageCode
        dailyWorker.async { [weak self] in
            let result = scanner.scan(includeSubagents: include, force: force)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.dailyBusy = false
                guard self.generation == currentGeneration, self.includeSubagents == include,
                      L10n.current.languageCode == languageCode else {
                    if self.showDailyHistory { self.refreshDaily(force: true) }; return
                }
                self.dailyResult = result
                if result.isLoading && self.showDailyHistory {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                        if self?.showDailyHistory == true { self?.refreshDaily() }
                    }
                }
            }
        }
    }
    func refresh(force: Bool = false) {
        guard !busy else { return }
        busy = true
        let scanner = scanner
        let currentGeneration = generation
        let preferredID = selectedID
        let languageCode = L10n.current.languageCode
        worker.async { [weak self] in
            let result = scanner.scan(force: force, preferredID: preferredID)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.busy = false
                guard self.generation == currentGeneration, L10n.current.languageCode == languageCode else {
                    self.refresh(force: true); return
                }
                self.sessions = result.sessions
                self.message = result.message
                self.now = Date()
                self.updateHistory()
                self.didUpdate?()
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
        if showDailyHistory { refreshDaily() }
        historyTurn = ""; history.removeAll(); historySampleAt = nil
        updateHistory(); didUpdate?()
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
        let key = metric.rawValue + ":global:" + String(includeSubagents)
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
        if showDailyHistory { refreshDaily(force: true) }
        sessions = []; selectedID = "automatic"; history = []
        message = nil; didUpdate?(); refresh(force: true)
    }
    func exportCSV() {
        guard let session else { return }
        let panel = NSSavePanel()
        panel.title = L10n.text("导出最近的速度记录")
        panel.nameFieldStringValue = "Codex-Speed.csv"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var csv = "turn_id,model,start,completed,output_tokens,reasoning_tokens,input_tokens,calls,elapsed_seconds,average_tokens_per_second,tool_seconds_to_sample,non_tool_seconds_to_sample,non_tool_average_tokens_per_second,continuous_output_tokens,continuous_output_seconds,continuous_output_calls,continuous_output_estimated_tokens_per_second,turn_first_token_delay_seconds,first_visible_output_delay_estimated_seconds,selected_metric,thread_id,agent,root_turn_id,row_scope\n"
        let formatter = ISO8601DateFormatter()
        func quote(_ string: String) -> String { "\"" + string.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        func decimal(_ value: Double?) -> String { value.map { String(format: "%.3f", $0) } ?? "" }
        for agent in countedAgents {
          for turn in agent.turns {
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
        do { try csv.write(to: url, atomically: true, encoding: .utf8) }
        catch { message = L10n.text("导出失败：%@", error.localizedDescription) }
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
