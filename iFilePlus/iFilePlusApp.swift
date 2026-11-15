import SwiftUI

@main
struct iFilePlusApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var connectionStore = ConnectionStore()

    var body: some Scene {
        WindowGroup {
            AppRootView()
                .environmentObject(connectionStore)
                .onChange(of: scenePhase) { _, phase in if phase == .active { CodexConnectService.resumeAll() } }
        }
    }
}
