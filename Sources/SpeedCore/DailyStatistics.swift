import Foundation

public struct DailyTotals: Sendable, Equatable {
    public var inputTokens = 0
    public var outputTokens = 0
    public var reasoningTokens = 0
    public var cachedInputTokens = 0
    public var cacheKnownInputTokens = 0
    public var requests = 0
    public var cacheKnownRequests = 0
    public var timedRequests = 0
    public var standardRequests = 0
    public var fastRequests = 0
    public var unknownTierRequests = 0
    public var timedOutputTokens = 0
    public var outputSeconds: Double = 0
    public var apiCost = ApiCostTotals()
    public var averageSpeed: Double? {
        timedRequests > 0 && outputSeconds > 0 ? Double(timedOutputTokens) / outputSeconds : nil
    }
    public var cacheHitRate: Double? {
        cacheKnownInputTokens > 0 ? Double(cachedInputTokens) / Double(cacheKnownInputTokens) : nil
    }
    public init() {}
    mutating func add(_ other: DailyTotals, sign: Int = 1) {
        inputTokens += sign * other.inputTokens; outputTokens += sign * other.outputTokens
        reasoningTokens += sign * other.reasoningTokens; cachedInputTokens += sign * other.cachedInputTokens
        cacheKnownInputTokens += sign * other.cacheKnownInputTokens; requests += sign * other.requests
        standardRequests += sign * other.standardRequests; fastRequests += sign * other.fastRequests
        unknownTierRequests += sign * other.unknownTierRequests
        cacheKnownRequests += sign * other.cacheKnownRequests; timedRequests += sign * other.timedRequests
        timedOutputTokens += sign * other.timedOutputTokens; outputSeconds += Double(sign) * other.outputSeconds
        apiCost.add(other.apiCost, sign: sign)
        if timedRequests == 0 { outputSeconds = 0 }
    }
}

public struct DailyModelUsage: Identifiable, Sendable {
    public var model: String
    public var id: String { model }
    public var totals: DailyTotals
}

public struct DailyUsage: Identifiable, Sendable {
    public var day: String
    public var id: String { day }
    public var totals: DailyTotals
    public var models: [DailyModelUsage]
}

public struct DailyScanResult: Sendable {
    public var days: [DailyUsage]
    public var isLoading: Bool
    public var filesRead: Int
    public var totalFiles: Int
    public var message: String?
    public var timeZoneIdentifier: String
}

// Statistics-only request summaries. No prompt, response text, or tool output is
// retained. Per-request IDs survive the live reader's 40-turn retention window.
final class DailyLogStatistics {
    struct Request {
        var day: String
        var model: String
        var totals: DailyTotals
        var pricingUsage: ApiRequestUsage?
        var serviceTier: ApiServiceTier
    }
    private let dayFormatter: DateFormatter
    private var records: [String: Request] = [:]
    private var legacyByTurn: [String: Set<String>] = [:]
    private var pendingModelByTurn: [String: Set<String>] = [:]
    private var modelByTurn: [String: String] = [:]
    private var modernTurns = Set<String>()
    private var previousLegacyTotal: Usage?
    private var legacySequence = 0
    private(set) var buckets: [String: [String: DailyTotals]] = [:]
    private var legacyOmissionsByTurn: [String: Int] = [:]
    private var otherOmissions = 0
    var omittedRecords: Int { otherOmissions + legacyOmissionsByTurn.values.reduce(0, +) }
    private(set) var legacyRequests = 0

    init(timeZone: TimeZone) {
        dayFormatter = DateFormatter()
        dayFormatter.calendar = Calendar(identifier: .gregorian)
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.timeZone = timeZone
        dayFormatter.dateFormat = "yyyy-MM-dd"
    }
    func reset() {
        records.removeAll(); legacyByTurn.removeAll(); pendingModelByTurn.removeAll()
        modelByTurn.removeAll(); modernTurns.removeAll(); previousLegacyTotal = nil
        legacySequence = 0; buckets.removeAll(); legacyOmissionsByTurn.removeAll(); otherOmissions = 0; legacyRequests = 0
    }
    private func apply(_ record: Request, sign: Int) {
        var totals = buckets[record.day]?[record.model] ?? DailyTotals()
        totals.add(record.totals, sign: sign)
        if totals.requests == 0 {
            buckets[record.day]?.removeValue(forKey: record.model)
            if buckets[record.day]?.isEmpty == true { buckets.removeValue(forKey: record.day) }
        } else { buckets[record.day, default: [:]][record.model] = totals }
    }
    // A turn_context can arrive just after usage. Only unresolved records are
    // backfilled; later explicit model changes affect subsequent requests only.
    func setModel(_ model: String, for turnID: String) {
        modelByTurn[turnID] = model
        for key in pendingModelByTurn.removeValue(forKey: turnID) ?? [] {
            guard var record = records[key] else { continue }
            apply(record, sign: -1); record.model = model
            record.totals.apiCost = ApiPriceCatalog.estimate(model: model, usage: record.pricingUsage, serviceTier: record.serviceTier)
            records[key] = record; apply(record, sign: 1)
        }
    }
    private func insert(key: String, turnID: String, timestamp: Date?, usageJSON: [String: Any], outputSeconds: Double?, serviceTier: ApiServiceTier) {
        guard records[key] == nil else { return }
        guard let timestamp, timestamp.timeIntervalSince1970.isFinite else { otherOmissions += 1; return }
        let usage = Usage(usageJSON)
        var totals = DailyTotals()
        totals.inputTokens = usage.input; totals.outputTokens = usage.output
        totals.reasoningTokens = usage.reasoning; totals.requests = 1
        switch serviceTier {
        case .standard: totals.standardRequests = 1
        case .fast: totals.fastRequests = 1
        case .unknown: totals.unknownTierRequests = 1
        }
        if let number = (usageJSON["cached_input_tokens"] ?? usageJSON["input_cached_tokens"]) as? NSNumber,
           number.doubleValue.isFinite, number.doubleValue >= 0 {
            totals.cachedInputTokens = min(usage.input, number.intValue)
            totals.cacheKnownInputTokens = usage.input; totals.cacheKnownRequests = 1
        }
        if let seconds = outputSeconds, seconds.isFinite, seconds >= 0.1, usage.output > 0 {
            totals.timedRequests = 1; totals.timedOutputTokens = usage.output; totals.outputSeconds = seconds
        }
        let requestModel = modelByTurn[turnID] ?? "未知模型"
        let pricingUsage = ApiRequestUsage(usageJSON)
        totals.apiCost = ApiPriceCatalog.estimate(model: requestModel, usage: pricingUsage, serviceTier: serviceTier)
        let record = Request(day: dayFormatter.string(from: timestamp), model: requestModel, totals: totals, pricingUsage: pricingUsage, serviceTier: serviceTier)
        records[key] = record; apply(record, sign: 1)
        if modelByTurn[turnID] == nil { pendingModelByTurn[turnID, default: []].insert(key) }
    }
    func recordModern(responseID: String, turnID: String, timestamp: Date?, model: String,
                      usageJSON: [String: Any], outputSeconds: Double?, serviceTier: ApiServiceTier = .unknown) {
        modernTurns.insert(turnID)
        legacyOmissionsByTurn.removeValue(forKey: turnID)
        // Modern records replace provisional legacy statistics for this turn,
        // including when the two formats arrive in different scan batches.
        for key in legacyByTurn.removeValue(forKey: turnID) ?? [] {
            if let old = records.removeValue(forKey: key) { apply(old, sign: -1); legacyRequests -= 1 }
            pendingModelByTurn[turnID]?.remove(key)
        }
        insert(key: "modern:" + responseID, turnID: turnID, timestamp: timestamp,
               usageJSON: usageJSON, outputSeconds: outputSeconds, serviceTier: serviceTier)
    }
    func noteUnattributedLegacy(turnID: String?) {
        if let turnID {
            if !modernTurns.contains(turnID) { legacyOmissionsByTurn[turnID, default: 0] += 1 }
        } else { otherOmissions += 1 }
    }
    func recordLegacy(turnID: String, timestamp: Date?, model: String,
                      totalJSON: [String: Any], lastJSON: [String: Any]?, serviceTier: ApiServiceTier = .unknown) {
        let total = Usage(totalJSON)
        let previous = previousLegacyTotal
        previousLegacyTotal = total
        guard !modernTurns.contains(turnID), previous != total else { return }
        // A cumulative counter is not a daily request. Accept only a matching
        // explicit last request and delta (or a provable reset to that request).
        guard let lastJSON else { legacyOmissionsByTurn[turnID, default: 0] += 1; return }
        let last = Usage(lastJSON)
        let delta: Usage
        if let previous, total.input >= previous.input, total.output >= previous.output {
            delta = Usage(input: total.input - previous.input, output: total.output - previous.output,
                          reasoning: max(0, total.reasoning - previous.reasoning))
        } else { delta = total }
        guard delta == last else { legacyOmissionsByTurn[turnID, default: 0] += 1; return }
        legacySequence += 1
        let key = "legacy:\(legacySequence)"
        insert(key: key, turnID: turnID, timestamp: timestamp, usageJSON: lastJSON, outputSeconds: nil, serviceTier: serviceTier)
        if records[key] != nil { legacyByTurn[turnID, default: []].insert(key); legacyRequests += 1 }
    }
}

/// Full history is streamed on a background caller, with a shared byte budget
/// and a short work deadline per scan. Archive copies share one thread identity.
public final class DailyStatisticsScanner: @unchecked Sendable {
    public let directory: URL
    public let timeZone: TimeZone
    private let lock = NSLock()
    private var logs: [URL: SessionLog] = [:]
    private var files: [URL] = []
    private var lastDiscovery = Date.distantPast
    private var discoveryFailed = false
    private var cursor = 0

    public init(directory: URL, timeZone: TimeZone = .current) {
        self.directory = directory; self.timeZone = timeZone
    }
    public func scan(includeSubagents: Bool = true, maxBytes: Int = 16 * 1024 * 1024, force: Bool = false) -> DailyScanResult {
        lock.lock(); defer { lock.unlock() }
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return DailyScanResult(days: [], isLoading: false, filesRead: 0, totalFiles: 0,
                message: L10n.text("找不到 sessions 文件夹，无法读取每日历史。"), timeZoneIdentifier: timeZone.identifier)
        }
        let now = Date()
        if force || now.timeIntervalSince(lastDiscovery) >= 10 {
            discoveryFailed = false
            var folders = [directory]
            let archive = directory.deletingLastPathComponent().appendingPathComponent("archived_sessions")
            if directory.lastPathComponent == "sessions", fm.fileExists(atPath: archive.path) { folders.append(archive) }
            var found = Set<URL>()
            for folder in folders {
                guard let entries = fm.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles], errorHandler: { _, _ in self.discoveryFailed = true; return true }) else {
                    discoveryFailed = true; continue
                }
                for case let url as URL in entries where url.pathExtension == "jsonl" {
                    if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { found.insert(url) }
                }
            }
            logs = logs.filter { found.contains($0.key) }
            files = found.sorted { $0.path < $1.path }
            for url in files where logs[url] == nil {
                logs[url] = SessionLog(url: url, fullHistory: true, statisticsTimeZone: timeZone)
            }
            cursor = files.isEmpty ? 0 : cursor % files.count
            lastDiscovery = now
        }
        var remaining = max(0, maxBytes)
        let deadline = Date().addingTimeInterval(0.5)
        var visited = 0
        while remaining > 0, visited < files.count {
            let url = files[cursor]; cursor = (cursor + 1) % files.count; visited += 1
            if let log = logs[url] {
                log.refresh(maxBytes: min(remaining, 1024 * 1024))
                remaining -= log.lastReadByteCount
            }
            if Date() >= deadline { break }
        }
        // Prefer the most complete physical copy, then the most recently
        // modified one. Count each thread once even across archive moves.
        var selected: [String: SessionLog] = [:]
        var selectedSizes: [String: UInt64] = [:]
        var read = 0
        var warning = discoveryFailed
        var unfinishedLine = false
        for url in files {
            guard let log = logs[url] else { continue }
            let size = ((try? fm.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.uint64Value ?? 0
            // EOF with a partial line waits for the next append; inaccessible
            // files report a warning rather than keeping initial loading alive.
            if log.error != nil || (log.hasReadFile && log.consumedByteCount >= size) { read += 1 }
            if log.hasPendingLine && log.consumedByteCount >= size { unfinishedLine = true }
            if log.error != nil || log.skippedLargeLines > 0 { warning = true }
            guard log.metadataLoaded else {
                if log.hasReadFile && !log.hasUnreadBytes { warning = true }
                continue
            }
            guard !log.isSubagent || log.isAttributedSubagent else { continue }
            guard includeSubagents || !log.isSubagent else { continue }
            if let old = selected[log.id], let oldSize = selectedSizes[log.id],
               oldSize > size || (oldSize == size && old.modifiedAt >= log.modifiedAt) { continue }
            selected[log.id] = log; selectedSizes[log.id] = size
        }
        var buckets: [String: [String: DailyTotals]] = [:]
        var omitted = 0, legacy = 0
        for log in selected.values {
            guard let statistics = log.dailyStatistics else { continue }
            omitted += statistics.omittedRecords; legacy += statistics.legacyRequests
            for (day, models) in statistics.buckets {
                for (model, value) in models { buckets[day, default: [:]][model, default: DailyTotals()].add(value) }
            }
        }
        let days = buckets.keys.sorted(by: >).map { day in
            let models = buckets[day]!.map { DailyModelUsage(model: $0.key, totals: $0.value) }.sorted { $0.model < $1.model }
            var totals = DailyTotals()
            for model in models { totals.add(model.totals) }
            return DailyUsage(day: day, totals: totals, models: models)
        }
        var notes: [String] = []
        if warning { notes.append(L10n.text("部分日志缺失、无法读取或记录过大，历史统计可能不完整。")) }
        if unfinishedLine { notes.append(L10n.text("部分日志末尾记录尚未写完，暂未计入；写入完成后会自动补全。")) }
        if omitted > 0 { notes.append(L10n.text("有 %@ 条旧用量或缺少时间的记录无法可靠归入日期，未计入。", omitted)) }
        if legacy > 0 { notes.append(L10n.text("已计入 %@ 次可验证的旧版请求；它们没有连续输出计时，不参与均速。", legacy)) }
        return DailyScanResult(days: days, isLoading: read < files.count, filesRead: read, totalFiles: files.count,
            message: notes.isEmpty ? nil : notes.joined(separator: "\n"), timeZoneIdentifier: timeZone.identifier)
    }
}
