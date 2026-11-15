import Foundation
import UserNotifications

final class CodexNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = CodexNotifications()
    func enable() async throws -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
    }
    func completed(id: String, host: String) {
        var seen = UserDefaults.standard.stringArray(forKey: "codex.completed.ids") ?? []
        guard !seen.contains(id) else { return }
        seen.append(id); UserDefaults.standard.set(Array(seen.suffix(200)), forKey: "codex.completed.ids")
        let content = UNMutableNotificationContent(); content.title = "Codex 处理完成"; content.body = host + " 上的对话已完成，可打开查看结果。"; content.sound = .default
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) { completionHandler([.banner, .sound, .list]) }
}
