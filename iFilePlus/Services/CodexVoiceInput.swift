import SwiftUI
import AVFoundation
import Speech

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
    @Published private(set) var usingOnDevice = false
    private var localRecognizer: SFSpeechRecognizer?
    private var localRequest: SFSpeechAudioBufferRecognitionRequest?
    private var localTask: SFSpeechRecognitionTask?
    private var finalTimeout: Task<Void, Never>?
    private var clockTask: Task<Void, Never>?
    private var transcript = CodexDictationSession()
    private var deliver: ((String) -> Void)?
    private var engine: AVAudioEngine?
    private var pump: Task<Void, Never>?
    private var generation = UUID()
    private var requestID = UUID().uuidString
    private var sequence = 0
    private weak var service: CodexConnectService?

    func start(service: CodexConnectService, preferLocal: Bool, onText: @escaping (String) -> Void) async {
        guard !active, !Task.isCancelled else { return }
        cancel(); preparing = true; partial = ""; error = nil; seconds = 0
        let token = generation
        if preferLocal { await startLocal(token: token, onText: onText); return }
        usingOnDevice = false
        let permitted = await AVAudioApplication.requestRecordPermission()
        guard token == generation, !Task.isCancelled else { return }
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
            _ = transcript.begin(); deliver = onText
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
                        self.transcript.replace(result["text"] as? String ?? "", session: self.transcript.id)
                        self.partial = self.transcript.text
                        if final { self.complete(); return }
                    } catch {
                        guard token == self.generation, !Task.isCancelled else { return }
                        self.fail(error.localizedDescription + "；已识别的文字已保留。", onText: onText); return
                    }
                    try? await Task.sleep(for: .milliseconds(300))
                }
            }
        } catch { preparing = false; self.error = error.localizedDescription; stopCapture() }
    }
    private func startLocal(token: UUID, onText: @escaping (String) -> Void) async {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")), recognizer.supportsOnDeviceRecognition else {
            preparing = false
            error = "此手机的中文离线识别暂不可用。可在识别方式中选择“服务器 CPU”，或先在系统设置启用中文听写。"
            return
        }
        let microphone = await AVAudioApplication.requestRecordPermission()
        guard token == generation, !Task.isCancelled else { return }
        guard microphone else { preparing = false; error = "请在系统设置允许 AstroGate 使用麦克风。"; return }
        let permission = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard token == generation, !Task.isCancelled else { return }
        guard permission == .authorized else {
            preparing = false; error = "语音识别权限未开启，请在系统设置中允许语音识别，或手动选择服务器 CPU。"; return
        }
        do {
            usingOnDevice = true
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement)
            try session.setActive(true)
            let audio = AVAudioEngine(), input = audio.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else { throw CodexConnectError(message: "麦克风不可用，请检查音频设备。") }
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.requiresOnDeviceRecognition = true
            request.shouldReportPartialResults = true
            request.taskHint = .dictation
            request.addsPunctuation = true
            request.contextualStrings = ["Codex", "AstroGate", "CPU", "SSH", "OpenClaw", "GitHub"]
            let recognitionID = transcript.begin()
            deliver = onText; localRecognizer = recognizer; localRequest = request
            localTask = recognizer.recognitionTask(with: request) { [weak self] result, failure in
                let snapshot = result?.bestTranscription.formattedString
                let isFinal = result?.isFinal ?? false
                let failed = failure != nil
                Task { @MainActor [weak self] in
                    guard let self, token == self.generation, !self.transcript.closed else { return }
                    if let snapshot, !snapshot.isEmpty || self.partial.isEmpty {
                        self.transcript.replace(snapshot, session: recognitionID)
                        self.partial = self.transcript.text
                    }
                    if isFinal { self.complete() }
                    else if failed {
                        if self.finishing || !self.partial.isEmpty { self.complete(warning: "本地识别已结束，请检查文字后发送。") }
                        else { self.complete(warning: "中文离线识别未能启动，请检查系统听写语言和离线资源，或切换到服务器 CPU。") }
                    }
                }
            }
            // Feed each native microphone buffer exactly once. The system handles
            // sample-rate conversion; there is no network or custom resampling.
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }
            engine = audio; audio.prepare(); try audio.start()
            preparing = false; recording = true
            let started = Date()
            clockTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(200))
                    guard let self, token == self.generation, !Task.isCancelled else { return }
                    self.seconds = Int(Date().timeIntervalSince(started))
                    if self.seconds >= 60 { self.finish(); return }
                }
            }
        } catch {
            let message = "无法开始本地录音：" + error.localizedDescription
            if transcript.closed { preparing = false; stopCapture(); self.error = message }
            else { complete(warning: message) }
        }
    }
    private func complete(warning: String? = nil) {
        guard let text = transcript.commit(session: transcript.id) else { return }
        let callback = deliver; deliver = nil
        generation = UUID()
        stopCapture(); finalTimeout?.cancel(); finalTimeout = nil
        localRequest?.endAudio(); localTask?.cancel()
        localTask = nil; localRequest = nil; localRecognizer = nil
        preparing = false; finishing = false; service = nil; partial = ""
        error = warning ?? (text.isEmpty ? "没有识别到说话内容，请重新按住说话。" : nil)
        if !text.isEmpty { callback?(text) }
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
        if usingOnDevice {
            localRequest?.endAudio()
            let token = generation
            finalTimeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                guard let self, token == self.generation, !Task.isCancelled else { return }
                self.complete(warning: "已保留识别文字，请检查后发送。")
            }
        }
    }
    private func fail(_ message: String, onText: (String) -> Void) {
        let saved = partial
        cancel()
        if !saved.isEmpty { onText(saved) }
        error = message
    }
    func cancel() {
        generation = UUID(); pump?.cancel(); pump = nil
        finalTimeout?.cancel(); finalTimeout = nil
        transcript.cancel(); deliver = nil
        stopCapture(); localRequest?.endAudio(); localTask?.cancel()
        localTask = nil; localRequest = nil; localRecognizer = nil
        preparing = false; finishing = false; partial = ""
        if let service {
            let id = requestID, seq = sequence
            Task { _ = try? await service.request("transcribe", ["requestId": id, "sequence": seq, "audio": "", "final": true, "cancel": true]) }
        }
        service = nil
    }
    private func stopCapture() {
        clockTask?.cancel(); clockTask = nil
        if let engine { engine.stop(); engine.inputNode.removeTap(onBus: 0) }
        engine = nil; recording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

struct CodexVoicePreview: View {
    @ObservedObject var voice: CodexVoiceRecorder
    @Binding var preferLocal: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if voice.active {
                VStack(spacing: 8) {
                    Image(systemName: "waveform").font(.title).foregroundStyle(.green)
                    Text(voice.preparing ? "准备录音…" : voice.finishing ? "正在确认文字…" : "松开转文字，上滑取消 · \(voice.seconds)s")
                        .font(.caption).foregroundStyle(.secondary)
                    if !voice.partial.isEmpty {
                        ScrollViewReader { proxy in
                            ScrollView {
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(voice.partial).frame(maxWidth: .infinity, alignment: .leading)
                                    Color.clear.frame(height: 1).id("voice-bottom")
                                }
                            }
                            .onChange(of: voice.partial) { _, _ in proxy.scrollTo("voice-bottom", anchor: .bottom) }
                        }.frame(maxHeight: 110)
                    }
                }.padding(12).background(.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
            }
            HStack {
                Menu {
                    Button { preferLocal = true } label: { Label("手机本地（中文）", systemImage: preferLocal ? "checkmark" : "iphone") }
                    Button { preferLocal = false } label: { Label("服务器 CPU", systemImage: preferLocal ? "desktopcomputer" : "checkmark") }
                } label: { Label(preferLocal ? "手机本地识别" : "服务器 CPU 识别", systemImage: preferLocal ? "iphone" : "desktopcomputer") }
                .disabled(voice.active)
                Spacer()
                if voice.finishing { ProgressView(); Button("取消") { voice.cancel() } }
            }.font(.caption)
            if let error = voice.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
        }.padding(.horizontal)
    }
}

struct CodexHoldToTalk: View {
    @ObservedObject var voice: CodexVoiceRecorder
    let service: CodexConnectService
    let preferLocal: Bool
    let disabled: Bool
    let onText: (String) -> Void
    @State private var startTask: Task<Void, Never>?
    @State private var pressing = false
    @State private var cancelling = false
    @GestureState private var touching = false
    var body: some View {
        Text(cancelling ? "松开取消" : pressing ? "松开 转文字" : "按住 说话")
            .font(.headline).frame(maxWidth: .infinity).frame(height: 46)
            .background(cancelling ? Color.red.opacity(0.22) : pressing ? Color.green.opacity(0.22) : Color(uiColor: .secondarySystemBackground), in: Capsule())
            .contentShape(Capsule())
            .gesture(DragGesture(minimumDistance: 0)
                .updating($touching) { _, state, _ in state = true }
                .onChanged { value in
                    guard !disabled, !voice.finishing else { return }
                    cancelling = value.translation.height < -60
                    if !pressing {
                        pressing = true
                        startTask = Task { await voice.start(service: service, preferLocal: preferLocal, onText: onText) }
                    }
                }
                .onEnded { value in cancelling = value.translation.height < -60; release() })
            .onChange(of: touching) { _, down in
                if !down { Task { @MainActor in await Task.yield(); if !touching { release() } } }
            }
            .opacity(disabled || voice.finishing ? 0.5 : 1)
            .accessibilityLabel("按住说话，松开转文字，上滑取消")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                guard !disabled else { return }
                if voice.recording { voice.finish() }
                else { Task { await voice.start(service: service, preferLocal: preferLocal, onText: onText) } }
            }
            .onDisappear { voice.cancel() }
    }
    private func release() {
        guard pressing else { return }
        pressing = false
        startTask?.cancel(); startTask = nil
        if cancelling || voice.preparing || !voice.recording { voice.cancel() }
        else { voice.finish() }
        cancelling = false
    }
}
