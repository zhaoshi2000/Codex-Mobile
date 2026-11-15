import XCTest
@testable import FileServices

final class FileServicesTests: XCTestCase {
    func testMessageImageStackSeparatesOnlyImageAttachmentLinks() {
        let content = "正文\n📎 [照片](<C:/folder/照片.jpg>)\n📎 [文档](<C:/folder/readme.md>)\n📎 [照片](<C:/folder/照片.jpg>)\n📎 [二](<C:/two.PNG>)"
        let images = CodexMessageImages(content)
        XCTAssertEqual(images.paths, ["C:/folder/照片.jpg", "C:/two.PNG"])
        XCTAssertTrue(images.body.contains("正文")); XCTAssertTrue(images.body.contains("readme.md"))
        XCTAssertFalse(images.body.contains("照片.jpg")); XCTAssertFalse(images.body.contains("two.PNG"))
        XCTAssertEqual(CodexMessageImages("[普通链接](https://example.com/a.jpg)").paths, [])
    }

    func testServerAIStreamRequiresCompleteCommandsAndPreservesChunks() throws {
        var stream = ServerAIStream()
        func line(_ delta: [String: Any], finish: String? = nil) throws -> String {
            var choice: [String: Any] = ["delta": delta]; if let finish { choice["finish_reason"] = finish }
            return "data: " + String(decoding: try JSONSerialization.data(withJSONObject: ["choices": [choice]]), as: UTF8.self)
        }
        try stream.consume(line(["content": "中文"])); try stream.consume(line(["content": "流式"])); XCTAssertEqual(stream.text, "中文流式")
        try stream.consume(line(["tool_calls": [["index": 0, "id": "call-1", "function": ["name": "run_command", "arguments": "{\"command\":\"printf "]]]]))
        XCTAssertThrowsError(try stream.tools())
        try stream.consume(line(["tool_calls": [["index": 0, "function": ["arguments": "hello\",\"reason\":\"测试\"}"]]]], finish: "tool_calls"))
        let tool = try XCTUnwrap(try stream.tools().first); XCTAssertEqual(tool.command, "printf hello"); XCTAssertEqual(tool.reason, "测试")
        var broken = ServerAIStream(); XCTAssertThrowsError(try broken.consume(line([:], finish: "length")))
        XCTAssertThrowsError(try broken.consume("data: {\"error\":{\"message\":\"secret\"}}"))
    }
    func testModelDiscoveryUsesSameAPIPrefixAsChat() throws {
        for (address, expected) in [
            ("https://example.com", "/v1/models"),
            (" https://example.com/v1/ ", "/v1/models"),
            ("https://example.com/custom/v1", "/custom/v1/models"),
            ("https://example.com/custom/v1/chat/completions/", "/custom/v1/models")
        ] { XCTAssertEqual(try ServerAIProtocol.modelsEndpoint(address).path, expected) }
        for address in ["http://example.com", "https://user:secret@example.com", "https://example.com/v1?key=secret", "https://example.com/#token"] {
            XCTAssertThrowsError(try ServerAIProtocol.modelsEndpoint(address))
        }
    }
    func testModelDiscoveryParsesDeduplicatesAndRejectsInvalidResponses() throws {
        let data = try JSONSerialization.data(withJSONObject: ["data": [["id": "z-model"], ["id": "a-model"], ["id": "z-model"], ["id": " "], ["id": "bad\nmodel"], ["name": "missing-id"]]])
        XCTAssertEqual(try ServerAIProtocol.modelIDs(data), ["a-model", "z-model"])
        for invalid in ["{\"data\":[]}", "{\"models\":[\"a\"]}", "{\"error\":{},\"data\":[{\"id\":\"a\"}]}", "<html>login</html>"] {
            XCTAssertThrowsError(try ServerAIProtocol.modelIDs(Data(invalid.utf8)))
        }
    }
    func testServerAIAddressAndSecretRedaction() throws {
        XCTAssertEqual(try ServerAIProtocol.endpoint("https://example.com/").absoluteString, "https://example.com/v1/chat/completions")
        XCTAssertEqual(try ServerAIProtocol.endpoint("https://example.com/custom/v1/").path, "/custom/v1/chat/completions")
        XCTAssertEqual(try ServerAIProtocol.endpoint("https://example.com/v1/chat/completions").path, "/v1/chat/completions")
        for address in ["http://example.com", "https://user:pass@example.com", "https://example.com/?key=secret"] { XCTAssertThrowsError(try ServerAIProtocol.endpoint(address)) }
        let output = ServerAIProtocol.redact("password-123 Bearer token-456 sk-abcdefghijklmnopqrstuvwxyz\n-----BEGIN OPENSSH PRIVATE KEY-----\ndata\n-----END OPENSSH PRIVATE KEY-----", secrets: ["password-123"])
        for secret in ["password-123", "token-456", "sk-abcdefghijklmnopqrstuvwxyz", "data"] { XCTAssertFalse(output.contains(secret)) }
    }
    func testServerAICommandWrapperReturnsActualExitCode() throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/sh"); process.arguments = ["-c", ServerAIProtocol.shellCommand("printf '%s' '中文 $HOME'; exit 7", marker: "IFILE_TEST:")]
        let pipe = Pipe(); process.standardOutput = pipe; try process.run(); let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self); process.waitUntilExit()
        XCTAssertTrue(output.contains("中文 $HOME")); XCTAssertTrue(output.contains("IFILE_TEST:7"))
    }
    func testOpenClawCommandPreservesUntrustedTextAsOneArgument() throws {
        let folder = try temp()
        let script = folder.appendingPathComponent("mock openclaw")
        try Data("#!/bin/sh\nprintf '%s\\n' \"$@\"\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let message = "中文 ' \" $(printf injected) ; `printf injected` \\ 字符"
        let command = try OpenClawProtocol.command(executable: script.path, container: "", method: "chat.send", params: ["sessionKey": "agent:main:main", "message": message, "idempotencyKey": "stable-id"])
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/sh"); process.arguments = ["-c", command]
        let pipe = Pipe(); process.standardOutput = pipe; try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let lines = String(decoding: output, as: UTF8.self).components(separatedBy: "\n")
        let index = try XCTUnwrap(lines.firstIndex(of: "--params"))
        let params = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(lines[index + 1].utf8)) as? [String: String])
        XCTAssertEqual(params["message"], message)
        XCTAssertThrowsError(try OpenClawProtocol.command(executable: "openclaw", container: "name;bad", method: "chat.send", params: [:]))
        XCTAssertThrowsError(try OpenClawProtocol.command(executable: "openclaw", container: "", method: "config.set", params: [:]))
    }
    func testOpenClawResponseVariantsAndErrors() throws {
        XCTAssertEqual(try OpenClawProtocol.decode("doctor warning\n{\"sessions\":[]}")["sessions"] as? [String], [])
        XCTAssertEqual(try OpenClawProtocol.decode("{\"ok\":true,\"payload\":{\"runId\":\"run\"}}")["runId"] as? String, "run")
        XCTAssertThrowsError(try OpenClawProtocol.decode("{\"ok\":false,\"error\":{\"message\":\"permission denied\"}}"))
        XCTAssertThrowsError(try OpenClawProtocol.decode("openclaw: command not found"))
        XCTAssertEqual(OpenClawProtocol.text(["content": [["type":"text", "text":"可见"], ["type":"thinking", "text":"不可见"]]]), "可见")
    }
    func testChatMarkdownTablesAndPCLinks() {
        let blocks = ChatMarkdown.blocks("**数量**\n\n|名称|数量|\n|---|---:|\n|A\\|B|11|\n\n```\n|raw|code|\n```")
        XCTAssertEqual(blocks.count, 3)
        XCTAssertEqual(blocks[1], .table([["名称", "数量"], ["A|B", "11"]]))
        XCTAssertEqual(blocks[2], .code("|raw|code|"))
        XCTAssertTrue(ChatMarkdown.links("[下载](<D:/项目/测试.md>)").contains("ifilepc://download/"))
        XCTAssertEqual(ChatMarkdown.links("[网页](https://example.com)"), "[网页](https://example.com)")
        XCTAssertEqual(ChatMarkdown.blocks("|not a table|\n|normal text|"), [.text("|not a table|\n|normal text|")])
    }
    func temp() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    func fixture(_ name: String, in folder: URL) throws -> URL {
        let input = Bundle.module.url(forResource: name, withExtension: "zip", subdirectory: "Fixtures")!
        let copy = folder.appendingPathComponent(name + ".zip")
        try FileManager.default.copyItem(at: input, to: copy)
        return copy
    }
    func testCustomExtensionAndExtensionlessText() throws {
        let folder = try temp()
        for name in ["config.custom", "LICENSE", ".env"] {
            let file = try LocalFileService.createFile(named: name, in: folder)
            XCTAssertEqual(file.lastPathComponent, name)
            try LocalFileService.writeText("任意后缀文本", to: file)
            XCTAssertEqual(try LocalFileService.readText(file), "任意后缀文本")
            XCTAssertThrowsError(try LocalFileService.createFile(named: name, in: folder))
        }
        XCTAssertThrowsError(try LocalFileService.createFile(named: "../escape", in: folder))
    }
    func testZIPExtractionAndNoOverwrite() throws {
        let folder = try temp(); let source = try fixture("normal", in: folder)
        let first = try ArchiveService.extractZIP(source), second = try ArchiveService.extractZIP(source)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try LocalFileService.readText(first.appendingPathComponent("nested/content.unknown")), "测试文本\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }
    func testUnsafeAndCorruptArchivesLeaveNoOutput() throws {
        for name in ["traversal", "symlink", "duplicate", "corrupt"] {
            let folder = try temp(); let source = try fixture(name, in: folder)
            XCTAssertThrowsError(try ArchiveService.extractZIP(source), name)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [name + ".zip"])
        }
    }
    func testBinaryAndOversizedTextRejected() throws {
        let folder = try temp(); let file = folder.appendingPathComponent("unknown.xyz")
        try Data([0,1,2,0,3]).write(to: file)
        XCTAssertThrowsError(try LocalFileService.readText(file))
        try Data(repeating: 65, count: 5*1024*1024+1).write(to: file)
        XCTAssertThrowsError(try LocalFileService.readText(file))
    }
    private func chat(_ id: String, _ text: String = "message", role: String = "assistant", turn: String = "t", provisional: Bool = false) -> CodexChatMessage {
        CodexChatMessage(["id": id, "text": text, "role": role, "turnId": turn, "provisional": provisional])!
    }
    func testChatHistoryMergeKeepsDownloadAndInflightPhotoInOrder() {
        let latest = [chat("progress"), chat("stream", "正在输出")]
        let history = [chat("download", "[下载](<C:/build.ipa>)"), chat("photo", "📎 照片.jpg", role: "user"), chat("progress")]
        let result = CodexChatTimeline.merge(latest, history, history: true)
        XCTAssertEqual(result.map(\.id), ["download", "photo", "progress", "stream"])
        XCTAssertEqual(CodexChatTimeline.merge(result, history, history: true).map(\.id), result.map(\.id))
    }
    func testDelayedHistoryDoesNotEraseOrRewindStreamingReply() {
        let live = [chat("user", "问题", role: "user"), chat("reply", "正在输出完整内容")]
        let stale = [chat("user", "问题", role: "user"), chat("reply", "正在")]
        let result = CodexChatTimeline.merge(live, stale, history: true)
        XCTAssertEqual(result.last?.text, "正在输出完整内容")
        let completed = CodexChatTimeline.merge(result, [chat("reply", "正在输出完整内容，已完成")], history: true)
        XCTAssertEqual(completed.last?.text, "正在输出完整内容，已完成")
    }
    func testProvisionalPhotoInputReplacedByCanonicalMessageOnlyOnce() {
        let placeholder = chat("t:input", "📎 photo.jpg", role: "user", provisional: true)
        let real = chat("user-id", "📎 photo.jpg", role: "user")
        let result = CodexChatTimeline.merge([placeholder, chat("reply")], [real, chat("reply")])
        XCTAssertEqual(result.map(\.id), ["user-id", "reply"])
        XCTAssertEqual(CodexChatTimeline.merge(result, [placeholder, chat("reply")]).map(\.id), ["user-id", "reply"])
    }
    func testDisjointPersistedWindowPrecedesLiveWorkAndMemoryIsBounded() {
        let result = CodexChatTimeline.merge([chat("live")], [chat("old1"), chat("old2")], history: true)
        XCTAssertEqual(result.map(\.id), ["old1", "old2", "live"])
        let many = (0..<140).map { chat("row\($0)") }
        XCTAssertEqual(CodexChatTimeline.merge([], many).count, 100)
    }
    func testOlderDesktopIslandNeverAppearsAfterCurrentReply() {
        let old = CodexChatMessage(["id": "old", "text": "old", "startedAtMs": 1000])!
        let current = CodexChatMessage(["id": "new", "text": "new", "startedAtMs": 2000])!
        XCTAssertEqual(CodexChatTimeline.merge([current], [old]).map(\.id), ["old", "new"])
        XCTAssertEqual(CodexChatTimeline.merge([old], [current], history: true).map(\.id), ["old", "new"])
    }
    func testAssistantParagraphsAndCommandsShareOneContinuousTurn() {
        let rows = [chat("user", role: "user"), chat("first"), chat("cmd", role: "tool"), chat("final"), chat("next-user", role: "user", turn: "t2"), chat("next-reply", turn: "t2")]
        let groups = CodexChatTimeline.groups(rows)
        XCTAssertEqual(groups.count, 4)
        XCTAssertEqual(groups[1].items.map(\.id), ["first", "cmd", "final"])
        XCTAssertEqual(groups[1].text, "message\n\nmessage")
        XCTAssertEqual(groups[1].reply?.id, "final")
    }
    func testConsecutiveCommandsCollapseWithoutCrossingAReply() {
        let rows = [chat("intro"), chat("c1", role: "tool"), chat("c2", role: "tool"), chat("c3", role: "tool"), chat("c4", role: "tool"), chat("reply"), chat("c5", role: "tool")]
        let blocks = CodexChatTimeline.groups(rows)[0].blocks
        XCTAssertEqual(blocks.map { $0.items.count }, [1, 4, 1, 1])
        XCTAssertTrue(blocks[1].isCommands)
        XCTAssertFalse(blocks[2].isCommands)
    }
    func testDownloadProgressDoesNotClaimSavedBeforeVerification() {
        var state = CodexDownloadState(name: "app.ipa")
        XCTAssertNil(state.progress); XCTAssertTrue(state.active)
        state.phase = .receiving; state.total = 100; state.received = 40
        XCTAssertEqual(state.progress, 0.4); XCTAssertTrue(state.title.contains("40%"))
        state.received = 100; state.phase = .verifying
        XCTAssertEqual(state.progress, 1); XCTAssertFalse(state.title.contains("成功")); XCTAssertTrue(state.active)
        state.file = URL(fileURLWithPath: "/tmp/app.ipa"); state.phase = .saved
        XCTAssertEqual(state.title, "下载成功"); XCTAssertFalse(state.active)
    }
    func testDownloadFailureCancellationAndEmptyFileAreExplicit() {
        var state = CodexDownloadState(name: "empty.txt")
        state.total = 0; state.phase = .verifying
        XCTAssertEqual(state.progress, 1)
        state.phase = .failed; state.error = "校验失败"
        XCTAssertEqual(state.title, "下载失败"); XCTAssertFalse(state.active); XCTAssertNil(state.file)
        state.phase = .cancelling; XCTAssertTrue(state.active)
        state.phase = .cancelled; XCTAssertEqual(state.title, "下载已取消"); XCTAssertFalse(state.active)
    }
    func testCompletionTimeSurvivesHistoryRefreshWithoutInventingOne() {
        let completed = CodexChatMessage(["id": "answer", "text": "done", "completedAtMs": 1700000000123.0])!
        let missing = CodexChatMessage(["id": "answer", "text": "done"])!
        XCTAssertNil(missing.completedAt)
        XCTAssertEqual(CodexChatTimeline.merge([completed], [missing], history: true).last?.completedAt, 1700000000123.0)
        XCTAssertEqual(CodexChatTimeline.merge([missing], [completed], history: true).last?.completedAt, 1700000000123.0)
    }
    func testImageOnlyMessageHasNoTextBubbleAndMixedMessagePreservesText() {
        let image = "📎 [图片](<C:/photo.jpg>)"
        XCTAssertEqual(CodexMessageImages(image).body, "")
        XCTAssertEqual(CodexMessageImages("解释图片\n" + image).body, "解释图片")
        XCTAssertEqual(CodexMessageImages(image + "\n" + image).paths, ["C:/photo.jpg"])
    }

    func testThumbnailRequestsCoalesceAndSurviveScrollCancellationAndReentry() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = CodexThumbnailCache(directory: dir)
        let counter = ThumbnailLoadCounter()
        let first = Task { try await cache.data(for: "host/thread/photo") { await counter.load() } }
        try await Task.sleep(nanoseconds: 10000000)
        first.cancel()
        let second = try await cache.data(for: "host/thread/photo") { await counter.load() }
        _ = try await first.value
        XCTAssertEqual(second, Data("thumbnail".utf8))
        let total = await counter.count
        XCTAssertEqual(total, 1)
        let reopened = CodexThumbnailCache(directory: dir)
        let cached = try await reopened.data(for: "host/thread/photo") { await counter.load() }
        XCTAssertEqual(cached, second)
        let afterReentry = await counter.count
        XCTAssertEqual(afterReentry, 1)
        _ = try await reopened.data(for: "different-host/thread/photo") { await counter.load() }
        let afterOtherDevice = await counter.count
        XCTAssertEqual(afterOtherDevice, 2)
    }

    func testSteeredPhotoStaysVisibleAcrossRefreshUntilCanonicalMessageReplacesIt() {
        let queued = CodexQueuedMessage(["id": "steer-id", "text": "补充", "displayText": "补充\n📎 [照片](<C:/photo.jpg>)"])!
        let outgoing = CodexChatMessage(id: queued.id, text: queued.displayText, delivery: "正在引导…")
        let older = chat("older", "previous reply")
        let waiting = CodexChatTimeline.merge([older, outgoing], [older], history: true)
        XCTAssertEqual(waiting.last?.id, queued.id)
        XCTAssertEqual(CodexMessageImages(waiting.last!.text).paths, ["C:/photo.jpg"])
        let canonical = CodexChatMessage(["id": "native-user", "role": "user", "text": queued.displayText, "clientMessageId": queued.id])!
        let confirmed = CodexChatTimeline.merge(waiting, [older, canonical], history: true)
        XCTAssertEqual(confirmed.filter { $0.role == "user" }.count, 1)
        XCTAssertEqual(confirmed.last?.id, "native-user")
    }

}

private actor ThumbnailLoadCounter {
    var count = 0
    func load() async -> Data {
        count += 1
        try? await Task.sleep(nanoseconds: 80000000)
        return Data("thumbnail".utf8)
    }
}
