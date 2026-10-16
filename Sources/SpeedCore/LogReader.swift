import Foundation

public struct Usage: Equatable, Sendable {
    public var input = 0
    public var output = 0
    public var reasoning = 0
    public var total: Int { input + output }
    public init(input: Int = 0, output: Int = 0, reasoning: Int = 0) {
        self.input = input; self.output = output; self.reasoning = reasoning
    }
    init(_ json: [String: Any]) {
        input = max(0, (json["input_tokens"] as? NSNumber)?.intValue ?? 0)
        output = max(0, (json["output_tokens"] as? NSNumber)?.intValue ?? 0)
        reasoning = min(output, max(0, (json["reasoning_output_tokens"] as? NSNumber)?.intValue ?? 0))
    }
    mutating func add(_ other: Usage) {
        input += other.input; output += other.output; reasoning += other.reasoning
    }
}

public struct Turn: Identifiable, Sendable {
    public var id: String
    public var rootTurnID: String?
    public var parentTurnID: String?
    public var start: Date
    public var end: Date?
    public var lastUsageAt: Date?
    public var usage = Usage()
    public var calls = 0
    public var model = "未知模型"
    public var interrupted = false
    public var hasUsage = false
    public var hasKnownStart = true
    public var hasCompleteTimeline = true
    public var toolIntervals: [String: ToolInterval] = [:]
    public var generationIntervals: [String: ToolInterval] = [:]
    public var outputSamples: [OutputSample] = []
    var pendingOutput = PendingOutput()
    public var timeToFirstToken: TimeInterval?
    public var firstVisibleOutputAt: Date?
    public var durationOverride: TimeInterval?
    public var seenResponses = Set<String>()
    public var modernUsage = false
    public var legacyBaseline = Usage()
    public var legacyTotal = Usage()
    public var hasLegacyTotal = false

    public init(id: String, start: Date) { self.id = id; self.start = start }
    public func duration(at date: Date) -> TimeInterval {
        if end != nil, let durationOverride { return max(0, durationOverride) }
        return max(0, (end ?? date).timeIntervalSince(start))
    }
    public func rate(at date: Date) -> Double? {
        let elapsed = duration(at: date)
        guard hasUsage, hasKnownStart, elapsed >= 0.1 else { return nil }
        return Double(usage.output) / elapsed
    }
}

public final class SessionLog {
    public let url: URL
    public var id: String
    public var label: String { didSet { labelIsFallback = false } }
    public var labelIsFallback = true
    public var model = "未知模型"
    public var originator = "Codex"
    public private(set) var serviceTier: ApiServiceTier = .unknown
    public var cwd = ""
    public private(set) var isSubagent = false
    public private(set) var isAttributedSubagent = false
    public private(set) var parentThreadID: String?
    public private(set) var sessionID: String?
    public private(set) var agentPath: String?
    public private(set) var agentNickname: String?
    public private(set) var hasFallbackNickname = false
    public private(set) var hasCumulativeUsage = false
    public private(set) var hasUnreadBytes = false
    public private(set) var hasSkippedHistory = false
    private var hasMetadata = false
    private var readingInheritedHistory = false
    var metadataLoaded: Bool { hasMetadata }
    public var lifetimeUsage: Usage { hasCumulativeUsage ? threadTotal : turns.reduce(into: Usage()) { $0.add($1.usage) } }
    public var turns: [Turn] = []
    public var modifiedAt = Date.distantPast
    public private(set) var error: String?
    public private(set) var skippedLargeLines = 0
    let fullHistory: Bool
    let dailyStatistics: DailyLogStatistics?
    private(set) var lastReadByteCount = 0
    private(set) var hasReadFile = false
    var hasPendingLine: Bool { !pending.isEmpty || discardingLine }
    var consumedByteCount: UInt64 { offset }
    private var fileNumber: UInt64?
    private var offset: UInt64 = 0
    private var pending = Data()
    private var discardingLine = false
    private var currentID: String?
    private var threadTotal = Usage()
    private var tierChanges: [(date: Date, tier: ApiServiceTier)] = []
    private let formatter = ISO8601DateFormatter()
    private let simpleFormatter = ISO8601DateFormatter()
    private static let lineLimit = 16 * 1024 * 1024
    private static let initialTail = 8 * 1024 * 1024

    public init(url: URL, fullHistory: Bool = false, statisticsTimeZone: TimeZone = .current) {
        self.url = url
        self.fullHistory = fullHistory
        dailyStatistics = fullHistory ? DailyLogStatistics(timeZone: statisticsTimeZone) : nil
        id = url.deletingPathExtension().lastPathComponent
        label = "未命名会话"
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        simpleFormatter.formatOptions = [.withInternetDateTime]
    }
    public var latest: Turn? { turns.last }
    public var lastActivity: Date { latest?.lastUsageAt ?? latest?.start ?? modifiedAt }
    public var hasActiveTurn: Bool { latest?.end == nil && latest != nil }

    /// Metadata is the first record. Discovery can exclude internal tasks without
    /// reading their large tool output or letting them fill the eight chat slots.
    func refreshMetadata() {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 64 * 1024),
              let newline = head.firstIndex(of: 10) else { return }
        let line = Data(head[..<newline])
        guard let record = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              record["type"] as? String == "session_meta" else { return }
        consume(line)
    }

    /// Incremental reads; on first use only metadata plus the last 8 MiB are read.
    /// Partial lines are retained until their newline arrives. Oversized unrelated
    /// records are skipped with a bounded buffer, so tool output cannot exhaust RAM.
    public func refresh(maxBytes: Int = 2 * 1024 * 1024) {
        lastReadByteCount = 0
        do {
            if offset == 0, !hasMetadata, !fullHistory { refreshMetadata() }
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
            let modification = attrs[.modificationDate] as? Date ?? modifiedAt
            let number = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value
            if size < offset || (fullHistory && hasReadFile &&
                ((fileNumber != nil && number != fileNumber) || (size == offset && modification != modifiedAt))) { reset() }
            modifiedAt = modification; fileNumber = number; hasReadFile = true
            guard size > offset else { error = nil; hasUnreadBytes = false; return }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var budget = maxBytes
            if offset == 0, size > UInt64(Self.initialTail), !isAttributedSubagent, !fullHistory {
                hasSkippedHistory = true
                let head = try handle.read(upToCount: 64 * 1024) ?? Data()
                if let newline = head.firstIndex(of: 10) { consume(Data(head[..<newline])) }
                offset = size - UInt64(Self.initialTail)
                discardingLine = true
                budget = Self.initialTail
            }
            try handle.seek(toOffset: offset)
            let data = try handle.read(upToCount: budget) ?? Data()
            lastReadByteCount = data.count
            offset += UInt64(data.count)
            hasUnreadBytes = offset < size
            feed(data)
            error = nil
        } catch {
            self.error = L10n.text("暂时无法读取会话日志：%@", error.localizedDescription)
        }
    }

    public func ingest(_ data: Data) { feed(data) }
    private func reset() {
        offset = 0; pending.removeAll(); turns.removeAll()
        currentID = nil; threadTotal = Usage(); discardingLine = false
        skippedLargeLines = 0
        id = url.deletingPathExtension().lastPathComponent
        label = "未命名会话"; labelIsFallback = true; cwd = ""; isSubagent = false
        hasMetadata = false; isAttributedSubagent = false; parentThreadID = nil; sessionID = nil
        readingInheritedHistory = false
        model = "未知模型"; serviceTier = .unknown; tierChanges.removeAll()
        agentPath = nil; agentNickname = nil; hasFallbackNickname = false; hasCumulativeUsage = false
        hasUnreadBytes = false; hasSkippedHistory = false
        dailyStatistics?.reset()
    }
    private func feed(_ data: Data) {
        var cursor = data.startIndex
        while cursor < data.endIndex {
            let newline = data[cursor...].firstIndex(of: 10)
            let stop = newline ?? data.endIndex
            if !discardingLine {
                if pending.count + data.distance(from: cursor, to: stop) > Self.lineLimit {
                    pending.removeAll(keepingCapacity: false)
                    discardingLine = true; skippedLargeLines += 1
                } else { pending.append(contentsOf: data[cursor..<stop]) }
            }
            if let newline {
                if !discardingLine { consume(pending) }
                pending.removeAll(keepingCapacity: true)
                discardingLine = false
                cursor = data.index(after: newline)
            } else { break }
        }
    }
    private func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        return formatter.date(from: text) ?? simpleFormatter.date(from: text)
    }
    private func recordTier(_ value: Any?, at timestamp: Date) {
        guard timestamp != .distantPast else { return }
        let tier = ApiServiceTier(recordedValue: value as? String)
        if let last = tierChanges.last, last.tier == tier, last.date <= timestamp {
            serviceTier = tier; return
        }
        tierChanges.append((timestamp, tier))
        if tierChanges.count > 1, tierChanges[tierChanges.count - 2].date > timestamp {
            tierChanges.sort { $0.date < $1.date }
        }
        serviceTier = tierChanges.last?.tier ?? .unknown
    }
    private func pricingTier(at timestamp: Date) -> ApiServiceTier {
        // Match the setting at this request's output start. A later change
        // must not reprice earlier requests or an output already in flight.
        var low = 0, high = tierChanges.count
        while low < high {
            let middle = (low + high) / 2
            if tierChanges[middle].date <= timestamp { low = middle + 1 } else { high = middle }
        }
        return low > 0 ? tierChanges[low - 1].tier : .unknown
    }
    private func ensureTurn(_ requestedID: String?, at timestamp: Date) -> Int {
        let turnID = requestedID ?? currentID ?? "unknown-\(timestamp.timeIntervalSince1970)"
        if let i = turns.lastIndex(where: { $0.id == turnID }) { return i }
        var turn = Turn(id: turnID, start: timestamp)
        turn.model = model
        turn.hasKnownStart = false
        turn.hasCompleteTimeline = false
        turn.legacyBaseline = threadTotal
        turns.append(turn)
        currentID = turnID
        trim()
        return turns.count - 1
    }
    private func trim() {
        if isAttributedSubagent {
            // Reused children can have many turns for the SAME parent turn.
            // Retain 40 root turns instead of dropping early child contributions.
            var roots: [String] = []
            for turn in turns {
                let root = turn.rootTurnID ?? turn.id
                if !roots.contains(root) { roots.append(root) }
            }
            if roots.count > 40 {
                let keep = Set(roots.suffix(40))
                turns.removeAll { !keep.contains($0.rootTurnID ?? $0.id) }
            }
        } else if turns.count > 40 { turns.removeFirst(turns.count - 40) }
    }
    private func consume(_ data: Data) {
        // JSON contents are data only; no commands, user messages, or credentials
        // are executed, stored, or sent anywhere.
        guard !data.isEmpty,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let kind = root["type"] as? String,
              let payload = root["payload"] as? [String: Any] else { return }
        let timestamp = date(root["timestamp"]) ?? .distantPast
        let turnID = payload["turn_id"] as? String
        if kind == "session_meta" {
            if hasMetadata, let recordID = payload["id"] as? String, recordID != id {
                readingInheritedHistory = true
                return
            }
            id = payload["id"] as? String ?? id
            hasMetadata = true
            cwd = payload["cwd"] as? String ?? ""
            originator = payload["originator"] as? String ?? "Codex"
            let sourceText = payload["source"] as? String ?? ""
            let source = payload["source"] as? [String: Any]
                ?? ((try? JSONSerialization.jsonObject(with: Data(sourceText.utf8))) as? [String: Any]) ?? [:]
            let subagent = source["subagent"] as? [String: Any] ?? [:]
            let spawn = subagent["thread_spawn"] as? [String: Any] ?? [:]
            isSubagent = source["subagent"] != nil || sourceText == "subagent" || payload["thread_source"] as? String == "subagent"
            parentThreadID = payload["parent_thread_id"] as? String ?? spawn["parent_thread_id"] as? String
            sessionID = payload["session_id"] as? String
            agentPath = payload["agent_path"] as? String ?? spawn["agent_path"] as? String
            agentNickname = payload["agent_nickname"] as? String ?? spawn["agent_nickname"] as? String
            hasFallbackNickname = false
            // Include any explicitly owned child, including internal review agents:
            // their requests also contribute to the parent chat's token usage.
            isAttributedSubagent = isSubagent && parentThreadID != nil
            if agentNickname == nil, subagent["other"] as? String == "guardian" {
                agentNickname = "审核助手"
                hasFallbackNickname = true
            }
            return
        }
        // Forked logs can contain copied parent records. Only charge usage to
        // the thread that actually made the request.
        if let owner = payload["thread_id"] as? String, hasMetadata, owner != id { return }
        if readingInheritedHistory {
            let attribution = payload["turn_attribution"] as? [String: Any] ?? [:]
            let ownStart = payload["type"] as? String == "task_started" && attribution["parent_turn_id"] != nil
            guard payload["thread_id"] as? String == id || ownStart else { return }
            readingInheritedHistory = false; currentID = nil
        }
        if kind == "turn_context" {
            if payload.keys.contains("service_tier") { recordTier(payload["service_tier"], at: timestamp) }
            model = payload["model"] as? String ?? model
            if let target = turnID ?? currentID, let value = payload["model"] as? String {
                dailyStatistics?.setModel(value, for: target)
            }
            if let target = turnID ?? currentID, let i = turns.lastIndex(where: { $0.id == target }) {
                turns[i].model = model
            }
            return
        }
        if kind == "response_item", let itemType = payload["type"] as? String,
           itemType == "reasoning" || itemType == "function_call" || itemType == "custom_tool_call"
            || (itemType == "message" && payload["role"] as? String == "assistant") {
            let i = ensureTurn(turnID, at: timestamp)
            turns[i].observeOutput(completed: timestamp)
        }
        if kind == "response_item", let itemType = payload["type"] as? String,
           let callID = payload["call_id"] as? String {
            let key = "call:\(callID)"
            if itemType == "function_call" || itemType == "custom_tool_call" {
                let i = ensureTurn(turnID, at: timestamp)
                if turns[i].toolIntervals[key] == nil {
                    turns[i].toolIntervals[key] = ToolInterval(start: timestamp, end: nil)
                }
            } else if itemType == "function_call_output" || itemType == "custom_tool_call_output" {
                // A late result from an aborted turn must not charge the next turn.
                if let i = turns.lastIndex(where: { $0.toolIntervals[key] != nil }) {
                    if timestamp >= turns[i].toolIntervals[key]!.start {
                        turns[i].toolIntervals[key]!.end = timestamp
                    }
                }
            }
            return
        }
        if kind == "token_usage_record", let json = payload["usage"] as? [String: Any] {
            let i = ensureTurn(turnID, at: timestamp)
            turns[i].rootTurnID = payload["root_turn_id"] as? String ?? turns[i].rootTurnID
            let responseID = payload["response_id"] as? String
                ?? "\(timestamp.timeIntervalSince1970)-\(Usage(json).output)"
            guard turns[i].seenResponses.insert(responseID).inserted else { return }
            if !turns[i].modernUsage {
                // Replace legacy event totals when both formats coexist.
                turns[i].usage = Usage(); turns[i].calls = 0; turns[i].modernUsage = true
            }
            let pricingAt = turns[i].pendingOutput.start ?? turns[i].lastUsageAt ?? turns[i].start
            let requestTier = pricingTier(at: pricingAt)
            turns[i].finishOutput(responseID: responseID, tokens: Usage(json).output, at: timestamp)
            let sample = turns[i].outputSamples.last.flatMap { $0.responseID == responseID ? $0 : nil }
            dailyStatistics?.recordModern(responseID: responseID, turnID: turns[i].id,
                timestamp: date(root["timestamp"]), model: turns[i].model, usageJSON: json,
                outputSeconds: sample?.seconds, serviceTier: requestTier)
            if let cumulative = payload["turn_token_usage"] as? [String: Any] {
                turns[i].usage = Usage(cumulative)
            } else { turns[i].usage.add(Usage(json)) }
            turns[i].hasUsage = true
            turns[i].lastUsageAt = timestamp
            turns[i].calls += 1
            if let total = payload["thread_token_usage"] as? [String: Any] {
                threadTotal = Usage(total); hasCumulativeUsage = true
            }
            return
        }
        guard kind == "event_msg", let event = payload["type"] as? String else { return }
        switch event {
        case "thread_settings_applied":
            guard let settings = payload["thread_settings"] as? [String: Any] else { return }
            recordTier(settings["service_tier"], at: timestamp)
        case "task_started", "turn_started":
            let newID = turnID ?? "turn-\(timestamp.timeIntervalSince1970)"
            let attribution = payload["turn_attribution"] as? [String: Any] ?? [:]
            let rootID = payload["root_turn_id"] as? String ?? attribution["root_turn_id"] as? String
            let parentID = attribution["parent_turn_id"] as? String ?? payload["parent_turn_id"] as? String
            if let i = turns.lastIndex(where: { $0.id == newID }) {
                turns[i].rootTurnID = rootID; turns[i].parentTurnID = parentID
                turns[i].start = timestamp; turns[i].hasKnownStart = true
                turns[i].hasCompleteTimeline = true
            } else {
                if let i = turns.indices.last, turns[i].end == nil {
                    turns[i].end = timestamp; turns[i].interrupted = true
                }
                var turn = Turn(id: newID, start: timestamp)
                turn.rootTurnID = rootID; turn.parentTurnID = parentID
                turn.model = model; turn.legacyBaseline = threadTotal
                turns.append(turn); trim()
            }
            currentID = newID
        case "item_started", "item_completed":
            guard let item = payload["item"] as? [String: Any],
                  let itemType = item["type"] as? String,
                  Self.toolItemTypes.contains(itemType) || Self.generationItemTypes.contains(itemType),
                  let itemID = item["id"] as? String,
                  let startMS = payload["started_at_ms"] as? NSNumber,
                  startMS.doubleValue.isFinite, startMS.doubleValue > 0 else { return }
            let started = Date(timeIntervalSince1970: startMS.doubleValue / 1000)
            var completed: Date?
            if event == "item_completed" {
                guard let endMS = payload["completed_at_ms"] as? NSNumber,
                      endMS.doubleValue.isFinite, endMS.doubleValue >= startMS.doubleValue else { return }
                completed = Date(timeIntervalSince1970: endMS.doubleValue / 1000)
            }
            let i = ensureTurn(turnID, at: timestamp)
            let key = "item:\(itemID)"
            // Preserve completion if a delayed start arrives afterwards.
            if Self.generationItemTypes.contains(itemType) {
                if event == "item_completed" || turns[i].generationIntervals[key] == nil {
                    turns[i].generationIntervals[key] = ToolInterval(start: started, end: completed)
                }
                if let completed {
                    turns[i].observeOutput(started: started, completed: completed)
                }
                if itemType == "AgentMessage" || itemType == "agentMessage",
                   started >= turns[i].start {
                    turns[i].firstVisibleOutputAt = min(turns[i].firstVisibleOutputAt ?? started, started)
                }
            } else if event == "item_completed" || turns[i].toolIntervals[key] == nil {
                turns[i].toolIntervals[key] = ToolInterval(start: started, end: completed)
            }
        case "task_complete", "task_completed", "turn_complete", "turn_completed", "turn_aborted", "task_aborted":
            guard let target = turnID ?? currentID,
                  let i = turns.lastIndex(where: { $0.id == target }) else { return }
            turns[i].end = timestamp
            turns[i].interrupted = event.contains("aborted")
            if let ms = payload["duration_ms"] as? NSNumber {
                turns[i].durationOverride = ms.doubleValue / 1000
                if !turns[i].hasKnownStart && turns[i].modernUsage {
                    turns[i].start = timestamp.addingTimeInterval(-ms.doubleValue / 1000)
                    turns[i].hasKnownStart = true
                }
            }
            if let ms = payload["time_to_first_token_ms"] as? NSNumber,
               ms.doubleValue.isFinite, ms.doubleValue >= 0,
               ms.doubleValue / 1000 <= turns[i].duration(at: timestamp) {
                turns[i].timeToFirstToken = ms.doubleValue / 1000
            }
        case "token_count":
            // Old cumulative counters in forked context cannot be attributed
            // reliably. Children require their explicit owned usage records.
            guard !isAttributedSubagent else {
                dailyStatistics?.noteUnattributedLegacy(turnID: turnID ?? currentID)
                return
            }
            guard let info = payload["info"] as? [String: Any],
                  let totalJSON = info["total_token_usage"] as? [String: Any] else { return }
            let total = Usage(totalJSON)
            let i = ensureTurn(turnID, at: timestamp)
            dailyStatistics?.recordLegacy(turnID: turns[i].id, timestamp: date(root["timestamp"]),
                model: turns[i].model, totalJSON: totalJSON, lastJSON: info["last_token_usage"] as? [String: Any],
                serviceTier: pricingTier(at: turns[i].pendingOutput.start ?? turns[i].lastUsageAt ?? turns[i].start))
            defer { if !turns[i].modernUsage { threadTotal = total; hasCumulativeUsage = true } }
            guard !turns[i].modernUsage else { return }
            guard !turns[i].hasLegacyTotal || total != turns[i].legacyTotal else { return }
            let baseline = turns[i].legacyBaseline
            // A reset (e.g. compaction) must not turn a delta negative or copy
            // previous-turn totals into the current turn.
            if total.output >= baseline.output, total.input >= baseline.input {
                turns[i].usage = Usage(input: total.input - baseline.input,
                    output: total.output - baseline.output,
                    reasoning: max(0, total.reasoning - baseline.reasoning))
            } else if let last = info["last_token_usage"] as? [String: Any] {
                turns[i].usage.add(Usage(last))
                turns[i].legacyBaseline = Usage(input: total.input - turns[i].usage.input,
                    output: total.output - turns[i].usage.output,
                    reasoning: total.reasoning - turns[i].usage.reasoning)
            } else { return }
            turns[i].legacyTotal = total; turns[i].hasLegacyTotal = true
            turns[i].pendingOutput = PendingOutput()
            turns[i].hasUsage = true; turns[i].lastUsageAt = timestamp
            turns[i].calls += 1
        default: break
        }
    }
    private static let toolItemTypes: Set<String> = [
        "CommandExecution", "FileChange", "McpToolCall", "DynamicToolCall",
        "CollabToolCall", "WebSearch", "ImageView", "Extension", "Hook",
        "commandExecution", "fileChange", "mcpToolCall", "dynamicToolCall",
        "collabToolCall", "webSearch", "imageView", "extension", "hook"
    ]
    private static let generationItemTypes: Set<String> = [
        "Reasoning", "AgentMessage", "Plan", "reasoning", "agentMessage", "plan"
    ]
}

public struct SessionSnapshot: Identifiable, Sendable {
    public var id: String
    public var label: String
    public var labelIsFallback: Bool
    public var displayLabel: String { labelIsFallback ? L10n.text("未命名会话") : label }
    public var model: String
    public var url: URL
    public var turns: [Turn]
    public var modifiedAt: Date
    public var error: String?
    public var own: AgentSnapshot
    public var agents: [AgentSnapshot] = []
    public var latest: Turn? { turns.last }
    public init(log: SessionLog) {
        id = log.id; label = log.label; model = log.model; url = log.url
        labelIsFallback = log.labelIsFallback
        turns = log.turns; modifiedAt = log.modifiedAt; error = log.error
        own = AgentSnapshot(log: log)
    }
}

public struct ScanResult: Sendable {
    public var sessions: [SessionSnapshot]
    public var message: String?
}

// Mutable scanner state is protected by this lock. Callers receive value-type
// snapshots; SessionLog objects never leave the scanner.
public final class LogScanner: @unchecked Sendable {
    public let directory: URL
    private let lock = NSLock()
    private var logs: [URL: SessionLog] = [:]
    private var lastDiscovery = Date.distantPast
    private var candidates: [URL] = []
    private var rootCandidates: [URL] = []
    private var owners: [URL: String] = [:]
    private let titles: SessionTitles
    private var discoveryMessage: String?
    public init(directory: URL) {
        self.directory = directory
        titles = SessionTitles(directory: directory.deletingLastPathComponent())
    }

    public func scan(at now: Date = Date(), force: Bool = false, preferredID: String? = nil) -> ScanResult {
        lock.lock()
        defer { lock.unlock() }
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: directory.path, isDirectory: &isDir), isDir.boolValue else {
            return ScanResult(sessions: [], message: L10n.text("找不到 sessions 文件夹，请选择 Codex 日志位置。"))
        }
        if force || now.timeIntervalSince(lastDiscovery) >= 10 {
            let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
            var discoveryFailed = false
            var files: [(URL, Date, Bool)] = []
            var directories = [directory]
            let archive = directory.deletingLastPathComponent().appendingPathComponent("archived_sessions")
            if directory.lastPathComponent == "sessions", fm.fileExists(atPath: archive.path) { directories.append(archive) }
            for folder in directories {
                if let enumerator = fm.enumerator(at: folder, includingPropertiesForKeys: keys,
                    options: [.skipsHiddenFiles], errorHandler: { _, _ in discoveryFailed = true; return true }) {
                    for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                        if let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true {
                            files.append((url, values.contentModificationDate ?? .distantPast, folder == archive))
                        }
                    }
                } else { discoveryFailed = true }
            }
            let existing = Set(files.map { $0.0 })
            logs = logs.filter { existing.contains($0.key) }
            // Prefer the newest physical file for a thread; backups and moved
            // archive copies must never double its counts.
            var byID: [String: URL] = [:]
            var dates: [URL: Date] = [:]
            var archived = Set<URL>()
            for (url, date, isArchived) in files.sorted(by: { $0.1 > $1.1 }) {
                let log = logs[url] ?? SessionLog(url: url)
                if !log.metadataLoaded { log.refreshMetadata() }
                logs[url] = log; dates[url] = date
                if isArchived { archived.insert(url) }
                if byID[log.id] == nil { byID[log.id] = url }
            }
            let rootURLs = Set(byID.values.filter { logs[$0]?.isSubagent == false && !archived.contains($0) })
            func owner(of log: SessionLog) -> String? {
                guard log.isAttributedSubagent else { return nil }
                var cursor = log
                var seen = Set<String>()
                while seen.insert(cursor.id).inserted {
                    if let root = cursor.sessionID, let url = byID[root], rootURLs.contains(url) { return root }
                    guard let parent = cursor.parentThreadID, let url = byID[parent], let next = logs[url] else { return nil }
                    if rootURLs.contains(url) { return next.id }
                    guard next.isAttributedSubagent else { return nil }
                    cursor = next
                }
                return nil
            }
            owners = [:]
            for url in byID.values {
                if let log = logs[url], let id = owner(of: log) { owners[url] = id }
            }
            var familyDates: [String: Date] = [:]
            for url in rootURLs { familyDates[logs[url]!.id] = dates[url] }
            for (url, owner) in owners { familyDates[owner] = max(familyDates[owner] ?? .distantPast, dates[url] ?? .distantPast) }
            let ordered = rootURLs.sorted {
                (familyDates[logs[$0]!.id] ?? .distantPast) > (familyDates[logs[$1]!.id] ?? .distantPast)
            }
            // Read every potentially active family, plus recent chats for the
            // picker and an explicitly selected older chat. Idle history cannot
            // dilute the global speed average or cause unbounded startup reads.
            let recent = Set(ordered.prefix(8))
            rootCandidates = ordered.filter { url in
                recent.contains(url) || logs[url]?.id == preferredID ||
                now.timeIntervalSince(familyDates[logs[url]!.id] ?? .distantPast) < 300
            }
            let rootIDs = Set(rootCandidates.compactMap { logs[$0]?.id })
            candidates = rootCandidates + owners.keys.filter { rootIDs.contains(owners[$0]!) }
            lastDiscovery = now
            discoveryMessage = discoveryFailed ? L10n.text("部分日志无法读取，合计可能不完整。") : nil
        }
        for url in candidates { logs[url]?.refresh() }
        let names = titles.names(for: rootCandidates.compactMap { logs[$0]?.id })
        var snapshots: [SessionSnapshot] = []
        for url in rootCandidates {
            guard let log = logs[url] else { continue }
            log.label = names[log.id] ?? "未命名会话"
            log.labelIsFallback = names[log.id] == nil
            var snapshot = SessionSnapshot(log: log)
            snapshot.agents = candidates.compactMap { childURL -> AgentSnapshot? in
                guard owners[childURL] == log.id, let child = logs[childURL] else { return nil }
                return AgentSnapshot(log: child)
            }.sorted { $0.modifiedAt > $1.modifiedAt }
            snapshot.modifiedAt = max(snapshot.modifiedAt, snapshot.agents.map(\.modifiedAt).max() ?? .distantPast)
            if snapshot.agents.contains(where: { $0.error != nil }) { snapshot.error = L10n.text("部分子 agent 日志无法读取，合计可能不完整。") }
            snapshots.append(snapshot)
        }
        // Preserve the compact picker when recent files have no actual running
        // turn; active chats are always retained beyond the usual eight slots.
        snapshots.sort { $0.modifiedAt > $1.modifiedAt }
        let recentIDs = Set(snapshots.prefix(8).map(\.id))
        snapshots = snapshots.filter { recentIDs.contains($0.id) || $0.id == preferredID || $0.isActive(at: now) }
        return ScanResult(sessions: snapshots,
            message: discoveryMessage ?? (snapshots.isEmpty ? L10n.text("尚未发现会话。发送一条 Codex 消息后会自动出现。") : nil))
    }
}
