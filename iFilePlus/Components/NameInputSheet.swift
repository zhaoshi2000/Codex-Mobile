import SwiftUI

struct NameInputSheet: View {
    let title: String
    let placeholder: String
    let initialValue: String
    let actionTitle: String
    let onSubmit: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var value: String

    init(title: String, placeholder: String = "请输入名称", initialValue: String = "", actionTitle: String = "确定", onSubmit: @escaping (String) -> Void) {
        self.title = title
        self.placeholder = placeholder
        self.initialValue = initialValue
        self.actionTitle = actionTitle
        self.onSubmit = onSubmit
        _value = State(initialValue: initialValue)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField(placeholder, text: $value)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(actionTitle) {
                        onSubmit(value)
                        dismiss()
                    }
                    .disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }
}
