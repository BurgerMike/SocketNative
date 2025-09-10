import Foundation

public protocol TransportDriver: AnyObject {
    var delegate: TransportDriverDelegate? { get set }
    func connect(url: URL, headers: [String:String], security: SecurityEvaluating?)
    func sendText(_ text: String)
    func sendBinary(_ data: Data)
    func close()
}

public protocol TransportDriverDelegate: AnyObject {
    func transportDidOpen(_ transport: TransportDriver)
    func transport(_ transport: TransportDriver, didFail error: Error)
    func transportDidClose(_ transport: TransportDriver, code: Int?, reason: Data?)
    func transport(_ transport: TransportDriver, didReceiveText text: String)
    func transport(_ transport: TransportDriver, didReceiveData data: Data)
}

public protocol SecurityEvaluating: AnyObject {
    func evaluate(challenge: URLAuthenticationChallenge, for host: String)
      -> (disposition: URLSession.AuthChallengeDisposition, credential: URLCredential?)
}

public protocol AuthProviding: AnyObject {
    func headersForConnection() async -> [String:String]
    func queryForConnection() async -> [String:String]
    func didReceiveAuthError(code: Int?, message: String?) async -> Bool
}

public protocol EventMiddleware {
    func willEmit(event: String, payload: Any?) -> (String, Any?)?
    func didReceive(event: String, payload: Any?) -> (String, Any?)?
}

public protocol KeyValueStoring {
    func set(_ value: Data, forKey key: String)
    func get(_ key: String) -> Data?
    func remove(_ key: String)
}

public protocol Logging {
    func log(_ level: LogLevel, _ message: @autoclosure () -> String)
}
