import Foundation

final class PollingDriver: NSObject, TransportDriver, URLSessionDelegate {
    weak var delegate: TransportDriverDelegate?
    private var session: URLSession!
    private var baseURL: URL!
    private var headers: [String:String] = [:]
    private var security: SecurityEvaluating?
    private var sid: String?
    private var closed = false
    private let logger: Logger

    init(logger: Logger) { self.logger = logger; super.init() }

    func connect(url: URL, headers: [String:String], security: SecurityEvaluating?) {
        self.baseURL = url; self.headers = headers; self.security = security
        let conf = URLSessionConfiguration.default; conf.httpAdditionalHeaders = headers
        session = URLSession(configuration: conf, delegate: self, delegateQueue: OperationQueue())
        closed = false; poll()
    }

    func sendText(_ text: String) { post(payload: encodePackets([text])) }
    func sendBinary(_ data: Data) {
        let packet = "b" + data.base64EncodedString()
        post(payload: encodePackets([packet]))
    }

    func close() { closed = true; session.invalidateAndCancel(); delegate?.transportDidClose(self, code: nil, reason: nil) }

    private func poll() {
        guard !closed else { return }
        var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!; var q = comps.queryItems ?? []
        func setQ(_ n:String,_ v:String){ if let i=q.firstIndex(where:{$0.name==n}){q[i]=URLQueryItem(name:n,value:v)} else {q.append(URLQueryItem(name:n,value:v))} }
        setQ("transport","polling"); if let sid { setQ("sid",sid) }; comps.queryItems = q
        let url = comps.url!; var req = URLRequest(url: url); req.httpMethod="GET"
        session.dataTask(with: req) { [weak self] data,_,err in
            guard let self else { return }
            if let err = err { self.delegate?.transport(self, didFail: err); return }
            guard let data = data, let text = String(data: data, encoding: .utf8) else { self.poll(); return }
            self.processPayload(text); self.poll()
        }.resume()
    }

    private func post(payload: String) {
        guard !closed else { return }
        var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!; var q = comps.queryItems ?? []
        func setQ(_ n:String,_ v:String){ if let i=q.firstIndex(where:{$0.name==n}){q[i]=URLQueryItem(name:n,value:v)} else {q.append(URLQueryItem(name:n,value:v))} }
        setQ("transport","polling"); if let sid { setQ("sid",sid) }; comps.queryItems = q
        let url = comps.url!; var req = URLRequest(url: url); req.httpMethod="POST"
        req.setValue("text/plain;charset=UTF-8", forHTTPHeaderField: "Content-Type"); req.httpBody = payload.data(using: .utf8)
        session.dataTask(with: req) { [weak self] _,_,err in if let err = err { self?.delegate?.transport(self!, didFail: err) } }.resume()
    }

    private func deframe(_ payload: String, handler: (String) -> Void) {
        var i = payload.startIndex
        while i < payload.endIndex {
            var lenStr = ""
            while i < payload.endIndex, payload[i].isNumber { lenStr.append(payload[i]); i = payload.index(after: i) }
            guard i < payload.endIndex, payload[i] == ":" else { break }
            i = payload.index(after: i)
            let len = Int(lenStr) ?? 0; guard len > 0 else { continue }
            let start = i; let end = payload.index(i, offsetBy: len, limitedBy: payload.endIndex) ?? payload.endIndex
            handler(String(payload[start..<end])); i = end
        }
    }

    private func processPayload(_ payload: String) {
        deframe(payload) { packet in
            if packet.hasPrefix("b") {
                if let d = Data(base64Encoded: String(packet.dropFirst())) {
                    delegate?.transport(self, didReceiveData: d)
                }
            } else {
                if packet.first == "0", sid == nil, let data = String(packet.dropFirst()).data(using: .utf8),
                   let open = try? JSONDecoder().decode(OpenPayload.self, from: data) { sid = open.sid }
                delegate?.transport(self, didReceiveText: packet)
            }
        }
        if sid != nil { delegate?.transportDidOpen(self) }
    }

    private func encodePackets(_ packets: [String]) -> String {
        var s = ""; for p in packets { s += String(p.utf8.count) + ":" + p }; return s
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if let security {
            let r = security.evaluate(challenge: challenge, for: challenge.protectionSpace.host)
            completionHandler(r.disposition, r.credential)
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

extension PollingDriver: @unchecked Sendable {}
