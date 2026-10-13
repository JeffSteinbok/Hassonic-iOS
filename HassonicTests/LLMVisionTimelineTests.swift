import XCTest
@testable import Hassonic

final class LLMVisionTimelineTests: XCTestCase {

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    // MARK: - Decoding

    func testEventDecodesAllFields() throws {
        let json = """
        {
            "uid": "abc123",
            "title": "Person at Front Door",
            "description": "A person was detected at the front door.",
            "start": "2024-01-15T08:30:00Z",
            "end": "2024-01-15T08:30:10Z",
            "key_frame": "/media/llmvision/snapshots/abc123.jpg",
            "camera_name": "camera.front_door",
            "category": "person",
            "label": "person"
        }
        """.data(using: .utf8)!

        let event = try decoder.decode(LLMVisionEvent.self, from: json)

        XCTAssertEqual(event.uid, "abc123")
        XCTAssertEqual(event.title, "Person at Front Door")
        XCTAssertEqual(event.description, "A person was detected at the front door.")
        XCTAssertEqual(event.keyFrame, "/media/llmvision/snapshots/abc123.jpg")
        XCTAssertEqual(event.cameraName, "camera.front_door")
        XCTAssertEqual(event.category, "person")
        XCTAssertNotNil(event.startDate)
    }

    func testEventDecodesWithMissingOptionalFields() throws {
        let json = """
        {
            "uid": "minimal"
        }
        """.data(using: .utf8)!

        let event = try decoder.decode(LLMVisionEvent.self, from: json)

        XCTAssertEqual(event.uid, "minimal")
        XCTAssertNil(event.title)
        XCTAssertNil(event.description)
        XCTAssertNil(event.keyFrame)
        XCTAssertNil(event.cameraName)
        XCTAssertNil(event.category)
        XCTAssertNil(event.startDate)
    }

    func testTimelineResponseDecodesEvents() throws {
        let json = """
        {
            "events": [
                { "uid": "e1", "title": "Event 1", "start": "2024-01-15T09:00:00Z" },
                { "uid": "e2", "title": "Event 2", "start": "2024-01-15T08:00:00Z" }
            ]
        }
        """.data(using: .utf8)!

        let response = try decoder.decode(LLMVisionTimelineResponse.self, from: json)

        XCTAssertEqual(response.events.count, 2)
        XCTAssertEqual(response.events[0].uid, "e1")
        XCTAssertEqual(response.events[1].uid, "e2")
    }

    func testEmptyEventsArrayDecodes() throws {
        let json = #"{"events":[]}"#.data(using: .utf8)!
        let response = try decoder.decode(LLMVisionTimelineResponse.self, from: json)
        XCTAssertTrue(response.events.isEmpty)
    }

    func testEventWithUnknownExtraFieldsDecodes() throws {
        let json = """
        {
            "uid": "extra",
            "title": "Extra Fields",
            "future_field": "ignored",
            "another_new_field": 42
        }
        """.data(using: .utf8)!

        let event = try decoder.decode(LLMVisionEvent.self, from: json)
        XCTAssertEqual(event.uid, "extra")
        XCTAssertEqual(event.title, "Extra Fields")
    }

    // MARK: - Ordering and deduplication

    func testFetchResultIsOrderedNewestFirst() async {
        let session = MockURLSession()
        session.stubbedResponse = HTTPURLResponse(
            url: URL(string: "https://ha.example.com/api/llmvision/timeline/events")!,
            statusCode: 200, httpVersion: nil, headerFields: nil
        )!
        session.stubbedData = """
        {
            "events": [
                { "uid": "old", "start": "2024-01-15T07:00:00Z" },
                { "uid": "new", "start": "2024-01-15T09:00:00Z" },
                { "uid": "mid", "start": "2024-01-15T08:00:00Z" }
            ]
        }
        """.data(using: .utf8)!

        let client = LLMVisionClient(baseURL: URL(string: "https://ha.example.com")!,
                                      accessToken: "token",
                                      urlSession: session)
        let result = await client.fetchTimelineEvents()

        guard case .success(let events) = result else {
            XCTFail("Expected success"); return
        }
        XCTAssertEqual(events.map(\.uid), ["new", "mid", "old"])
    }

    func testDuplicateEventsAreDeduplicatedByUID() async {
        let session = MockURLSession()
        session.stubbedResponse = HTTPURLResponse(
            url: URL(string: "https://ha.example.com/api/llmvision/timeline/events")!,
            statusCode: 200, httpVersion: nil, headerFields: nil
        )!
        session.stubbedData = """
        {
            "events": [
                { "uid": "dup", "start": "2024-01-15T09:00:00Z" },
                { "uid": "dup", "start": "2024-01-15T08:00:00Z" },
                { "uid": "unique", "start": "2024-01-15T07:00:00Z" }
            ]
        }
        """.data(using: .utf8)!

        let client = LLMVisionClient(baseURL: URL(string: "https://ha.example.com")!,
                                      accessToken: "token",
                                      urlSession: session)
        let result = await client.fetchTimelineEvents()

        guard case .success(let events) = result else {
            XCTFail("Expected success"); return
        }
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events.map(\.uid), ["dup", "unique"])
    }

    // MARK: - Request construction

    func testRequestIncludesAuthorizationHeader() async {
        let session = MockURLSession()
        session.stubbedResponse = HTTPURLResponse(
            url: URL(string: "https://ha.example.com")!,
            statusCode: 200, httpVersion: nil, headerFields: nil
        )!
        session.stubbedData = #"{"events":[]}"#.data(using: .utf8)!

        let client = LLMVisionClient(baseURL: URL(string: "https://ha.example.com")!,
                                      accessToken: "my-secret-token",
                                      urlSession: session)
        _ = await client.fetchTimelineEvents()

        let header = session.lastRequest?.value(forHTTPHeaderField: "Authorization")
        XCTAssertEqual(header, "Bearer my-secret-token")
    }

    func testRequestUsesCorrectPath() async {
        let session = MockURLSession()
        session.stubbedResponse = HTTPURLResponse(
            url: URL(string: "https://ha.example.com")!,
            statusCode: 200, httpVersion: nil, headerFields: nil
        )!
        session.stubbedData = #"{"events":[]}"#.data(using: .utf8)!

        let client = LLMVisionClient(baseURL: URL(string: "https://ha.example.com")!,
                                      accessToken: "token",
                                      urlSession: session)
        _ = await client.fetchTimelineEvents()

        let path = session.lastRequest?.url?.path
        XCTAssertEqual(path, "/api/llmvision/timeline/events")
    }

    func testTokenNotInURL() async {
        let session = MockURLSession()
        session.stubbedResponse = HTTPURLResponse(
            url: URL(string: "https://ha.example.com")!,
            statusCode: 200, httpVersion: nil, headerFields: nil
        )!
        session.stubbedData = #"{"events":[]}"#.data(using: .utf8)!

        let client = LLMVisionClient(baseURL: URL(string: "https://ha.example.com")!,
                                      accessToken: "supersecret",
                                      urlSession: session)
        _ = await client.fetchTimelineEvents()

        let urlString = session.lastRequest?.url?.absoluteString ?? ""
        XCTAssertFalse(urlString.contains("supersecret"))
    }

    // MARK: - Authenticated image request

    /// LLM Vision's `key_frame` is a filesystem-style path
    /// ("/media/llmvision/..."), but HA's actual web route for local media
    /// requires a "local" segment ("/media/local/llmvision/...") — hitting
    /// the filesystem-style path 404s. This is the root cause of #81.
    func testImageRequestInsertsLocalSegmentForMediaPath() {
        let client = LLMVisionClient(baseURL: URL(string: "https://ha.example.com")!,
                                      accessToken: "token")
        let req = client.imageRequest(for: "/media/llmvision/snapshots/abc.jpg")
        XCTAssertEqual(req?.url?.absoluteString,
                       "https://ha.example.com/media/local/llmvision/snapshots/abc.jpg")
        XCTAssertEqual(req?.value(forHTTPHeaderField: "Authorization"), "Bearer token")
    }

    func testImageRequestLeavesAlreadyCorrectLocalPathUnchanged() {
        let client = LLMVisionClient(baseURL: URL(string: "https://ha.example.com")!,
                                      accessToken: "token")
        let req = client.imageRequest(for: "/media/local/llmvision/snapshots/abc.jpg")
        XCTAssertEqual(req?.url?.absoluteString,
                       "https://ha.example.com/media/local/llmvision/snapshots/abc.jpg")
    }

    func testImageRequestPreservesAbsoluteURL() {
        let client = LLMVisionClient(baseURL: URL(string: "https://ha.example.com")!,
                                      accessToken: "token")
        let req = client.imageRequest(for: "https://cdn.example.com/snapshots/abc.jpg")
        XCTAssertEqual(req?.url?.absoluteString, "https://cdn.example.com/snapshots/abc.jpg")
    }

    func testImageRequestReturnsNilForInvalidPath() {
        let client = LLMVisionClient(baseURL: URL(string: "https://ha.example.com")!,
                                      accessToken: "token")
        let req = client.imageRequest(for: "")
        XCTAssertNil(req)
    }

    func testResolveMediaPathInsertsLocalSegment() {
        XCTAssertEqual(LLMVisionClient.resolveMediaPath("/media/llmvision/snapshots/abc.jpg"),
                       "/media/local/llmvision/snapshots/abc.jpg")
    }

    func testResolveMediaPathLeavesNonMediaPathsUnchanged() {
        XCTAssertEqual(LLMVisionClient.resolveMediaPath("/api/image_proxy/abc.jpg"),
                       "/api/image_proxy/abc.jpg")
    }

    // MARK: - Error states

    func test404ReturnsIntegrationUnavailable() async {
        let session = MockURLSession()
        session.stubbedResponse = HTTPURLResponse(
            url: URL(string: "https://ha.example.com")!,
            statusCode: 404, httpVersion: nil, headerFields: nil
        )!
        session.stubbedData = Data()

        let client = LLMVisionClient(baseURL: URL(string: "https://ha.example.com")!,
                                      accessToken: "token",
                                      urlSession: session)
        let result = await client.fetchTimelineEvents()

        XCTAssertEqual(result, .failure(.integrationUnavailable))
    }

    func test401ReturnsAuthenticationFailed() async {
        let session = MockURLSession()
        session.stubbedResponse = HTTPURLResponse(
            url: URL(string: "https://ha.example.com")!,
            statusCode: 401, httpVersion: nil, headerFields: nil
        )!
        session.stubbedData = Data()

        let client = LLMVisionClient(baseURL: URL(string: "https://ha.example.com")!,
                                      accessToken: "bad-token",
                                      urlSession: session)
        let result = await client.fetchTimelineEvents()

        XCTAssertEqual(result, .failure(.authenticationFailed))
    }

    func testNetworkErrorReturnsNetworkError() async {
        let session = MockURLSession()
        session.stubbedError = URLError(.notConnectedToInternet)

        let client = LLMVisionClient(baseURL: URL(string: "https://ha.example.com")!,
                                      accessToken: "token",
                                      urlSession: session)
        let result = await client.fetchTimelineEvents()

        guard case .failure(let error) = result, case .networkError = error else {
            XCTFail("Expected networkError"); return
        }
    }

    func testMalformedJSONReturnsDecodingError() async {
        let session = MockURLSession()
        session.stubbedResponse = HTTPURLResponse(
            url: URL(string: "https://ha.example.com")!,
            statusCode: 200, httpVersion: nil, headerFields: nil
        )!
        session.stubbedData = "not json".data(using: .utf8)!

        let client = LLMVisionClient(baseURL: URL(string: "https://ha.example.com")!,
                                      accessToken: "token",
                                      urlSession: session)
        let result = await client.fetchTimelineEvents()

        XCTAssertEqual(result, .failure(.decodingError))
    }

    func testNetworkErrorIsRetryable() {
        XCTAssertTrue(LLMVisionError.networkError("oops").isRetryable)
    }

    func testIntegrationUnavailableIsNotRetryable() {
        XCTAssertFalse(LLMVisionError.integrationUnavailable.isRetryable)
    }
}

// MARK: - MockURLSession

final class MockURLSession: URLSessionProtocol {
    var stubbedData: Data = Data()
    var stubbedResponse: URLResponse = URLResponse()
    var stubbedError: Error?
    private(set) var lastRequest: URLRequest?

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        lastRequest = request
        if let error = stubbedError { throw error }
        return (stubbedData, stubbedResponse)
    }
}
