import SwiftUI

struct AppRootView: View {
    var body: some View {
        TabView {
            NavigationStack {
                FileBrowserView(directory: LocalFileService.documentsDirectory, isRoot: true)
            }
            .tabItem { Label("文件", systemImage: "folder.fill") }

            NavigationStack {
                ConnectionsView()
            }
            .tabItem { Label("连接", systemImage: "network") }

            NavigationStack {
                CodexConnectView()
            }
            .tabItem { Label("Codex", systemImage: "terminal") }

            NavigationStack {
                SettingsView()
            }
            .tabItem { Label("设置", systemImage: "gearshape.fill") }
        }
        .tint(.blue)
    }
}
