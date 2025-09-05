import Foundation

public struct ChatConfig {
    public var baseURL: URL
    public var path: PathStrategy
    public var namespace: NamespaceStrategy
    public var query: [String:String]
    public var headers: [String:String]
    public var auth: [String:Any]?
    public var preferTransports: [TransportKind]     // orden preferido para conexión inicial
    public var engineIO: EngineIO
    public var connectTimeout: TimeInterval
    public var reconnectionAttempts: Int
    public var reconnectionDelay: TimeInterval       // base
    public var reconnectionDelayMax: TimeInterval    // tope
    public var logLevel: LogLevel

    public init(
        baseURL: URL,
        path: PathStrategy = .auto(["/socket.io", "/QA/chat/socket"]),
        namespace: NamespaceStrategy = .auto(preferred: "/", fallbacks: ["/messages", "/"]),
        query: [String:String] = [:],
        headers: [String:String] = [:],
        auth: [String:Any]? = nil,
        preferTransports: [TransportKind] = [.websocket, .polling],
        engineIO: EngineIO = .v4,
        connectTimeout: TimeInterval = 12,
        reconnectionAttempts: Int = .max,
        reconnectionDelay: TimeInterval = 1.0,
        reconnectionDelayMax: TimeInterval = 5.0,
        logLevel: LogLevel = .info
    ) {
        self.baseURL = baseURL
        self.path = path
        self.namespace = namespace
        self.query = query
        self.headers = headers
        self.auth = auth
        self.preferTransports = preferTransports
        self.engineIO = engineIO
        self.connectTimeout = connectTimeout
        self.reconnectionAttempts = reconnectionAttempts
        self.reconnectionDelay = reconnectionDelay
        self.reconnectionDelayMax = reconnectionDelayMax
        self.logLevel = logLevel
    }
}
