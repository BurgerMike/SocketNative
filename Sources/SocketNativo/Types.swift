import Foundation

public enum TransportKind: String { case websocket, polling }
public enum EngineIO: Int { case v4 = 4 }
public enum LogLevel: Int { case off = 0, error = 1, info = 2, debug = 3 }

public enum NamespaceStrategy: Equatable { case fixed(String); case auto(preferred: String, fallbacks: [String]) }
public enum PathStrategy: Equatable { case fixed(String); case auto([String]) }

public enum SocketEvent: Equatable {
    case connect(String)                 // namespace
    case disconnect(String)
    case connectError(String, String)    // ns, error
    case error(String)
    case ping, pong
    case custom(String, Any?)            // name, payload
    case ack(Int, Any?)                  // id, payload

    public static func == (lhs: SocketEvent, rhs: SocketEvent) -> Bool {
        switch (lhs, rhs) {
        case let (.connect(a), .connect(b)):
            return a == b
        case let (.disconnect(a), .disconnect(b)):
            return a == b
        case let (.connectError(ns1, err1), .connectError(ns2, err2)):
            return ns1 == ns2 && err1 == err2
        case let (.error(a), .error(b)):
            return a == b
        case (.ping, .ping):
            return true
        case (.pong, .pong):
            return true
        case let (.custom(name1, payload1), .custom(name2, payload2)):
            // We cannot equate Any values; compare name and whether payloads are nil.
            return name1 == name2 && (payload1 == nil) == (payload2 == nil)
        case let (.ack(id1, payload1), .ack(id2, payload2)):
            // Compare id and whether payloads are nil.
            return id1 == id2 && (payload1 == nil) == (payload2 == nil)
        default:
            return false
        }
    }
}

public enum SocketNativeError: Error, LocalizedError {
    case invalidURL
    case openTimeout
    case sioConnectTimeout
    case transportClosed
    case allCombosFailed(last: Error?)
    case notConnected

    public var errorDescription: String? {
        switch self {
        case .invalidURL: return "URL inválida"
        case .openTimeout: return "Timeout esperando Engine.IO OPEN"
        case .sioConnectTimeout: return "Timeout esperando Socket.IO CONNECT"
        case .transportClosed: return "El transporte se cerró"
        case .allCombosFailed(let last): return "No se pudo conectar con ningún transporte. Último error: \(String(describing: last))"
        case .notConnected: return "No hay conexión activa"
        }
    }
}
