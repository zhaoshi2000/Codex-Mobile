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
    @State private var custom: Set<String> = []
    private let skipped = "用户跳过此问题，未提供答案。"
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
                        Button { custom.remove(q.id); answers[q.id] = option } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: answers[q.id] == option ? "checkmark.circle.fill" : "circle").foregroundStyle(answers[q.id] == option ? Color.accentColor : .secondary)
                                Text(option).font(.subheadline).foregroundStyle(.primary).multilineTextAlignment(.leading)
                                Spacer(minLength: 0)
                            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                .background(answers[q.id] == option ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                    HStack {
                        if !q.options.isEmpty {
                            Button("自定义回答") { custom.insert(q.id); answers[q.id] = "" }
                        }
                        Spacer()
                        Button(answers[q.id] == skipped ? "已跳过 · 撤销" : "跳过此题") {
                            custom.remove(q.id); answers[q.id] = answers[q.id] == skipped ? "" : skipped
                        }
                    }.font(.caption).buttonStyle(.borderless).frame(minHeight: 36)
                    if custom.contains(q.id) || q.options.isEmpty {
                        if q.secret { SecureField("填写回答", text: binding(q.id)).textFieldStyle(.roundedBorder) }
                        else { TextField("填写回答", text: binding(q.id), axis: .vertical).lineLimit(2...5).textFieldStyle(.roundedBorder) }
                    }
                }.disabled(submitting || submitted || uncertain)
            }
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            if !submitted {
                if !service.connected { Text("电脑未连接，恢复连接后可提交。").font(.caption).foregroundStyle(.secondary) }
                else if !uncertain && group.questions.contains(where: { (answers[$0.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                    Text("请选择、填写回答，或跳过暂不回答的问题。").font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    if !uncertain {
                        Button("跳过全部") {
                            for q in group.questions { answers[q.id] = skipped }; custom = []
                            Task { await submit() }
                        }.buttonStyle(.borderless).disabled(!service.connected || submitting)
                    }
                    Spacer()
                    Button { Task { if uncertain { await checkStatus() } else { await submit() } } } label: {
                        HStack { if submitting { ProgressView() }; Text(uncertain ? "核实提交状态" : "提交回答") }.padding(.horizontal, 8).frame(minHeight: 32)
                    }.buttonStyle(.borderedProminent)
                        .disabled(!service.connected || submitting || (!uncertain && group.questions.contains { (answers[$0.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (answers[$0.id] ?? "").count > 8000 }))
                }
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.secondary.opacity(0.15), lineWidth: 1))
        .task {
            if let raw = KeychainStore.get(account: account), let data = raw.data(using: .utf8), let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let id = saved["id"] as? String {
                submissionID = id; answers = saved["answers"] as? [String: String] ?? [:]; submitted = saved["state"] as? String == "accepted"; uncertain = saved["state"] as? String == "unknown"
                custom = Set(group.questions.filter { !($0.options.contains(answers[$0.id] ?? "")) && answers[$0.id] != skipped }.map(\.id))
            }
        }
    }
    private func binding(_ id: String) -> Binding<String> { Binding(get: { answers[id] ?? "" }, set: { answers[id] = $0 }) }
    private func save(_ state: String) throws { let data = try JSONSerialization.data(withJSONObject: ["id": submissionID, "answers": answers, "state": state]); try KeychainStore.set(String(decoding: data, as: UTF8.self), account: account) }
    private func submit() async {
        guard service.connected, !submitting else { return }
        submitting = true; defer { submitting = false }
        do {
            try save("unknown"); uncertain = true
            let result = try await service.request("answer", ["threadId": threadID, "groupId": group.id, "answers": answers, "messageId": submissionID])
            submitted = result["state"] as? String == "accepted"; uncertain = !submitted
            try save(submitted ? "accepted" : "unknown")
            message = submitted ? "已提交到电脑原对话" : "送达尚未确认，请在电脑核实；不会自动重复发送。"
        } catch { message = error.localizedDescription }
    }
    private func checkStatus() async {
        guard !submitting else { return }
        submitting = true; defer { submitting = false }
        do {
            let result = try await service.request("answerStatus", ["threadId": threadID, "groupId": group.id, "messageId": submissionID])
            switch result["state"] as? String {
            case "accepted": submitted = true; uncertain = false; try save("accepted"); message = "已提交到电脑原对话"
            case "notSubmitted": uncertain = false; try save("draft"); message = "上次未提交，可修改后重新发送。"
            default: message = "送达仍未确认，请在电脑核实；不会重复发送。"
            }
        } catch { message = error.localizedDescription }
    }
}
