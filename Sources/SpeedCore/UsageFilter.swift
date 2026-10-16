import Foundation

public enum UsageFilter {
    /// Match recorded model IDs, never user-written chat titles or agent names.
    public static func isAutoReview(model: String) -> Bool {
        let id = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return id == "codex-auto-review" || id.hasPrefix("codex-auto-review-")
    }
}

extension Usage {
    public func subtracting(_ other: Usage) -> Usage {
        Usage(input: max(0, input - other.input), output: max(0, output - other.output),
              reasoning: max(0, reasoning - other.reasoning))
    }
}

extension Turn {
    public func filteringAutoReview(_ include: Bool) -> Turn {
        guard !include, autoReviewCalls > 0 else { return self }
        var result = self
        result.usage = usage.subtracting(autoReviewUsage)
        result.calls = max(0, calls - autoReviewCalls)
        result.hasUsage = result.calls > 0
        result.outputSamples.removeAll { autoReviewResponseIDs.contains($0.responseID) }
        result.firstVisibleOutputAt = result.outputSamples.compactMap(\.firstVisibleOutputAt).min()
        result.timeToFirstToken = nil // A logged turn-wide value cannot be split by model.
        result.model = reviewFilteredModel ?? model
        result.autoReviewUsage = Usage(); result.autoReviewCalls = 0
        result.autoReviewResponseIDs.removeAll()
        return result
    }
}

/// Compact request ownership/model accounting. No messages or tool contents are
/// kept. Lifetime review totals survive the live view's 40-turn retention limit.
final class ModelUsageLedger {
    struct Record {
        var turnID: String
        var model: String
        var usage: Usage
        var sequence: Int
    }
    private var records: [String: Record] = [:]
    private var modelByTurn: [String: String] = [:]
    private var pendingByTurn: [String: Set<String>] = [:]
    private var legacyByTurn: [String: Set<String>] = [:]
    private var sequence = 0
    private var reviewByTurn: [String: Usage] = [:]
    private var reviewCallsByTurn: [String: Int] = [:]
    private var lastIncludedModel: [String: (model: String, sequence: Int)] = [:]
    private(set) var totalUsage = Usage()
    private(set) var autoReviewUsage = Usage()
    private(set) var unknownModels = 0
    private(set) var requestCount = 0
    private(set) var reviewCalls = 0

    private func apply(_ record: Record, sign: Int) {
        func adjust(_ old: Usage) -> Usage {
            Usage(input: old.input + sign * record.usage.input,
                  output: old.output + sign * record.usage.output,
                  reasoning: old.reasoning + sign * record.usage.reasoning)
        }
        totalUsage = adjust(totalUsage); requestCount += sign
        if record.model == "未知模型" { unknownModels += sign }
        if UsageFilter.isAutoReview(model: record.model) {
            autoReviewUsage = adjust(autoReviewUsage); reviewCalls += sign
            reviewByTurn[record.turnID] = adjust(reviewByTurn[record.turnID] ?? Usage())
            reviewCallsByTurn[record.turnID, default: 0] += sign
        } else if sign > 0, record.model != "未知模型",
                  record.sequence >= (lastIncludedModel[record.turnID]?.sequence ?? -1) {
            lastIncludedModel[record.turnID] = (record.model, record.sequence)
        }
    }

    func setModel(_ model: String, for turnID: String) {
        modelByTurn[turnID] = model
        for key in pendingByTurn.removeValue(forKey: turnID) ?? [] {
            guard var record = records[key] else { continue }
            apply(record, sign: -1); record.model = model
            records[key] = record; apply(record, sign: 1)
        }
    }

    func contains(responseID: String) -> Bool { records["modern:" + responseID] != nil }

    func recordModern(responseID: String, turnID: String, usage: Usage) {
        let key = "modern:" + responseID
        guard records[key] == nil else { return }
        for oldKey in legacyByTurn.removeValue(forKey: turnID) ?? [] {
            if let old = records.removeValue(forKey: oldKey) { apply(old, sign: -1) }
            pendingByTurn[turnID]?.remove(oldKey)
        }
        insert(key: key, turnID: turnID, usage: usage)
    }

    func recordLegacy(turnID: String, usage: Usage) {
        let key = "legacy:\(sequence + 1)"
        insert(key: key, turnID: turnID, usage: usage)
        legacyByTurn[turnID, default: []].insert(key)
    }

    private func insert(key: String, turnID: String, usage: Usage) {
        sequence += 1
        let record = Record(turnID: turnID, model: modelByTurn[turnID] ?? "未知模型", usage: usage, sequence: sequence)
        records[key] = record; apply(record, sign: 1)
        if modelByTurn[turnID] == nil { pendingByTurn[turnID, default: []].insert(key) }
    }

    func annotate(_ turn: Turn) -> Turn {
        guard let calls = reviewCallsByTurn[turn.id], calls > 0 else { return turn }
        var result = turn
        result.autoReviewUsage = reviewByTurn[turn.id] ?? Usage()
        result.autoReviewCalls = calls
        result.reviewFilteredModel = lastIncludedModel[turn.id]?.model
        result.autoReviewResponseIDs = Set(turn.outputSamples.compactMap { sample in
            guard let model = records["modern:" + sample.responseID]?.model,
                  UsageFilter.isAutoReview(model: model) else { return nil }
            return sample.responseID
        })
        return result
    }
}
