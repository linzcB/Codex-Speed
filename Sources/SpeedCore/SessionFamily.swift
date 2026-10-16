import Foundation

/// Each entry owns only its own requests. Family totals add unique thread IDs,
/// never copied fork history or a parent's already-grouped total.
public struct AgentSnapshot: Identifiable, Sendable {
    public var id: String
    public var label: String
    public var labelIsFallback: Bool
    public var displayLabel: String { labelIsFallback ? L10n.text(label) : label }
    public var model: String
    public var serviceTier: ApiServiceTier
    public var turns: [Turn]
    public var totalUsage: Usage
    public var hasCumulativeUsage: Bool
    public var modifiedAt: Date
    public var isLoading: Bool
    public var hasSkippedHistory: Bool
    public var error: String?
    public var latest: Turn? { turns.last }

    public init(log: SessionLog) {
        id = log.id; label = log.agentPath ?? log.agentNickname ?? log.label
        labelIsFallback = log.agentPath == nil && (log.agentNickname == nil ? log.labelIsFallback : log.hasFallbackNickname)
        model = log.model; serviceTier = log.serviceTier; turns = log.turns; totalUsage = log.lifetimeUsage
        hasCumulativeUsage = log.hasCumulativeUsage; modifiedAt = log.modifiedAt
        isLoading = log.hasUnreadBytes; hasSkippedHistory = log.hasSkippedHistory; error = log.error
    }
    public func isActive(at date: Date) -> Bool {
        guard let latest, latest.end == nil else { return false }
        return date.timeIntervalSince(modifiedAt) < 300
    }
}

public struct FamilyRound: Sendable {
    public var main: Turn
    public var children: [Turn]
    public var childCount: Int
    public var mainUsage: Usage { main.usage }
    public var childUsage: Usage { children.reduce(into: Usage()) { $0.add($1.usage) } }
    public var usage: Usage { var value = main.usage; value.add(childUsage); return value }
    public var calls: Int { main.calls + children.reduce(0) { $0 + $1.calls } }
}

extension SessionSnapshot {
    public var childUsage: Usage { agents.reduce(into: Usage()) { $0.add($1.totalUsage) } }
    public var totalUsage: Usage { var value = own.totalUsage; value.add(childUsage); return value }
    public func usage(includeSubagents: Bool) -> Usage { includeSubagents ? totalUsage : own.totalUsage }
    public var participants: [AgentSnapshot] { [own] + agents }
    public var isLoading: Bool { participants.contains { $0.isLoading } }
    public var totalsAreComplete: Bool {
        !isLoading && participants.allSatisfy { $0.hasCumulativeUsage && $0.error == nil }
    }
    public func round(for main: Turn, includeSubagents: Bool = true) -> FamilyRound {
        guard includeSubagents else { return FamilyRound(main: main, children: [], childCount: 0) }
        // Resolve explicit parent-turn chains when older records omit root_turn_id.
        let allTurns = participants.flatMap(\.turns)
        let turnMap = Dictionary(allTurns.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func rootID(_ turn: Turn) -> String? {
            var current = turn
            var visited = Set<String>()
            while visited.insert(current.id).inserted {
                if let root = current.rootTurnID { return root }
                if turns.contains(where: { $0.id == current.id }) { return current.id }
                guard let parent = current.parentTurnID, let next = turnMap[parent] else { return nil }
                current = next
            }
            return nil
        }
        let selected = agents.map { agent in agent.turns.filter { $0.hasUsage && rootID($0) == main.id } }
        return FamilyRound(main: main, children: selected.flatMap { $0 }, childCount: selected.filter { !$0.isEmpty }.count)
    }
    public var latestRound: FamilyRound? { latest.map { round(for: $0) } }
    public func isActive(at date: Date) -> Bool { participants.contains { $0.isActive(at: date) } }
}

public struct GlobalSpeed: Sendable {
    public var sum: Double?
    public var average: Double?
    public var sampledAgents: Int
    public var activeAgents: Int
    public var activeChats: Int
    public var sampleAt: Date?

    public init(sessions: [SessionSnapshot], at date: Date, metric: SpeedMetric, includeSubagents: Bool = true) {
        var seen = Set<String>()
        var values: [Double] = []
        var times: [Date] = []
        activeAgents = 0; activeChats = 0
        for session in sessions {
            let participants = includeSubagents ? session.participants : [session.own]
            if participants.contains(where: { $0.isActive(at: date) }) { activeChats += 1 }
            for agent in participants where seen.insert(agent.id).inserted && agent.isActive(at: date) {
                activeAgents += 1
                guard !agent.isLoading, let turn = agent.latest,
                      let rate = turn.rate(at: date, metric: metric), rate.isFinite else { continue }
                values.append(rate)
                if let time = metric == .continuousOutput ? turn.outputSamples.last?.end : turn.lastUsageAt {
                    times.append(time)
                }
            }
        }
        sampledAgents = values.count
        sum = values.isEmpty ? nil : values.reduce(0, +)
        average = sum.map { $0 / Double(values.count) }
        sampleAt = times.max()
    }
}
