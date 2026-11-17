import XCTest
import Foundation
@testable import FenShen

final class NetworkTests: XCTestCase {
    @MainActor private func makeSettings() -> SettingsStore {
        let suite = "FenShenNetworkTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let keychain = KeychainStore(service: suite)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            keychain.remove(account: "settings.apiKey")
        }
        let settings = SettingsStore(defaults: defaults, keychain: keychain)
        settings.apiKey = "offline-test-key"
        return settings
    }

    private var tool: ToolDefinition { WebSearchTool().definition }

    private func makeFixture(_ replies: [NetworkFixture.Reply], host: String = UUID().uuidString.lowercased() + ".invalid",
                             uploadDirectory: URL? = nil, onRequest: (@Sendable () -> Void)? = nil,
                             onStop: (@Sendable () -> Void)? = nil) -> (NetworkFixture, URLSession, String) {
        let fixture = NetworkFixture(replies: replies, uploadDirectory: uploadDirectory,
                                     onRequest: onRequest, onStop: onStop)
        OfflineNetworkProtocol.registry.set(fixture, host: host)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OfflineNetworkProtocol.self]
        let session = URLSession(configuration: configuration)
        addTeardownBlock {
            session.invalidateAndCancel()
            OfflineNetworkProtocol.registry.set(nil, host: host)
        }
        return (fixture, session, "https://\(host)/v1")
    }

    private func makeUploadDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FenShenNetworkTests-\(UUID().uuidString)", isDirectory: true)
        let directory = root.appendingPathComponent("uploads", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return directory
    }

    private func assertNoUploadFiles(_ directory: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty, file: file, line: line)
    }

    private func assertMultipart(_ request: NetworkFixture.Request, payload: Data, filename: String, purpose: String,
                                 file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(request.request.httpMethod, "POST", file: file, line: line)
        XCTAssertEqual(request.request.url?.path, "/files", file: file, line: line)
        XCTAssertEqual(request.request.value(forHTTPHeaderField: "Authorization"), "Bearer offline-test-key", file: file, line: line)
        XCTAssertEqual(request.request.timeoutInterval, 600, file: file, line: line)
        XCTAssertNil(request.request.httpBody, "Upload must not attach a whole multipart Data", file: file, line: line)
        let contentType = try XCTUnwrap(request.request.value(forHTTPHeaderField: "Content-Type"), file: file, line: line)
        let prefix = "multipart/form-data; boundary="
        XCTAssertTrue(contentType.hasPrefix(prefix), file: file, line: line)
        let boundary = String(contentType.dropFirst(prefix.count))
        XCTAssertTrue(boundary.hasPrefix("FenShen-"), file: file, line: line)
        var expected = Data(("--\(boundary)\r\n"
            + "Content-Disposition: form-data; name=\"purpose\"\r\n\r\n\(purpose)\r\n"
            + "--\(boundary)\r\n"
            + "Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n"
            + "Content-Type: application/octet-stream\r\n\r\n").utf8)
        expected.append(payload)
        expected.append(Data("\r\n--\(boundary)--\r\n".utf8))
        XCTAssertEqual(request.stagedFiles.count, 1, file: file, line: line)
        XCTAssertEqual(try XCTUnwrap(request.stagedBody, file: file, line: line), expected, file: file, line: line)
        // 部分系统的 URLProtocol 不暴露 fromFile 的 stream；暴露时同时验证线上 body。
        if !request.body.isEmpty { XCTAssertEqual(request.body, expected, file: file, line: line) }
        XCTAssertTrue(request.stagedFiles.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) }, file: file, line: line)
    }

    private func event(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return "data: " + String(decoding: data, as: UTF8.self) + "\n\n"
    }

    private func toolReply(ids: [String] = ["call_1"], name: String = "web_search") throws -> String {
        let calls: [[String: Any]] = ids.enumerated().map { index, id in
            ["index": index, "id": id, "type": "function", "function": ["name": name, "arguments": "{\"query\":\"test\"}"]]
        }
        return try event(["choices": [["delta": ["tool_calls": calls], "finish_reason": "tool_calls"]]])
            + event(["choices": [], "usage": ["prompt_tokens": 2, "completion_tokens": 3]])
            + "data: [DONE]\n\n"
    }

    @MainActor func testCompletionURLValidatesAndPreservesPrefix() throws {
        XCTAssertEqual(try DeepSeekClient.completionURL(baseURL: " https://example.com/proxy/v1/// \n").absoluteString,
                       "https://example.com/proxy/v1/chat/completions")
        XCTAssertEqual(try DeepSeekClient.completionURL(baseURL: "http://127.0.0.1:8000").absoluteString,
                       "http://127.0.0.1:8000/chat/completions")
        for invalid in ["", "example.com", "/relative", "file:///tmp/key", "https:///", "https://user:pass@example.com", "https://example.com?token=secret", "https://example.com#fragment"] {
            XCTAssertThrowsError(try DeepSeekClient.completionURL(baseURL: invalid), invalid)
        }
    }

    @MainActor func testFilesURLPreservesProxyPrefixAndRemovesOnlyTrailingV1() throws {
        XCTAssertEqual(try DeepSeekClient.filesURL(baseURL: " https://example.com/proxy/v1/// \n").absoluteString,
                       "https://example.com/proxy/files")
        XCTAssertEqual(try DeepSeekClient.filesURL(baseURL: "https://example.com/v10").absoluteString,
                       "https://example.com/v10/files")
        for invalid in ["", "file:///tmp/document", "https://user:pass@example.com", "https://example.com?key=secret"] {
            XCTAssertThrowsError(try DeepSeekClient.filesURL(baseURL: invalid))
        }
    }

    @MainActor func testDataUploadsPreserveMultipartAtChunkBoundariesAndCleanFiles() async throws {
        // 空文件、单块边界及跨块二进制内容，包含 Data 非零 startIndex 的切片。
        let sizes = [0, 1, 65_535, 65_536, 65_537, 131_073]
        let directory = try makeUploadDirectory()
        let (fixture, session, baseURL) = makeFixture(sizes.map { _ in .init(body: "{\"id\":\"file-api-test\"}") }, uploadDirectory: directory)
        let settings = makeSettings()
        settings.baseURL = baseURL
        let client = DeepSeekClient(settings: settings, session: session, uploadDirectory: directory)
        for size in sizes {
            let bytes = Data((0..<(size + 7)).map { UInt8($0 % 251) })
            let payload = bytes.dropFirst(7)
            let id = try await client.uploadFile(data: payload, filename: "附件.bin", purpose: "user_data")
            XCTAssertEqual(id, "file-api-test")
            try assertMultipart(XCTUnwrap(fixture.requests.last), payload: payload, filename: "附件.bin", purpose: "user_data")
            try assertNoUploadFiles(directory)
        }
        XCTAssertEqual(fixture.requests.count, sizes.count)
    }

    @MainActor func testURLUploadPreservesFileContentAndLeavesSourceUntouched() async throws {
        let directory = try makeUploadDirectory()
        let source = directory.deletingLastPathComponent().appendingPathComponent("source.pdf")
        let payload = Data((0..<196_619).map { UInt8($0 % 253) })
        try payload.write(to: source)
        let (fixture, session, baseURL) = makeFixture([.init(body: "{\"id\":\"file-api-url\"}")], uploadDirectory: directory)
        let settings = makeSettings()
        settings.baseURL = baseURL
        let id = try await DeepSeekClient(settings: settings, session: session, uploadDirectory: directory)
            .uploadFile(fileURL: source, filename: "报告.pdf", purpose: "text_recognition")
        XCTAssertEqual(id, "file-api-url")
        try assertMultipart(XCTUnwrap(fixture.requests.first), payload: payload, filename: "报告.pdf", purpose: "text_recognition")
        XCTAssertEqual(try Data(contentsOf: source), payload)
        try assertNoUploadFiles(directory)
    }

    @MainActor func testUploadHTTPAndInvalidResponseErrorsPreserveMessagesAndCleanFiles() async throws {
        let cases: [(NetworkFixture.Reply, String)] = [
            (.init(status: 400, body: "{\"error\":{\"message\":\"bad purpose\"}}"), "文件上传失败（HTTP 400）：bad purpose"),
            (.init(status: 503, body: "unavailable"), "文件上传失败（HTTP 503）"),
            (.init(body: "{}"), "文件上传响应缺少 file_id，已停止"),
            (.init(body: "{\"id\":\"\"}"), "文件上传响应缺少 file_id，已停止"),
            (.init(body: "not-json"), "文件上传响应缺少 file_id，已停止")
        ]
        let directory = try makeUploadDirectory()
        let (fixture, session, baseURL) = makeFixture(cases.map(\.0), uploadDirectory: directory)
        let settings = makeSettings()
        settings.baseURL = baseURL
        let client = DeepSeekClient(settings: settings, session: session, uploadDirectory: directory)
        for (_, expected) in cases {
            do {
                _ = try await client.uploadFile(data: Data([0, 255]), filename: "test.bin", purpose: "user_data")
                XCTFail("Expected upload error")
            } catch { XCTAssertEqual((error as? ToolLoopError)?.message, expected) }
            try assertNoUploadFiles(directory)
        }
        XCTAssertEqual(fixture.requests.count, cases.count, "Failed uploads must not retry")
        XCTAssertTrue(fixture.requests.allSatisfy { $0.stagedFiles.count == 1 })
    }

    @MainActor func testUploadTransportErrorCleansTemporaryFile() async throws {
        let directory = try makeUploadDirectory()
        let (fixture, session, baseURL) = makeFixture([.init(body: "", error: URLError(.networkConnectionLost))], uploadDirectory: directory)
        let settings = makeSettings()
        settings.baseURL = baseURL
        do {
            _ = try await DeepSeekClient(settings: settings, session: session, uploadDirectory: directory)
                .uploadFile(data: Data("document".utf8), filename: "test.txt", purpose: "user_data")
            XCTFail("Expected transport error")
        } catch { XCTAssertEqual((error as? URLError)?.code, .networkConnectionLost) }
        XCTAssertEqual(fixture.requests.count, 1)
        XCTAssertEqual(fixture.requests.first?.stagedFiles.count, 1)
        try assertNoUploadFiles(directory)
    }

    @MainActor func testUploadCancellationStopsRequestAndCleansTemporaryFile() async throws {
        let directory = try makeUploadDirectory()
        let started = expectation(description: "Upload request started")
        let stopped = expectation(description: "Upload request cancelled")
        let (fixture, session, baseURL) = makeFixture([.init(body: "", waitsForCancellation: true)], uploadDirectory: directory,
                                                    onRequest: { started.fulfill() }, onStop: { stopped.fulfill() })
        let settings = makeSettings()
        settings.baseURL = baseURL
        let client = DeepSeekClient(settings: settings, session: session, uploadDirectory: directory)
        let task = Task { @MainActor in
            try await client.uploadFile(data: Data(repeating: 42, count: 131_073), filename: "test.bin", purpose: "user_data")
        }
        await fulfillment(of: [started], timeout: 3)
        XCTAssertEqual(fixture.requests.count, 1)
        let staged = try XCTUnwrap(fixture.requests.first?.stagedFiles.first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path))
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled) }
        await fulfillment(of: [stopped], timeout: 3)
        try assertNoUploadFiles(directory)
    }

    @MainActor func testUploadPreparationFailureAndPreCancellationMakeNoRequestOrLeaks() async throws {
        let directory = try makeUploadDirectory()
        let (fixture, session, baseURL) = makeFixture([], uploadDirectory: directory)
        let settings = makeSettings()
        settings.baseURL = baseURL
        let client = DeepSeekClient(settings: settings, session: session, uploadDirectory: directory)
        do {
            _ = try await client.uploadFile(fileURL: directory.appendingPathComponent("missing.pdf"), filename: "missing.pdf", purpose: "text_recognition")
            XCTFail("Expected source file error")
        } catch { XCTAssertFalse(error is CancellationError) }
        try assertNoUploadFiles(directory)
        let task = Task { @MainActor in
            try await client.uploadFile(data: Data(repeating: 1, count: 131_073), filename: "test.bin", purpose: "user_data")
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        try assertNoUploadFiles(directory)
        XCTAssertTrue(fixture.requests.isEmpty)
        settings.apiKey = " \n"
        do {
            _ = try await client.uploadFile(data: Data(), filename: "empty", purpose: "user_data")
            XCTFail("Expected missing key error")
        } catch { XCTAssertEqual((error as? ToolLoopError)?.message, "还没有填 API Key，请到「设置」里填写 DeepSeek API Key") }
        try assertNoUploadFiles(directory)
        XCTAssertTrue(fixture.requests.isEmpty)
    }

    @MainActor func testRequestEncodesMessagesAndToolsWithoutRoundtrip() throws {
        let settings = makeSettings()
        let client = DeepSeekClient(settings: settings)
        let call = ToolCall(id: "id-1", type: "function", function: .init(name: "web_search", arguments: "{}"))
        let messages = [ChatMessage.system(""), ChatMessage(role: "assistant", content: "", toolCalls: [call]), .tool(result: "结果", for: "id-1")]
        let request = try client.makeRequest(messages: messages, tools: [tool])
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "text/event-stream")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer offline-test-key")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        let encodedMessages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(encodedMessages[0]["content"] as? String, " ")
        XCTAssertEqual(encodedMessages[2]["tool_call_id"] as? String, "id-1")
        XCTAssertEqual((encodedMessages[1]["tool_calls"] as? [[String: Any]])?.first?["id"] as? String, "id-1")
        XCTAssertEqual((body["stream_options"] as? [String: Bool])?["include_usage"], true)
        XCTAssertEqual((body["tools"] as? [[String: Any]])?.count, 1)
        let withoutTools = try client.makeRequest(messages: [.user("hello")], tools: [])
        let plainBody = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(withoutTools.httpBody)) as? [String: Any])
        XCTAssertNil(plainBody["tools"])
        settings.temperature = .nan
        XCTAssertThrowsError(try client.makeRequest(messages: [], tools: [tool]))
    }

    @MainActor func testRequestRejectsBlankKey() {
        let settings = makeSettings()
        settings.apiKey = " \n"
        XCTAssertThrowsError(try DeepSeekClient(settings: settings).makeRequest(messages: [], tools: []))
    }

    func testSSETextUsageAndDone() throws {
        var stream = DeepSeekClient.StreamAccumulator()
        XCTAssertNil(try stream.consume(line: ": keep-alive"))
        XCTAssertEqual(try stream.consume(line: "data:{\"choices\":[{\"delta\":{\"content\":\" hello \"}}]}"), " hello ")
        _ = try stream.consume(line: "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}")
        _ = try stream.consume(line: "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":11,\"completion_tokens\":7}}")
        _ = try stream.consume(line: "data: [DONE]")
        XCTAssertTrue(stream.isDone)
        let (text, calls, usage) = try stream.finish()
        XCTAssertEqual(text, "hello")
        XCTAssertTrue(calls.isEmpty)
        XCTAssertEqual(usage.promptTokens, 11)
        XCTAssertEqual(usage.completionTokens, 7)
    }

    func testSSEFinishReasonOnlyCompatibility() throws {
        var stream = DeepSeekClient.StreamAccumulator()
        _ = try stream.consume(line: "data: {\"choices\":[{\"delta\":{\"content\":\"ok\"},\"finish_reason\":\"stop\"}]}")
        XCTAssertFalse(stream.isDone)
        XCTAssertEqual(try stream.finish().0, "ok")
    }

    func testSSERejectsTruncationMalformedJSONAndAPIErrors() throws {
        var truncated = DeepSeekClient.StreamAccumulator()
        _ = try truncated.consume(line: "data: {\"choices\":[{\"delta\":{\"content\":\"partial\"}}]}")
        XCTAssertThrowsError(try truncated.finish())
        var empty = DeepSeekClient.StreamAccumulator()
        _ = try empty.consume(line: "data: [DONE]")
        XCTAssertThrowsError(try empty.finish())
        for line in ["data: not-json", "data: {\"error\":{\"message\":\"quota exceeded\"}}", "data: {\"error\":\"failure\"}", "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"length\"}]}", "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"content_filter\"}]}"] {
            var stream = DeepSeekClient.StreamAccumulator()
            XCTAssertThrowsError(try stream.consume(line: line), line)
        }
    }

    func testSSEAssemblesToolFragmentsByIndexIncludingLateID() throws {
        var stream = DeepSeekClient.StreamAccumulator()
        let pieces: [[String: Any]] = [
            ["index": 1, "function": ["name": "web_", "arguments": "{\"query\":"]],
            ["index": 0, "id": "first", "function": ["name": "web_search", "arguments": "{}"]],
            ["index": 1, "id": "second", "function": ["name": "search", "arguments": "\"swift\"}"]]
        ]
        for piece in pieces {
            _ = try stream.consume(line: event(["choices": [["delta": ["tool_calls": [piece]]]]]).trimmingCharacters(in: .newlines))
        }
        _ = try stream.consume(line: "data: [DONE]")
        let calls = try stream.finish().1
        XCTAssertEqual(calls.map(\.id), ["first", "second"])
        XCTAssertEqual(calls[1].function.name, "web_search")
        XCTAssertEqual(calls[1].function.arguments, "{\"query\":\"swift\"}")
    }

    func testSSERejectsIncompleteAndDuplicateToolIDs() throws {
        let invalidCalls: [[[String: Any]]] = [
            [["index": 0, "function": ["name": "web_search", "arguments": "{}"]]],
            [["index": 0, "id": "same", "function": ["name": "web_search", "arguments": "{}"]],
             ["index": 1, "id": "same", "function": ["name": "web_search", "arguments": "{}"]]]
        ]
        for calls in invalidCalls {
            var stream = DeepSeekClient.StreamAccumulator()
            _ = try stream.consume(line: event(["choices": [["delta": ["tool_calls": calls]]]]).trimmingCharacters(in: .newlines))
            _ = try stream.consume(line: "data: [DONE]")
            XCTAssertThrowsError(try stream.finish())
        }
    }

    func testSearchURLPreservesReservedCharacters() throws {
        let query = "C++ & Swift # 中文?=yes"
        let url = try XCTUnwrap(WebSearchTool.searchURL(query: query))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.queryItems, [URLQueryItem(name: "q", value: query)])
        XCTAssertTrue(url.absoluteString.contains("%2B%2B"))
        XCTAssertNil(components.fragment)
    }

    func testJSONStringIsEscapedScalarNotArray() throws {
        let value = "引号\"、反斜线\\、换行\n"
        let json = WebSearchTool.jsonString(value)
        XCTAssertEqual(try JSONDecoder().decode(String.self, from: Data(json.utf8)), value)
        XCTAssertFalse(json.hasPrefix("["))
    }

    func testSearchParsesProtocolRelativeRedirectAndDirectLinks() {
        let html = """
        <div class="result__body"><a class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2F%3Fa%3D1%26b%3D2&amp;rut=abc">A &amp; B</a><a class="result__snippet">some <b>text</b></a></div>
        <div class="result__body"><a href="https://swift.org/" class="result__a">Swift</a><a class="result__snippet">Language</a></div>
        <div class="result__body"><a class="result__a" href="javascript:alert(1)">Unsafe</a></div>
        """
        let results = WebSearchTool().parseResults(from: html, limit: 5)
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results.first?.title, "A & B")
        XCTAssertEqual(results.first?.snippet, "some text")
        XCTAssertEqual(results.first?.url, "https://example.com/?a=1&b=2")
        XCTAssertEqual(results.last?.url, "https://swift.org/")
        XCTAssertTrue(WebSearchTool().parseResults(from: html, limit: 0).isEmpty)
        XCTAssertEqual(WebSearchTool().parseResults(from: html, limit: 1).count, 1)
    }

    @MainActor func testThreeToolRoundsThenOneSummaryAndUsageAggregation() async throws {
        let tools = try toolReply()
        let final = try event(["choices": [["delta": ["content": "final"], "finish_reason": "stop"]]])
            + event(["choices": [], "usage": ["prompt_tokens": 2, "completion_tokens": 3]]) + "data: [DONE]\n\n"
        let (fixture, session, baseURL) = makeFixture([.init(body: tools), .init(body: tools), .init(body: tools), .init(body: final)])
        let settings = makeSettings()
        settings.baseURL = baseURL
        var runs = 0
        let (text, usage) = try await DeepSeekClient(settings: settings, session: session).ask(messages: [.user("search")], tools: [tool], toolRunner: { _, _ in
            runs += 1
            return "result"
        })
        XCTAssertEqual(text, "final")
        XCTAssertEqual(runs, 3)
        XCTAssertEqual(usage.promptTokens, 8)
        XCTAssertEqual(usage.completionTokens, 12)
        let bodies = try fixture.requestBodies.map { try XCTUnwrap(JSONSerialization.jsonObject(with: $0) as? [String: Any]) }
        XCTAssertEqual(bodies.count, 4)
        XCTAssertTrue(bodies.prefix(3).allSatisfy { $0["tools"] != nil })
        XCTAssertNil(bodies.last?["tools"])
        XCTAssertEqual((bodies.last?["messages"] as? [[String: Any]])?.count, 7)
    }

    @MainActor func testUndeclaredToolIsRejectedBeforeRunner() async throws {
        let (fixture, session, baseURL) = makeFixture([.init(body: try toolReply(name: "not_declared"))])
        let settings = makeSettings()
        settings.baseURL = baseURL
        do {
            _ = try await DeepSeekClient(settings: settings, session: session).ask(messages: [.user("hi")], tools: [tool], toolRunner: { _, _ in
                XCTFail("Undeclared tool must not run")
                return ""
            })
            XCTFail("Expected undeclared tool error")
        } catch { XCTAssertTrue(error is ToolLoopError) }
        XCTAssertEqual(fixture.requestBodies.count, 1)
    }

    @MainActor func testTruncatedStreamDoesNotRetryOrRepeatDeltas() async throws {
        let body = try event(["choices": [["delta": ["content": "partial"]]]])
        let (fixture, session, baseURL) = makeFixture([.init(body: body)])
        let settings = makeSettings()
        settings.baseURL = baseURL
        var deltas: [String] = []
        do {
            _ = try await DeepSeekClient(settings: settings, session: session).ask(messages: [.user("hi")], tools: [], toolRunner: { _, _ in XCTFail("No tools expected"); return "" }, onDelta: { deltas.append($0) })
            XCTFail("Expected truncated stream error")
        } catch { XCTAssertTrue(error is ToolLoopError) }
        XCTAssertEqual(deltas, ["partial"])
        XCTAssertEqual(fixture.requestBodies.count, 1)
    }

    @MainActor func testCancellationDuringFirstToolStopsRemainingToolsAndRequests() async throws {
        let (fixture, session, baseURL) = makeFixture([.init(body: try toolReply(ids: ["one", "two"]))])
        let settings = makeSettings()
        settings.baseURL = baseURL
        var runs = 0
        let task = Task { @MainActor in
            try await DeepSeekClient(settings: settings, session: session).ask(messages: [.user("search")], tools: [self.tool], toolRunner: { _, _ in
                runs += 1
                withUnsafeCurrentTask { $0?.cancel() }
                return "cancelled"
            })
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(runs, 1)
        XCTAssertEqual(fixture.requestBodies.count, 1)
    }

    @MainActor func testAlreadyCancelledAskMakesNoRequest() async throws {
        let (fixture, session, baseURL) = makeFixture([])
        let settings = makeSettings()
        settings.baseURL = baseURL
        let task = Task { @MainActor in
            try await DeepSeekClient(settings: settings, session: session).ask(messages: [], tools: [], toolRunner: { _, _ in XCTFail("No tools expected"); return "" })
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(fixture.requestBodies.isEmpty)
    }

    func testSearchHTTPFailureIsErrorRatherThanEmptyResults() async throws {
        let (fixture, session, _) = makeFixture([.init(status: 503, body: "unavailable")], host: "html.duckduckgo.com")
        let output = await WebSearchTool(session: session).run(argumentsJSON: "{\"query\":\"swift\"}")
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        XCTAssertTrue((result["error"] as? String)?.contains("503") == true)
        XCTAssertNil(result["results"])
        XCTAssertEqual(fixture.requestBodies.count, 1)
    }
}

// Every request is intercepted, including unexpected hosts: these tests never contact a paid API.
private final class NetworkFixture: @unchecked Sendable {
    struct Reply {
        var status = 200
        var body: String
        var error: URLError? = nil
        var waitsForCancellation = false
    }
    struct Request {
        let request: URLRequest
        let body: Data
        let stagedFiles: [URL]
        let stagedBody: Data?
    }
    private let lock = NSLock()
    private var replies: [Reply]
    private var recordedRequests: [Request] = []
    private let uploadDirectory: URL?
    private let onRequest: (@Sendable () -> Void)?
    let onStop: (@Sendable () -> Void)?
    init(replies: [Reply], uploadDirectory: URL? = nil, onRequest: (@Sendable () -> Void)? = nil,
         onStop: (@Sendable () -> Void)? = nil) {
        self.replies = replies
        self.uploadDirectory = uploadDirectory
        self.onRequest = onRequest
        self.onStop = onStop
    }
    var requests: [Request] {
        lock.lock(); defer { lock.unlock() }
        return recordedRequests
    }
    var requestBodies: [Data] { requests.map(\.body) }
    func next(request: URLRequest, body: Data) -> Reply? {
        // CFNetwork 不保证 URLProtocol 看得到 fromFile 的 stream；在请求存活期间验证磁盘体。
        let files = uploadDirectory.flatMap { try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil) } ?? []
        let stagedBody = files.first.flatMap { try? Data(contentsOf: $0) }
        lock.lock()
        recordedRequests.append(Request(request: request, body: body, stagedFiles: files, stagedBody: stagedBody))
        let reply = replies.isEmpty ? nil : replies.removeFirst()
        lock.unlock()
        onRequest?()
        return reply
    }
}

private final class NetworkFixtureRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var fixtures: [String: NetworkFixture] = [:]
    func set(_ fixture: NetworkFixture?, host: String) {
        lock.lock(); defer { lock.unlock() }
        fixtures[host] = fixture
    }
    func get(host: String) -> NetworkFixture? {
        lock.lock(); defer { lock.unlock() }
        return fixtures[host]
    }
}

private final class OfflineNetworkProtocol: URLProtocol {
    static let registry = NetworkFixtureRegistry()
    private var fixture: NetworkFixture?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(contentsOf: buffer.prefix(count))
            }
        }
        guard let url = request.url,
              let fixture = Self.registry.get(host: url.host ?? "") else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        self.fixture = fixture
        guard let reply = fixture.next(request: request, body: body),
              let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if let error = reply.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        // 挂起到消费方取消：用于验证取消会真正停掉传输并清理临时文件。
        if reply.waitsForCancellation { return }
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { fixture?.onStop?() }
}
