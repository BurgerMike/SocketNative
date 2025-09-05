import Foundation

protocol Transport: AnyObject {
    var kind: TransportKind { get }
    var onText: ((String)->Void)? { get set }
    var onBinary: ((Data)->Void)? { get set }
    var onClose: ((Error?)->Void)? { get set }
    func open(url: URL, headers: [String:String], timeout: TimeInterval) async throws -> String
    func send(_ text: String)
    func sendBinary(_ data: Data)
    func close()
}

// MARK: WebSocketTransport
final class WebSocketTransport: NSObject, Transport, URLSessionWebSocketDelegate {
    let kind: TransportKind = .websocket
    var onText: ((String)->Void)?
    var onBinary: ((Data)->Void)?
    var onClose: ((Error?)->Void)?
    private var session: URLSession!
    private var task: URLSessionWebSocketTask!

    func open(url: URL, headers: [String:String], timeout: TimeInterval) async throws -> String {
        let conf = URLSessionConfiguration.default
        session = URLSession(configuration: conf, delegate: self, delegateQueue: nil)
        var req = URLRequest(url: url)
        headers.forEach { req.setValue($0.value, forHTTPHeaderField: $0.key) }
        task = session.webSocketTask(with: req)
        task.resume()
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { try await self.receiveTextOnce() }
            group.addTask { try await Self.timeout(after: timeout) }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
    }

    func send(_ text: String) { task?.send(.string(text)) { _ in } }
    func sendBinary(_ data: Data) { task?.send(.data(data)) { _ in } }
    func close() { task?.cancel(with: .goingAway, reason: nil); session?.invalidateAndCancel() }

    private func receiveTextOnce() async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            task.receive { result in
                switch result {
                case .failure(let e): cont.resume(throwing: e)
                case .success(let msg):
                    switch msg {
                    case .string(let s): cont.resume(returning: s)
                    case .data(let d): cont.resume(returning: String(decoding: d, as: UTF8.self))
                    @unknown default: cont.resume(returning: "")
                    }
                }
            }
        }
    }
    private static func timeout(after s: TimeInterval) async throws -> String { try await Task.sleep(nanoseconds: UInt64(s*1e9)); throw SocketNativeError.openTimeout }

    private func receiveLoop() {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let err): self.onClose?(err)
            case .success(let msg):
                switch msg {
                case .string(let s): self.onText?(s)
                case .data(let d): self.onBinary?(d)
                @unknown default: break
                }
                self.receiveLoop()
            }
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didOpenWithProtocol protocol: String?) { receiveLoop() }
}

// MARK: PollingTransport
final class PollingTransport: Transport {
    let kind: TransportKind = .polling
    var onText: ((String)->Void)?
    var onBinary: ((Data)->Void)?
    var onClose: ((Error?)->Void)?

    private var baseURL: URL!
    private var headers: [String:String] = [:]
    private var sid: String?
    private var timer: Task<Void, Never>?
    private var closed = false

    func open(url: URL, headers: [String:String], timeout: TimeInterval) async throws -> String {
        self.baseURL = url
        self.headers = headers
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        headers.forEach { req.setValue($0.value, forHTTPHeaderField: $0.key) }
        let (data, _) = try await URLSession.shared.data(for: req)
        let body = String(decoding: data, as: UTF8.self)
        var first = body
        if body.first?.isNumber == true && body.contains(":") {
            if let p = parsePollingPayload(body).first { first = p.type + p.data }
        }
        if first.hasPrefix("0"), let s = try? Self.extractSID(from: String(first.dropFirst())) { self.sid = s }
        startLoop()
        return first
    }

    func send(_ text: String) {
        guard let sid else { return }
        Task {
            var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
            comps.queryItems = (comps.queryItems ?? []) + [URLQueryItem(name: "sid", value: sid)]
            var req = URLRequest(url: comps.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
            headers.forEach { req.setValue($0.value, forHTTPHeaderField: $0.key) }
            req.httpMethod = "POST"
            req.httpBody = makePollingBody([text])
            _ = try? await URLSession.shared.data(for: req)
        }
    }

    func sendBinary(_ data: Data) {
        let b64 = data.base64EncodedString()
        send("b" + b64)
    }

    func close() { closed = true; timer?.cancel(); timer = nil }

    private func startLoop() {
        guard !closed else { return }
        timer = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled && !self.closed {
                do {
                    try await Task.sleep(nanoseconds: 250_000_000)
                    guard let sid = self.sid else { continue }
                    var comps = URLComponents(url: self.baseURL, resolvingAgainstBaseURL: false)!
                    comps.queryItems = (comps.queryItems ?? []) + [URLQueryItem(name: "sid", value: sid)]
                    var req = URLRequest(url: comps.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
                    self.headers.forEach { req.setValue($0.value, forHTTPHeaderField: $0.key) }
                    req.httpMethod = "GET"
                    let (data, _) = try await URLSession.shared.data(for: req)
                    let body = String(decoding: data, as: UTF8.self)
                    let packets = parsePollingPayload(body)
                    for p in packets {
                        if p.type == "b", let d = Data(base64Encoded: p.data) { self.onBinary?(d) }
                        else { self.onText?(p.type + p.data) }
                    }
                } catch { self.onClose?(error); break }
            }
        }
    }

    private static func extractSID(from json: String) throws -> String { struct Open: Decodable { let sid: String }; return try JSONDecoder().decode(Open.self, from: Data(json.utf8)).sid }
}
