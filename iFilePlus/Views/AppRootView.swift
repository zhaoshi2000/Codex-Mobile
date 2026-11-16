import SwiftUI

enum AppTab: Hashable { case codex, connections, services, settings }

@MainActor final class AppNavigation: ObservableObject {
    @Published var tab: AppTab = .codex
    @Published var selectedDeviceID: String? = UserDefaults.standard.string(forKey: "codex.selectedDevice.v1")

    func open(_ device: CodexDevice) {
        selectedDeviceID = device.id
        UserDefaults.standard.set(device.id, forKey: "codex.selectedDevice.v1")
        tab = .codex
    }
}

struct AppRootView: View {
    @StateObject private var devices = CodexDeviceStore()
    @StateObject private var navigation = AppNavigation()
    private var activeDeviceID: String {
        (devices.devices.first { $0.id == navigation.selectedDeviceID } ?? devices.devices.first)?.id ?? "unpaired"
    }

    var body: some View {
        TabView(selection: $navigation.tab) {
            NavigationStack {
                CodexHomeView()
            }
            .id(activeDeviceID)
            .tabItem { Label("Codex", systemImage: "terminal") }
            .tag(AppTab.codex)

            NavigationStack {
                CodexConnectView()
            }
            .tabItem { Label("连接", systemImage: "desktopcomputer") }
            .tag(AppTab.connections)

            NavigationStack {
                ConnectionsView()
            }
            .tabItem { Label("服务", systemImage: "square.grid.2x2.fill") }
            .tag(AppTab.services)

            NavigationStack {
                SettingsView()
            }
            .tabItem { Label("设置", systemImage: "gearshape.fill") }
            .tag(AppTab.settings)
        }
        .environmentObject(devices)
        .environmentObject(navigation)
        .tint(.blue)
    }
}
