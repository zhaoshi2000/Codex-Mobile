import Foundation

/// Partial recognizer results are revised snapshots, never text deltas.
/// A recording can be committed only once; late callbacks cannot change it.
struct CodexDictationSession {
    private(set) var id = UUID()
    private(set) var text = ""
    private(set) var closed = true
    mutating func begin() -> UUID {
        id = UUID(); text = ""; closed = false; return id
    }
    mutating func replace(_ snapshot: String, session: UUID) {
        guard session == id, !closed else { return }
        text = snapshot.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    mutating func commit(session: UUID) -> String? {
        guard session == id, !closed else { return nil }
        closed = true; return text
    }
    mutating func cancel() { closed = true; text = ""; id = UUID() }
}
