//  Canned answers for the network, in unit tests.
//
//  Compiled into AquariumTests and (by a project exception) AquariumWatchTests.
//  Foundation only, so it builds for every platform.
//
//      StubURLProtocol.reset()
//      StubURLProtocol.stub("/System/Info/Public", json: #"{"Id":"abc","ServerName":"QA"}"#)
//      StubURLProtocol.stub("/Users/Me", status: 401)
//      ... make the client's requests ...
//      XCTAssertEqual(StubURLProtocol.requests.map(\.url?.path), [...])
//
//  A request is matched by its path alone, or by "<METHOD> <path>" when a stub
//  was given a method. Unmatched requests answer 404 with an empty body (and are
//  still recorded), so a test sees what it forgot to stub instead of hanging.
//  The client has to be told to use this class: `JellyfinClient.testProtocolClasses`
//  then `resetConnections()` (iPhone/iPad/Mac/TV, see `ClientStub`), or
//  `JellyfinClient.shared.useTestProtocols([StubURLProtocol.self])` (Watch).

import Foundation

final class StubURLProtocol: URLProtocol {
    struct Response {
        var status: Int = 200
        var headers: [String: String] = ["Content-Type": "application/json"]
        var body: Data = Data()
        /// A transport failure instead of an answer.
        var error: URLError.Code?
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var responses: [String: Response] = [:]
    nonisolated(unsafe) private static var recorded: [URLRequest] = []

    /// Every request seen since the last `reset`, in order, with its body
    /// (URLSession moves a body into a stream; it is read back here).
    static var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return recorded }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        responses = [:]
        recorded = []
    }

    static func stub(_ path: String, method: String? = nil, _ response: Response) {
        lock.lock(); defer { lock.unlock() }
        responses[method.map { "\($0) \(path)" } ?? path] = response
    }

    static func stub(_ path: String, method: String? = nil, status: Int = 200, json: String = "") {
        stub(path, method: method, Response(status: status, body: Data(json.utf8)))
    }

    /// A JSON file from the test bundle's resources, by name without `.json`.
    static func stub(_ path: String, method: String? = nil, status: Int = 200, fixture name: String, in bundle: Bundle) {
        let data = bundle.url(forResource: name, withExtension: "json").flatMap { try? Data(contentsOf: $0) } ?? Data()
        stub(path, method: method, Response(status: status, body: data))
    }

    /// The JSON body a recorded request sent, decoded loosely.
    static func jsonBody(of request: URLRequest) -> [String: Any]? {
        guard let data = request.httpBody else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var seen = request
        if seen.httpBody == nil, let stream = seen.httpBodyStream {
            seen.httpBody = Self.read(stream)
        }
        let path = request.url?.path ?? ""
        let method = request.httpMethod ?? "GET"
        Self.lock.lock()
        Self.recorded.append(seen)
        let answer = Self.responses["\(method) \(path)"] ?? Self.responses[path]
        Self.lock.unlock()

        guard let answer else {
            finish(Response(status: 404))
            return
        }
        if let code = answer.error {
            client?.urlProtocol(self, didFailWithError: URLError(code))
            return
        }
        finish(answer)
    }

    private func finish(_ answer: Response) {
        let response = HTTPURLResponse(url: request.url!, statusCode: answer.status, httpVersion: "HTTP/1.1", headerFields: answer.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: answer.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream) -> Data {
        stream.open(); defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }
}
