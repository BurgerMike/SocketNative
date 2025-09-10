import Foundation

public enum EngineVersion { case v4 }
public enum Transport: String { case websocket, polling }

public struct ReconnectPolicy {
    public var enabled: Bool = true
    public var maxAttempts: Int = 10
    public var initial: TimeInterval = 0.5
    public var max: TimeInterval = 20.0
    public var factor: Double = 2.0
    public var jitter: Double = 0.25
    public init(enabled: Bool = true, maxAttempts: Int = 10, initial: TimeInterval = 0.5, max: TimeInterval = 20.0, factor: Double = 2.0, jitter: Double = 0.25) {
        self.enabled = enabled; self.maxAttempts = maxAttempts; self.initial = initial; self.max = max; self.factor = factor; self.jitter = jitter
    }
}

public struct AckPolicy { public var timeout: TimeInterval = 8.0; public init(timeout: TimeInterval = 8.0) {} }
public struct OfflineQueuePolicy { public var enabled: Bool = true; public var maxItems: Int = 200; public init(enabled: Bool = true, maxItems: Int = 200) { self.enabled = enabled; self.maxItems = maxItems } }
public enum LogLevel: Int { case off = 0, error = 1, info = 2, debug = 3 }

public struct ChatConfig {
    public var baseURL: URL
    public var path: String
    public var namespace: String
    public var query: [String:String]
    public var headers: [String:String]
    public var preferTransports: [Transport]
    public var engineIO: EngineVersion
    public var reconnect: ReconnectPolicy
    public var ack: AckPolicy
    public var offlineQueue: OfflineQueuePolicy
    public var logLevel: LogLevel

    public var security: SecurityEvaluating?
    public var authProvider: AuthProviding?
    public var middlewares: [EventMiddleware]
    public var store: KeyValueStoring?
    public var logger: Logging?

    /// Nuevo: payload opcional que se envía en el CONNECT de Socket.IO (40<nsp>,{...})
    public var connectPayloadProvider: (() async -> [String:Any]?)?

    public init(baseURL: URL,
                path: String,
                namespace: String = "/",
                query: [String:String] = [:],
                headers: [String:String] = [:],
                preferTransports: [Transport] = [.websocket, .polling],
                engineIO: EngineVersion = .v4,
                reconnect: ReconnectPolicy = .init(),
                ack: AckPolicy = .init(),
                offlineQueue: OfflineQueuePolicy = .init(),
                logLevel: LogLevel = .info,
                security: SecurityEvaluating? = nil,
                authProvider: AuthProviding? = nil,
                middlewares: [EventMiddleware] = [],
                store: KeyValueStoring? = nil,
                logger: Logging? = nil,
                connectPayloadProvider: (() async -> [String:Any]?)? = nil) {
        self.baseURL = baseURL; self.path = path; self.namespace = namespace
        self.query = query; self.headers = headers; self.preferTransports = preferTransports
        self.engineIO = engineIO; self.reconnect = reconnect; self.ack = ack
        self.offlineQueue = offlineQueue; self.logLevel = logLevel
        self.security = security; self.authProvider = authProvider
        self.middlewares = middlewares; self.store = store; self.logger = logger
        self.connectPayloadProvider = connectPayloadProvider
    }
}

struct AckPending { let id: Int; let deadline: Date; let cb: (Any?) -> Void }

enum EIOType: Character { case open="0", close="1", ping="2", pong="3", message="4", upgrade="5", noop="6" }
enum SIOType: Character { case connect="0", disconnect="1", event="2", ack="3", error="4", binaryEvent="5", binaryAck="6" }

public enum ChatError: Error { case badURL, transportNotAvailable, notConnected, timedOut, server(String) }
