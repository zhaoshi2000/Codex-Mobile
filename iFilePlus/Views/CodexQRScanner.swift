import SwiftUI
import AVFoundation

struct CodexQRScanner: UIViewControllerRepresentable {
    let completion: (Result<String, Error>) -> Void
    func makeUIViewController(context: Context) -> ScannerController { let controller = ScannerController(); controller.completion = completion; return controller }
    func updateUIViewController(_ controller: ScannerController, context: Context) {}
    static func dismantleUIViewController(_ controller: ScannerController, coordinator: ()) { controller.stop() }
    final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        var completion: ((Result<String, Error>) -> Void)?
        private let capture = AVCaptureSession()
        private let queue = DispatchQueue(label: "ifile.codex.qr")
        private var preview: AVCaptureVideoPreviewLayer?
        private var finished = false
        override func viewDidLoad() {
            super.viewDidLoad(); view.backgroundColor = .black
            let label = UILabel(); label.text = "将电脑配对二维码放入画面"; label.textColor = .white; label.textAlignment = .center; label.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(label)
            NSLayoutConstraint.activate([label.centerXAnchor.constraint(equalTo: view.centerXAnchor), label.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 30)])
            AVCaptureDevice.requestAccess(for: .video) { [weak self] allowed in
                DispatchQueue.main.async { guard let self else { return }; if allowed { self.configure() } else { self.finish(.failure(CodexConnectError(message: "未获得相机权限，可在设置中允许或改用粘贴链接。"))) } }
            }
        }
        private func configure() {
            guard !finished else { return }
            do {
                guard let camera = AVCaptureDevice.default(for: .video) else { throw CodexConnectError(message: "此设备没有可用相机") }
                let input = try AVCaptureDeviceInput(device: camera); let output = AVCaptureMetadataOutput()
                guard capture.canAddInput(input), capture.canAddOutput(output) else { throw CodexConnectError(message: "无法启动扫码") }
                capture.addInput(input); capture.addOutput(output); output.setMetadataObjectsDelegate(self, queue: .main); output.metadataObjectTypes = [.qr]
                let layer = AVCaptureVideoPreviewLayer(session: capture); layer.videoGravity = .resizeAspectFill; view.layer.insertSublayer(layer, at: 0); preview = layer; layer.frame = view.bounds
                queue.async { [capture] in capture.startRunning() }
            } catch { finish(.failure(error)) }
        }
        override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); preview?.frame = view.bounds }
        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
            guard let value = (metadataObjects.first as? AVMetadataMachineReadableCodeObject)?.stringValue else { return }; finish(.success(value))
        }
        private func finish(_ result: Result<String, Error>) { guard !finished else { return }; finished = true; stop(); completion?(result) }
        func stop() { queue.async { [capture] in if capture.isRunning { capture.stopRunning() } } }
    }
}
