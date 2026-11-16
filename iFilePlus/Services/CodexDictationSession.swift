import Foundation

/// Partial recognizer results are revised snapshots, never text deltas.
/// A recording can be committed only once; late callbacks cannot change it.
struct CodexDictationSession {
    private(set) var id = UUID()
    private(set) var text = ""
    private(set) var closed = true
    private struct Utterance {
        var text: String
        var start: TimeInterval
        var end: TimeInterval
        var settled: Bool
    }
    private var utterances: [Utterance] = []
    mutating func begin() -> UUID {
        id = UUID(); text = ""; utterances = []; closed = false; return id
    }
    mutating func replace(_ snapshot: String, session: UUID) {
        guard session == id, !closed else { return }
        text = snapshot.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    /// On-device Speech can reset formattedString after an utterance boundary.
    /// Audio timestamps identify revisions versus new speech; text equality alone
    /// must not remove words the speaker actually repeats after a pause.
    mutating func recognize(_ snapshot: String, start: TimeInterval?, end: TimeInterval?, settled: Bool, session: UUID) {
        guard session == id, !closed else { return }
        let value = snapshot.trimmingCharacters(in: .whitespacesAndNewlines)
        // Some devices deliver an empty final result after silence.
        guard !value.isEmpty else { return }
        let first = start ?? 0, last = max(first, end ?? first)
        let next = Utterance(text: value, start: first, end: last, settled: settled)
        if let previous = utterances.last {
            let hasTiming = last > first
            let cumulative = utterances.count > 1 && value.hasPrefix(utterances[0].text)
            // A repeated untimed callback is not evidence of new audio. Keep the
            // endpoint so a later timed repetition can still become a new phrase.
            if !hasTiming && value == previous.text { return }
            if previous.settled && !settled && (!hasTiming || first < previous.start - 0.3) && !value.hasPrefix(previous.text) && !cumulative {
                utterances.append(next)
            } else if !previous.settled && previous.end <= previous.start {
                utterances[utterances.count - 1] = next
            } else if first > previous.start + 0.3 && first >= previous.end - 0.1 {
                utterances.append(next)
            } else if hasTiming, let index = utterances.firstIndex(where: { abs($0.start - first) < 0.3 }) {
                // A cumulative callback can cover several already saved utterances.
                // Preserve later utterances if this is a delayed earlier revision.
                let upper = utterances.indices.last(where: { $0 >= index && utterances[$0].start < last - 0.1 }) ?? index
                utterances.replaceSubrange(index...max(index, upper), with: [next])
            } else {
                utterances[utterances.count - 1] = next
            }
        } else { utterances = [next] }
        text = utterances.map(\.text).joined(separator: "\n")
    }
    mutating func commit(session: UUID) -> String? {
        guard session == id, !closed else { return nil }
        closed = true; return text
    }
    mutating func cancel() { closed = true; text = ""; utterances = []; id = UUID() }
}
