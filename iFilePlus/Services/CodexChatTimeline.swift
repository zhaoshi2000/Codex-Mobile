import Foundation

struct CodexChatMessage: Identifiable {
    let id: String
    let role: String
    let text: String
    let truncated: Bool
    let turnID: String?
    let clientMessageID: String?
    let provisional: Bool
    let startedAt: Double?
    let toolStatus: String?
    var completedAt: Double?
    var delivery: String?
    init(id: String, text: String, delivery: String) {
        self.id = id; self.role = "user"; self.text = text; self.truncated = false
        self.turnID = nil; self.clientMessageID = id; self.provisional = true; self.delivery = delivery; startedAt = nil; toolStatus = nil; completedAt = nil
    }
    init?(_ json: [String: Any]) {
        guard let id = json["id"] as? String, let text = json["text"] as? String else { return nil }
        self.id = id; self.text = text
        role = json["role"] as? String ?? "assistant"
        truncated = json["truncated"] as? Bool ?? false; turnID = json["turnId"] as? String
        clientMessageID = json["clientMessageId"] as? String; provisional = json["provisional"] as? Bool ?? false; delivery = nil
        completedAt = (json["completedAtMs"] as? NSNumber)?.doubleValue
        startedAt = (json["startedAtMs"] as? NSNumber)?.doubleValue; toolStatus = json["toolStatus"] as? String
    }
}

struct CodexChatGroup: Identifiable {
    let id: String
    let isUser: Bool
    var items: [CodexChatMessage]
    var text: String { items.filter { $0.role != "tool" }.map(\.text).joined(separator: "\n\n") }
    var reply: CodexChatMessage? { items.last(where: { $0.role == "assistant" }) }
    var blocks: [CodexChatBlock] {
        var result: [CodexChatBlock] = []
        for item in items {
            if item.role == "tool", result.last?.isCommands == true { result[result.count - 1].items.append(item) }
            else { result.append(CodexChatBlock(id: item.id, items: [item])) }
        }
        return result
    }
}

struct CodexChatBlock: Identifiable {
    let id: String
    var items: [CodexChatMessage]
    var isCommands: Bool { items.first?.role == "tool" }
}

enum CodexChatTimeline {
    static func groups(_ messages: [CodexChatMessage]) -> [CodexChatGroup] {
        var result: [CodexChatGroup] = []
        for row in messages {
            if row.role != "user", let last = result.last, !last.isUser,
               let turn = row.turnID, last.items.last?.turnID == turn {
                result[result.count - 1].items.append(row)
            } else { result.append(CodexChatGroup(id: row.id, isUser: row.role == "user", items: [row])) }
        }
        return result
    }
    // Both sources contain chronological windows with gaps. Insert missing
    // messages at their shared anchors instead of appending older history after
    // live output. A delayed disk page must not erase or rewind live messages.
    static func merge(_ existing: [CodexChatMessage], _ incoming: [CodexChatMessage], history: Bool = false) -> [CodexChatMessage] {
        var result = existing
        for row in incoming where row.role == "user" && !row.provisional {
            result.removeAll { old in
                old.provisional && old.id != row.id &&
                ((row.clientMessageID != nil && old.clientMessageID == row.clientMessageID) ||
                 (old.turnID != nil && old.turnID == row.turnID))
            }
        }
        var previous: String?
        for (offset, row) in incoming.enumerated() {
            if row.provisional, let turn = row.turnID,
               let real = result.first(where: { $0.role == "user" && !$0.provisional && $0.turnID == turn }) { previous = real.id; continue }
            if let index = result.firstIndex(where: { $0.id == row.id }) {
                if !history || row.text.hasPrefix(result[index].text) {
                    var updated = row
                    updated.completedAt = row.completedAt ?? result[index].completedAt
                    result[index] = updated
                } else if result[index].completedAt == nil { result[index].completedAt = row.completedAt }
            } else if let prior = previous, let index = result.firstIndex(where: { $0.id == prior }) {
                result.insert(row, at: index + 1)
            } else if let next = incoming.dropFirst(offset + 1).first(where: { candidate in result.contains(where: { $0.id == candidate.id }) }),
                      let index = result.firstIndex(where: { $0.id == next.id }) {
                result.insert(row, at: index)
            } else if history && !result.isEmpty {
                // No overlap: a delayed persisted page precedes in-flight work.
                result.insert(row, at: 0)
            } else { result.append(row) }
            previous = row.id
        }
        // A Desktop snapshot may contain an older, disjoint history island.
        // Recorded item time gives both sources the same chronological order.
        let timed = result.enumerated().filter { $0.element.startedAt != nil }.sorted {
            if $0.element.startedAt == $1.element.startedAt { return $0.offset < $1.offset }
            return $0.element.startedAt! < $1.element.startedAt!
        }.map(\.element)
        var next = 0
        for index in result.indices where result[index].startedAt != nil { result[index] = timed[next]; next += 1 }
        var chats = 0, tools = 0, bytes = 0
        result = result.reversed().filter { row in
            bytes += row.text.utf8.count
            if row.role == "tool" { tools += 1 } else { chats += 1 }
            return tools <= 100 && chats <= 100 && bytes <= 512000
        }.reversed()
        return result
    }
}


struct CodexQueuedMessage: Identifiable {
    let id: String
    let text: String
    let displayText: String
    let editable: Bool
    let preparing: Bool
    let error: String?
    init?(_ json: [String: Any]) {
        guard let id = json["id"] as? String else { return nil }
        self.id = id; text = json["text"] as? String ?? "附件消息"
        displayText = json["displayText"] as? String ?? text
        editable = json["editable"] as? Bool ?? false; preparing = json["preparing"] as? Bool ?? false; error = json["error"] as? String
    }
}

// Extract only attachment links; ordinary Markdown images/links remain intact.
struct CodexMessageImages {
    let paths: [String]
    let body: String
    init(_ text: String) {
        let pattern = #"📎\s*\[[^\]\n]*\]\(<([^>\n]+)>\)"#
        let regex = try! NSRegularExpression(pattern: pattern)
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        var paths: [String] = [], body = text
        var ranges: [Range<String.Index>] = []
        for match in matches {
            guard let range = Range(match.range(at: 1), in: text), let whole = Range(match.range, in: text) else { continue }
            let path = String(text[range])
            if ["jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "bmp", "tif", "tiff"].contains(URL(fileURLWithPath: path).pathExtension.lowercased()) {
                if !paths.contains(path) { paths.append(path) }; ranges.append(whole)
            }
        }
        for range in ranges.reversed() { body.removeSubrange(range) }
        self.paths = paths; self.body = body.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
