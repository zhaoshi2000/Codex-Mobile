import SwiftUI
import WebKit
import Network

struct HostWebServicesView: View {
    @EnvironmentObject private var devices: CodexDeviceStore
    @State private var deviceID = ""
    @State private var address = "http://localhost:3000"
    @State private var directAddress = ""
    @State private var page: HostWebPage?
    @State private var error: String?
    var body: some View {
        Form {
            Section("主机") {
                Picker("已配对电脑", selection: $deviceID) {
                    Text("请选择").tag("")
                    ForEach(devices.devices) { Text($0.displayName).tag($0.id) }
                }
            }
            Section("网页服务") {
                TextField("网页地址", text: $address).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                TextField("主机 ZeroTier IP", text: $directAddress).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.numbersAndPunctuation)
            }
            Section {
                Button { open(direct: false) } label: { Label("服务器中转打开", systemImage: "server.rack") }
                Button { open(direct: true) } label: { Label("ZeroTier 直连打开", systemImage: "network") }
            }.disabled(deviceID.isEmpty)
            if let error { Text(error).foregroundStyle(.red).font(.footnote) }
            Section {
                Text("填写电脑上的网页服务地址，保留端口和路径。中转访问已配对电脑本机服务；直连使用其 ZeroTier IP，服务须监听该地址或所有网卡。HTTPS 仍验证原网址的证书。")
            }.font(.footnote).foregroundStyle(.secondary)
        }
        .navigationTitle("主机网页服务").navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if deviceID.isEmpty { deviceID = devices.devices.first?.id ?? "" }
            address = UserDefaults.standard.string(forKey: "hostweb.url") ?? address
            directAddress = UserDefaults.standard.string(forKey: "hostweb.zt") ?? ""
        }
        .sheet(item: $page) { page in HostWebPageView(page: page) }
    }
    private func open(direct: Bool) {
        guard let device = devices.devices.first(where: { $0.id == deviceID }),
              let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http","https"].contains(url.scheme ?? ""), url.host != nil, url.user == nil, url.password == nil else { error = "请输入有效的 http 或 https 网页地址"; return }
        let host = directAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        if direct && host.isEmpty { error = "请填写主机的 ZeroTier IP"; return }
        UserDefaults.standard.set(address, forKey: "hostweb.url"); UserDefaults.standard.set(host, forKey: "hostweb.zt")
        error = nil; page = HostWebPage(url: url, device: device, directHost: direct ? host : nil)
    }
}

struct HostWebPage: Identifiable {
    let id = UUID()
    let url: URL
    let device: CodexDevice
    let directHost: String?
    static func isHostService(_ url: URL) -> Bool {
        guard ["http","https"].contains(url.scheme ?? ""), let host = url.host?.lowercased() else { return false }
        if ["localhost","127.0.0.1","0.0.0.0","::1","[::1]"].contains(host) { return true }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else { return false }
        return parts[0] == 10 || (parts[0] == 192 && parts[1] == 168) || (parts[0] == 172 && (16...31).contains(parts[1]))
    }
}

struct HostWebPageView: View {
    let page: HostWebPage
    @Environment(\.dismiss) private var dismiss
    @State private var proxy: HostServiceProxy?
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Group {
                if let proxy { HostWebBrowser(url: page.url, proxy: proxy, error: $error) }
                else if let error { ContentUnavailableView("无法打开网页", systemImage: "network.slash", description: Text(error)) }
                else { ProgressView("正在连接主机…") }
            }
            .safeAreaInset(edge: .bottom) { if proxy != nil, let error { Text(error).font(.caption).padding().background(.regularMaterial) } }
            .navigationTitle(page.directHost == nil ? "服务器中转" : "ZeroTier 直连").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
        }
        .task {
            do {
                let service = CodexConnectService.session(for: page.device)
                if page.directHost == nil && !service.connected { await service.connect() }
                let created = try await HostServiceProxy(url: page.url, directHost: page.directHost, service: service)
                guard !Task.isCancelled else { created.stop(); return }; proxy = created
            } catch { self.error = error.localizedDescription }
        }
        .onDisappear { proxy?.stop(); proxy = nil }
    }
}

private struct HostWebBrowser: UIViewRepresentable {
    let url: URL
    let proxy: HostServiceProxy
    @Binding var error: String?
    func makeCoordinator() -> Coordinator { Coordinator(error: $error) }
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration(), data = WKWebsiteDataStore.nonPersistent()
        var proxy = ProxyConfiguration(socksv5Proxy: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: self.proxy.port)!))
        proxy.applyCredential(username: self.proxy.username, password: self.proxy.password)
        proxy.allowFailover = false
        // Public CDN assets use the normal network; only the chosen host uses this route.
        proxy.matchDomains = [url.host!]
        data.proxyConfigurations = [proxy]; config.websiteDataStore = data
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator; web.allowsBackForwardNavigationGestures = true
        web.load(URLRequest(url: url)); return web
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) { uiView.stopLoading(); uiView.navigationDelegate = nil }
    final class Coordinator: NSObject, WKNavigationDelegate {
        var error: Binding<String?>
        init(error: Binding<String?>) { self.error = error }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError failure: Error) { error.wrappedValue = "连接失败，请检查主机服务端口、网络授权与连接程序。\n" + failure.localizedDescription }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError failure: Error) { error.wrappedValue = failure.localizedDescription }
    }
}
