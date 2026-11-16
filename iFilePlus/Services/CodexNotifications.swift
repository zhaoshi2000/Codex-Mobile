import Foundation
import UserNotifications

final class CodexNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = CodexNotifications()
    func enable() async throws -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
    }
    func completed(id: String, host: String, status: String = "completed", message: String? = nil) {
        var seen = UserDefaults.standard.stringArray(forKey: "codex.completed.ids") ?? []
        guard !seen.contains(id) else { return }
        seen.append(id); UserDefaults.standard.set(Array(seen.suffix(200)), forKey: "codex.completed.ids")
        let content = UNMutableNotificationContent()
        content.title = status == "failed" ? "Codex 本轮未完成" : status == "interrupted" ? "Codex 已停止" : status == "completed" ? "Codex 处理完成" : "Codex 任务已结束"
        content.body = host + "：" + (message ?? "可打开查看结果。")
        content.sound = .default
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) { completionHandler([.banner, .sound, .list]) }
}
