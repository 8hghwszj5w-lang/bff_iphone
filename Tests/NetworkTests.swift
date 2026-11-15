import XCTest
import Foundation
@testable import FenShen

final class NetworkTests: XCTestCase {
    @MainActor private func makeSettings() -> SettingsStore {
        let suite = "FenShenNetworkTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        settings.apiKey = "offline-test-key"
        return settings
    }

    private var tool: ToolDefinition { WebSearchTool().definition }

    private func makeFixture(_ replies: [NetworkFixture.Reply], host: String = UUID().uuidString.lowercased() + ".invalid") -> (NetworkFixture, URLSession, String) {
        let fixture = NetworkFixture(replies: replies)
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
    }
    private let lock = NSLock()
    private var replies: [Reply]
    private var bodies: [Data] = []
    init(replies: [Reply]) { self.replies = replies }
    var requestBodies: [Data] {
        lock.lock(); defer { lock.unlock() }
        return bodies
    }
    func next(body: Data) -> Reply? {
        lock.lock(); defer { lock.unlock() }
        bodies.append(body)
        return replies.isEmpty ? nil : replies.removeFirst()
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
              let fixture = Self.registry.get(host: url.host ?? ""),
              let reply = fixture.next(body: body),
              let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
