import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct HTTPRequest: Sendable, Equatable {
    public var url: URL
    public var method: String
    public var headers: [String: String]
    public var body: Data?
    public var timeout: Double
    public init(url: URL, method: String = "POST", headers: [String: String] = [:], body: Data? = nil, timeout: Double = 120) {
        self.url = url; self.method = method; self.headers = headers; self.body = body; self.timeout = timeout
    }
}

public struct HTTPStreamHead: Sendable, Equatable {
    public var status: Int
    public var headers: [String: String]
    public init(status: Int, headers: [String: String]) { self.status = status; self.headers = headers }
}

/// OS boundary for HTTP so model clients can be tested with scripted responses.
public protocol HTTPTransport: Sendable {
    /// Returns the status/headers and an async sequence of response body lines.
    func streamLines(_ request: HTTPRequest) async throws -> (HTTPStreamHead, AsyncThrowingStream<String, Error>)
}

public struct URLSessionTransport: HTTPTransport {
    public init() {}

    public func streamLines(_ request: HTTPRequest) async throws -> (HTTPStreamHead, AsyncThrowingStream<String, Error>) {
        var req = URLRequest(url: request.url)
        req.httpMethod = request.method
        req.timeoutInterval = request.timeout
        for (k, v) in request.headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = request.body
        #if canImport(FoundationNetworking)
        // swift-corelibs-foundation has no async byte streaming; fetch whole body.
        let (data, resp): (Data, URLResponse?) = try await withCheckedThrowingContinuation { cont in
            URLSession.shared.dataTask(with: req) { d, r, e in
                if let e { cont.resume(throwing: ModelError.network(e.localizedDescription)) }
                else { cont.resume(returning: (d ?? Data(), r)) }
            }.resume()
        }
        let http = resp as? HTTPURLResponse
        let head = HTTPStreamHead(status: http?.statusCode ?? 0, headers: Self.headers(http))
        let text = String(decoding: data, as: UTF8.self)
        let stream = AsyncThrowingStream<String, Error> { c in
            for l in text.split(separator: "\n", omittingEmptySubsequences: false) { c.yield(String(l)) }
            c.finish()
        }
        return (head, stream)
        #else
        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        let http = resp as? HTTPURLResponse
        let head = HTTPStreamHead(status: http?.statusCode ?? 0, headers: Self.headers(http))
        let stream = AsyncThrowingStream<String, Error> { c in
            let t = Task {
                do {
                    for try await line in bytes.lines { c.yield(line) }
                    c.finish()
                } catch { c.finish(throwing: error is CancellationError ? ModelError.cancelled : ModelError.network(error.localizedDescription)) }
            }
            c.onTermination = { _ in t.cancel() }
        }
        return (head, stream)
        #endif
    }

    static func headers(_ r: HTTPURLResponse?) -> [String: String] {
        var out: [String: String] = [:]
        for (k, v) in r?.allHeaderFields ?? [:] { out[String(describing: k).lowercased()] = String(describing: v) }
        return out
    }
}

/// Server-Sent Events parser (line-based).
public struct SSEParser: Sendable {
    public struct Event: Sendable, Equatable {
        public var event: String?
        public var data: String
    }
    private var eventName: String?
    private var dataLines: [String] = []
    public init() {}

    /// Feed one line; returns an event when a blank line terminates one. Because some line
    /// readers drop blank lines, a `data:` line that is complete JSON is also emitted
    /// immediately by `feedTolerant`.
    public mutating func feed(_ rawLine: String) -> Event? {
        let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
        if line.isEmpty {
            defer { eventName = nil; dataLines = [] }
            guard !dataLines.isEmpty else { return nil }
            return Event(event: eventName, data: dataLines.joined(separator: "\n"))
        }
        if line.hasPrefix(":") { return nil }
        let (field, value) = Self.split(line)
        switch field {
        case "event": eventName = value
        case "data": dataLines.append(value)
        default: break
        }
        return nil
    }

    /// Like `feed`, but emits immediately for single-line data events (robust when the
    /// transport strips empty lines, as `URLSession.AsyncBytes.lines` does).
    public mutating func feedTolerant(_ rawLine: String) -> Event? {
        let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
        if line.isEmpty { return feed(line) }
        let (field, value) = Self.split(line)
        if field == "data" {
            let ev = Event(event: eventName, data: value)
            eventName = nil; dataLines = []
            return ev
        }
        return feed(line)
    }

    static func split(_ line: String) -> (String, String) {
        guard let idx = line.firstIndex(of: ":") else { return (line, "") }
        let field = String(line[..<idx])
        var value = String(line[line.index(after: idx)...])
        if value.hasPrefix(" ") { value.removeFirst() }
        return (field, value)
    }
}
