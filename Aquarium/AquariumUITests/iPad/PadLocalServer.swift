//  A tiny HTTP server inside the test runner, on 127.0.0.1 and a port of its
//  own, for what the QA Jellyfin server does not serve: an M3U playlist, an
//  XMLTV guide and a channel logo for the custom Live TV source
//  (PadSettingsMoreTests). The simulator shares the Mac's loopback, so the
//  app under test reaches it. It answers GET by path, 404 otherwise, and
//  keeps the paths it was asked for.

#if os(iOS)
import Foundation
import Network
import XCTest

final class PadLocalServer {
    struct Page {
        let type: String
        let body: Data
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "aquarium.uitests.pad-local-server")
    private var pages: [String: Page] = [:]
    private var asked: [String] = []
    private(set) var port: UInt16 = 0

    var address: String { "http://127.0.0.1:\(port)" }

    /// The paths asked for so far, in order.
    var requests: [String] { queue.sync { asked } }

    init() throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed, .cancelled: ready.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
        guard let port = listener.port?.rawValue, port != 0 else {
            listener.cancel()
            throw XCTSkip("could not open a local port for the test's own HTTP server")
        }
        self.port = port
    }

    func set(_ path: String, type: String, body: Data) {
        queue.sync { pages[path] = Page(type: type, body: body) }
    }

    func set(_ path: String, type: String, text: String) {
        set(path, type: type, body: Data(text.utf8))
    }

    func stop() { listener.cancel() }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, _, _ in
            guard let self, let data, let head = String(data: data, encoding: .utf8) else { return connection.cancel() }
            // "GET /playlist.m3u HTTP/1.1"
            let parts = head.split(separator: "\r\n").first?.split(separator: " ") ?? []
            let raw = parts.count > 1 ? String(parts[1]) : "/"
            let path = raw.split(separator: "?").first.map(String.init) ?? raw
            self.asked.append(path)
            let page = self.pages[path]
            let isHead = parts.first == "HEAD"
            var answer = "HTTP/1.1 \(page == nil ? "404 Not Found" : "200 OK")\r\n"
            answer += "Content-Type: \(page?.type ?? "text/plain")\r\n"
            answer += "Content-Length: \(page?.body.count ?? 0)\r\n"
            answer += "Connection: close\r\n\r\n"
            var out = Data(answer.utf8)
            if let page, !isHead { out.append(page.body) }
            connection.send(content: out, completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}
#endif
