import Foundation

/// Rollouts persist output-item boundaries, not individual token arrival times.
/// Keep this explicitly approximate. Only pair per-response token counts with
/// that same response's observed output window; never divide turn totals by a
/// partial set of generation intervals.
public struct OutputSample: Sendable {
    public let responseID: String
    public let tokens: Int
    public let start: Date
    public let end: Date
    public let seconds: TimeInterval
}

struct PendingOutput: Sendable {
    var start: Date?
    var end: Date?
}

extension Turn {
    public var firstVisibleOutputDelay: TimeInterval? {
        guard hasKnownStart, hasCompleteTimeline, let firstVisibleOutputAt else { return nil }
        return max(0, firstVisibleOutputAt.timeIntervalSince(start))
    }

    mutating func observeOutput(started: Date? = nil, completed: Date) {
        // Delayed or repeated completion records from an already-counted call
        // cannot become the start/end of the next call.
        let boundary = lastUsageAt ?? (hasKnownStart ? start : .distantPast)
        guard completed > boundary else { return }
        if let started, started >= boundary, started <= completed {
            pendingOutput.start = min(pendingOutput.start ?? started, started)
        }
        pendingOutput.end = max(pendingOutput.end ?? completed, completed)
    }

    mutating func finishOutput(responseID: String, tokens: Int, at sampleAt: Date) {
        defer { pendingOutput = PendingOutput() }
        // With an initial truncated tail, the first window may be missing its
        // earlier items. The next usage boundary lets later calls be counted.
        guard (hasCompleteTimeline && hasKnownStart) || lastUsageAt != nil,
              tokens > 0, let began = pendingOutput.start, let ended = pendingOutput.end,
              began >= (lastUsageAt ?? start), ended <= sampleAt else { return }
        let seconds = ended.timeIntervalSince(began) - toolSeconds(from: began, through: ended)
        guard seconds >= 0.1 else { return }
        outputSamples.append(OutputSample(responseID: responseID, tokens: tokens,
            start: began, end: ended, seconds: seconds))
    }

    public var continuousOutputTokens: Int { outputSamples.reduce(0) { $0 + $1.tokens } }
    public var continuousOutputSeconds: TimeInterval { outputSamples.reduce(0) { $0 + $1.seconds } }
    public var continuousOutputCalls: Int { outputSamples.count }
    public var continuousOutputRate: Double? {
        let seconds = continuousOutputSeconds
        guard seconds >= 0.1 else { return nil }
        return Double(continuousOutputTokens) / seconds
    }
}
