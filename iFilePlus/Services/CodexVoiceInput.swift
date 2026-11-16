import SwiftUI
import AVFoundation

// Audio callbacks never touch SwiftUI state. A small locked PCM queue separates
// capture from network backpressure; the entire recording is limited to 60 s.
private final class CodexVoicePCM: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()
    private var samples = 0
    private var failed = false
    func append(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        let count = min(data.count, max(0, 16000 * 60 * 2 - samples * 2))
        pending.append(data.prefix(count)); samples += count / 2
    }
    func take() -> Data {
        lock.lock(); defer { lock.unlock() }
        let count = min(pending.count, 64000)
        let data = Data(pending.prefix(count)); pending.removeFirst(count); return data
    }
    var seconds: Int { lock.lock(); defer { lock.unlock() }; return samples / 16000 }
    var error: Bool { lock.lock(); defer { lock.unlock() }; return failed }
    func fail() { lock.lock(); failed = true; lock.unlock() }
}

@MainActor final class CodexVoiceRecorder: ObservableObject {
    @Published private(set) var recording = false
    @Published private(set) var preparing = false
    @Published private(set) var finishing = false
    @Published private(set) var seconds = 0
    @Published private(set) var partial = ""
    @Published private(set) var error: String?
    var active: Bool { recording || preparing || finishing }
    private var engine: AVAudioEngine?
    private var pump: Task<Void, Never>?
    private var generation = UUID()
    private var requestID = UUID().uuidString
    private var sequence = 0
    private weak var service: CodexConnectService?

    func start(service: CodexConnectService, onText: @escaping (String) -> Void) async {
        guard !active else { return }
        cancel(); preparing = true; partial = ""; error = nil; seconds = 0
        let token = generation
        let permitted = await AVAudioApplication.requestRecordPermission()
        guard token == generation else { return }
        guard permitted else { preparing = false; error = "麦克风未授权，请在系统设置中允许 AstroGate 使用麦克风。"; return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement)
            try session.setActive(true)
            let audio = AVAudioEngine()
            let input = audio.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0,
                  let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true),
                  let converter = AVAudioConverter(from: format, to: target) else {
                throw CodexConnectError(message: "无法读取麦克风，请检查音频设备。")
            }
            let queue = CodexVoicePCM()
            input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
                let capacity = AVAudioFrameCount(Double(buffer.frameLength) * 16000 / format.sampleRate) + 32
                guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { queue.fail(); return }
                var supplied = false
                var conversionError: NSError?
                converter.convert(to: output, error: &conversionError) { _, status in
                    if supplied { status.pointee = .noDataNow; return nil }
                    supplied = true; status.pointee = .haveData; return buffer
                }
                guard conversionError == nil else { queue.fail(); return }
                if let samples = output.int16ChannelData?.pointee, output.frameLength > 0 {
                    queue.append(Data(bytes: samples, count: Int(output.frameLength) * 2))
                }
            }
            engine = audio
            audio.prepare(); try audio.start()
            self.service = service; requestID = UUID().uuidString; sequence = 0
            preparing = false; recording = true
            pump = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self, token == self.generation else { return }
                    self.seconds = queue.seconds
                    if queue.error { self.fail("录音设备发生错误，请重试；已识别的文字已保留。", onText: onText); return }
                    if self.seconds >= 60 { self.finish() }
                    let data = queue.take()
                    let final = data.isEmpty && !self.recording
                    if data.isEmpty && !final { try? await Task.sleep(for: .milliseconds(300)); continue }
                    let params: [String: Any] = ["requestId": self.requestID, "sequence": self.sequence,
                                                  "audio": data.base64EncodedString(), "final": final]
                    do {
                        // Retrying the identical sequence cannot append audio twice.
                        let result = try await self.sendChunk(service, params: params)
                        guard token == self.generation, !Task.isCancelled else { return }
                        self.sequence += 1
                        self.partial = (result["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        if final {
                            self.finishing = false
                            if self.partial.isEmpty { self.error = "没有识别到说话内容，请重新录音。" }
                            else { onText(self.partial); self.partial = "" }
                            self.service = nil
                            return
                        }
                    } catch {
                        guard token == self.generation, !Task.isCancelled else { return }
                        self.fail(error.localizedDescription + "；已识别的文字已保留。", onText: onText); return
                    }
                    try? await Task.sleep(for: .milliseconds(300))
                }
            }
        } catch { preparing = false; self.error = error.localizedDescription; stopCapture() }
    }
    private func sendChunk(_ service: CodexConnectService, params: [String: Any]) async throws -> [String: Any] {
        do { return try await service.request("transcribe", params) }
        catch {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(400))
            return try await service.request("transcribe", params)
        }
    }
    func finish() {
        guard recording else { return }
        stopCapture(); finishing = true
    }
    private func fail(_ message: String, onText: (String) -> Void) {
        let saved = partial
        cancel()
        if !saved.isEmpty { onText(saved) }
        error = message
    }
    func cancel() {
        generation = UUID(); pump?.cancel(); pump = nil
        stopCapture(); preparing = false; finishing = false; partial = ""
        if let service {
            let id = requestID, seq = sequence
            Task { _ = try? await service.request("transcribe", ["requestId": id, "sequence": seq, "audio": "", "final": true, "cancel": true]) }
        }
        service = nil
    }
    private func stopCapture() {
        if let engine { engine.stop(); engine.inputNode.removeTap(onBus: 0) }
        engine = nil; recording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

struct CodexVoiceInput: View {
    @ObservedObject var service: CodexConnectService
    @Binding var text: String
    let disabled: Bool
    @StateObject private var voice = CodexVoiceRecorder()
    @Environment(\.scenePhase) private var scenePhase
    private func append(_ value: String) {
        text += (text.isEmpty || text.hasSuffix("\n") ? "" : "\n") + value
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if voice.active && !voice.partial.isEmpty {
                ScrollView { Text(voice.partial).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: 110).padding(10).background(.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            }
            HStack(spacing: 12) {
                Button {
                    if voice.recording { voice.finish() }
                    else { Task { await voice.start(service: service, onText: append) } }
                } label: {
                    Label(voice.recording ? "完成 · \(voice.seconds)s / 60s" : "语音输入",
                          systemImage: voice.recording ? "stop.circle.fill" : "mic")
                        .foregroundStyle(voice.recording ? .red : .blue)
                }.disabled(voice.preparing || voice.finishing || disabled || !service.connected)
                if voice.preparing || voice.finishing { ProgressView() }
                Text(voice.finishing ? "正在确认最后一句…" : voice.recording ? "边说边转，完成后可编辑" : voice.preparing ? "准备录音…" : "")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if voice.active { Button("取消") { voice.cancel() } }
            }.font(.caption)
            if let error = voice.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
        }
        .padding(.horizontal)
        .onDisappear { voice.cancel() }
        .onChange(of: scenePhase) { _, phase in if phase != .active && voice.recording { voice.finish() } }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { _ in if voice.recording { voice.finish() } }
    }
}
