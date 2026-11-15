import SwiftUI

struct CodexQuestion: Identifiable {
    let id: String
    let title: String
    let secret: Bool
    let options: [String]
}
struct CodexQuestionGroup: Identifiable {
    let id: String
    let questions: [CodexQuestion]
    init?(_ value: [String: Any]) {
        guard let id = value["id"] as? String else { return nil }; self.id = id
        questions = (value["questions"] as? [[String: Any]] ?? []).compactMap { q in
            guard let id = q["id"] as? String, let title = q["title"] as? String else { return nil }
            return CodexQuestion(id: id, title: title, secret: q["secret"] as? Bool ?? false, options: (q["options"] as? [[String: Any]] ?? []).compactMap { $0["label"] as? String })
        }
        if questions.isEmpty { return nil }
    }
}
struct CodexProgressStep: Identifiable {
    let id: String
    let title: String
    let active: Bool
    let failed: Bool
    init?(_ value: [String: Any]) { guard let id = value["id"] as? String, let title = value["title"] as? String else { return nil }; self.id = id; self.title = title; active = value["active"] as? Bool ?? false; failed = value["failed"] as? Bool ?? false }
}
struct CodexQuestionCard: View {
    let group: CodexQuestionGroup
    @ObservedObject var service: CodexConnectService
    let threadID: String
    @State private var answers: [String: String] = [:]
    @State private var submissionID = UUID().uuidString
    @State private var submitting = false
    @State private var submitted = false
    @State private var uncertain = false
    @State private var message: String?
    private var account: String { "codex.answer." + service.device.id + "." + threadID + "." + group.id }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(submitted ? "回答已提交" : "需要你回答", systemImage: "questionmark.bubble").font(.headline)
            ForEach(group.questions) { q in
                VStack(alignment: .leading, spacing: 8) {
                    Text(q.title).font(.subheadline)
                    ForEach(Array(q.options.enumerated()), id: \.offset) { _, option in
                        Button { answers[q.id] = option } label: { HStack(alignment: .top) { Image(systemName: answers[q.id] == option ? "checkmark.circle.fill" : "circle"); Text(option).multilineTextAlignment(.leading); Spacer(minLength: 0) } }
                    }
                    if q.secret { SecureField("填写回复", text: binding(q.id)).textFieldStyle(.roundedBorder) }
                    else { TextField("或自行填写回复", text: binding(q.id), axis: .vertical).lineLimit(1...5).textFieldStyle(.roundedBorder) }
                }.disabled(submitting || submitted || uncertain)
            }
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            if !submitted {
                Button { Task { await submit() } } label: { HStack { if submitting { ProgressView() }; Text(uncertain ? "核实提交状态" : "提交回答") } }
                    .disabled(!service.connected || submitting || group.questions.contains { (answers[$0.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (answers[$0.id] ?? "").count > 8000 })
            }
        }.padding().frame(maxWidth: .infinity, alignment: .leading).background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
        .task {
            if let raw = KeychainStore.get(account: account), let data = raw.data(using: .utf8), let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let id = saved["id"] as? String {
                submissionID = id; answers = saved["answers"] as? [String: String] ?? [:]; submitted = saved["state"] as? String == "accepted"; uncertain = !submitted
            }
        }
    }
    private func binding(_ id: String) -> Binding<String> { Binding(get: { answers[id] ?? "" }, set: { answers[id] = $0 }) }
    private func save(_ state: String) throws { let data = try JSONSerialization.data(withJSONObject: ["id": submissionID, "answers": answers, "state": state]); try KeychainStore.set(String(decoding: data, as: UTF8.self), account: account) }
    private func submit() async {
        submitting = true; defer { submitting = false }
        do {
            try save("unknown"); uncertain = true
            let result = try await service.request("answer", ["threadId": threadID, "groupId": group.id, "answers": answers, "messageId": submissionID])
            submitted = result["state"] as? String == "accepted"; uncertain = !submitted
            try save(submitted ? "accepted" : "unknown")
            message = submitted ? "已提交到电脑原对话" : "送达尚未确认，请在电脑核实；不会自动重复发送。"
        } catch { message = error.localizedDescription }
    }
}
