import Foundation

public enum SpeedMetric: String, CaseIterable, Sendable {
    case continuousOutput
    case excludingTools
    case wholeTurn
}

public struct ToolInterval: Sendable {
    public var start: Date
    public var end: Date?
}

extension Turn {
    /// Compare completed counts with the time up to that same sample. A running
    /// tool or unfinished generation does not lower this rate. The remainder
    /// still includes transport, prefill and orchestration, so it is an estimate.
    public var sampleEnd: Date? {
        guard let lastUsageAt else { return nil }
        return min(lastUsageAt, end ?? lastUsageAt)
    }

    public var toolSecondsToSample: TimeInterval? {
        guard hasCompleteTimeline, hasKnownStart, let stop = sampleEnd, stop >= start else { return nil }
        return toolSeconds(from: start, through: stop)
    }

    func toolSeconds(from begin: Date, through stop: Date) -> TimeInterval {
        let tools = mergedIntervals(toolIntervals, from: begin, through: stop)
        let generations = mergedIntervals(generationIntervals, from: begin, through: stop)
        let total = tools.reduce(0) { $0 + $1.1.timeIntervalSince($1.0) }
        // A background process can keep running while the model generates.
        // Preserve every model interval that the log positively identifies.
        var overlap: TimeInterval = 0
        var toolIndex = 0, generationIndex = 0
        while toolIndex < tools.count && generationIndex < generations.count {
            let tool = tools[toolIndex], generation = generations[generationIndex]
            let lower = max(tool.0, generation.0), upper = min(tool.1, generation.1)
            if upper > lower { overlap += upper.timeIntervalSince(lower) }
            if tool.1 < generation.1 { toolIndex += 1 }
            else { generationIndex += 1 }
        }
        return max(0, total - overlap)
    }

    private func mergedIntervals(_ values: [String: ToolInterval], from begin: Date, through stop: Date) -> [(Date, Date)] {
        let intervals = values.values.compactMap { interval -> (Date, Date)? in
            let lower = max(begin, interval.start)
            let upper = min(stop, interval.end ?? stop)
            guard lower < upper else { return nil }
            return (lower, upper)
        }.sorted { $0.0 < $1.0 }
        guard var merged = intervals.first else { return [] }
        var result: [(Date, Date)] = []
        for interval in intervals.dropFirst() {
            if interval.0 <= merged.1 { merged.1 = max(merged.1, interval.1) }
            else {
                result.append(merged)
                merged = interval
            }
        }
        result.append(merged)
        return result
    }

    public var nonToolSecondsToSample: TimeInterval? {
        guard let stop = sampleEnd, let tools = toolSecondsToSample else { return nil }
        return max(0, stop.timeIntervalSince(start) - tools)
    }

    public var rateExcludingTools: Double? {
        guard hasUsage, let elapsed = nonToolSecondsToSample, elapsed >= 0.1 else { return nil }
        return Double(usage.output) / elapsed
    }

    public func rate(at date: Date, metric: SpeedMetric) -> Double? {
        switch metric {
        case .continuousOutput: return continuousOutputRate
        case .excludingTools: return rateExcludingTools
        case .wholeTurn: return rate(at: date)
        }
    }
}
