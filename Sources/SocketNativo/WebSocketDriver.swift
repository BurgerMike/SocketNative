import Foundation

final class WebSocketDriver: NSObject, TransportDriver, URLSessionDelegate {
    weak var delegate: TransportDriverDelegate?

    private var session: URLSession!
    private var task: URLSessionWebSocketTask?
    private var closed = false
    private let logger: Logger
    private var security: SecurityEvaluating?

    init(logger: Logger) {
        self.logger = logger
        super.init()
    }

    func connect(url: URL, headers: [String:String], security: SecurityEvaluating?) {
        self.security = security
        let config = URLSessionConfiguration.default
        config.httpAdditionalHeaders = headers
        // Importante para mantener viva la conexión
        config.waitsForConnectivity = false

        session = URLSession(configuration: config, delegate: self, delegateQueue: OperationQueue())
        task = session.webSocketTask(with: url)
        closed = false
        task?.resume()
        receiveLoop()
        // No llamamos delegateDidOpen aquí; Engine.IO enviará "0{...}" y eso triggereará el flujo.
        // Pero sí es útil avisar cuando el WS está listo (como hace el probe):
        delegate?.transportDidOpen(self)
    }

    func sendText(_ text: String) {
        guard let task else { return }
        task.send(.string(text)) { [weak self] error in
            if let error { self?.delegate?.transport(self!, didFail: error) }
        }
    }

    func sendBinary(_ data: Data) {
        guard let task else { return }
        task.send(.data(data)) { [weak self] error in
            if let error { self?.delegate?.transport(self!, didFail: error) }
        }
    }

    func close() {
        closed = true
        task?.cancel(with: .normalClosure, reason: nil)
        session?.invalidateAndCancel()
        delegate?.transportDidClose(self, code: nil, reason: nil)
    }

    // MARK: - Receive

    private func receiveLoop() {
        guard let task, !closed else { return }
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.delegate?.transport(self, didFail: error)

            case .success(let message):
                switch message {
                case .string(let text):
                    self.delegate?.transport(self, didReceiveText: text)
                case .data(let data):
                    self.delegate?.transport(self, didReceiveData: data)
                @unknown default:
                    break
                }
                // Seguir recibiendo
                self.receiveLoop()
            }
        }
    }

    // MARK: - TLS pinning / trust

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

extension WebSocketDriver: @unchecked Sendable {}
