import Foundation

final class WebSocketDriver: NSObject, TransportDriver, URLSessionWebSocketDelegate, URLSessionDelegate {
    weak var delegate: TransportDriverDelegate?
    private var task: URLSessionWebSocketTask?
    private var session: URLSession!
    private var security: SecurityEvaluating?
    private let logger: Logger
    private var headers: [String:String] = [:]

    init(logger: Logger) {
        self.logger = logger
        super.init()
    }

    func connect(url: URL, headers: [String:String], security: SecurityEvaluating?) {
        self.headers = headers
        self.security = security
        let conf = URLSessionConfiguration.default
        conf.httpAdditionalHeaders = headers
        session = URLSession(configuration: conf, delegate: self, delegateQueue: OperationQueue())
        var req = URLRequest(url: url)
        headers.forEach { req.setValue($0.value, forHTTPHeaderField: $0.key) }
        task = session.webSocketTask(with: req)
        task?.resume()
        receiveLoop()
    }

    func sendText(_ text: String) {
        task?.send(.string(text)) { [weak self] err in
            if let err = err { self?.logger.error("send error: \(err)") }
        }
    }
    func sendBinary(_ data: Data) {
        task?.send(.data(data)) { [weak self] err in
            if let err = err { self?.logger.error("send data error: \(err)") }
        }
    }

    func close() {
        task?.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
    }

    private func receiveLoop() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let err):
                self.delegate?.transport(self, didFail: err)
            case .success(let msg):
                switch msg {
                case .string(let s): self.delegate?.transport(self, didReceiveText: s)
                case .data(let d):   self.delegate?.transport(self, didReceiveData: d)
                @unknown default: break
                }
                self.receiveLoop()
            }
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        delegate?.transportDidOpen(self)
    }
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        delegate?.transportDidClose(self, code: Int(closeCode.rawValue), reason: reason)
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if let security {
            let res = security.evaluate(challenge: challenge, for: challenge.protectionSpace.host)
            completionHandler(res.disposition, res.credential)
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

// MARK: - Concurrency
extension WebSocketDriver: @unchecked Sendable {}
