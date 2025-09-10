import Foundation

public typealias ClienteChat = ChatClient
public typealias ConfiguracionChat = ChatConfig
public typealias PoliticaReconex = ReconnectPolicy
public typealias PoliticaAck = AckPolicy
public typealias PoliticaColaOffline = OfflineQueuePolicy

public typealias NivelLog = LogLevel
public typealias Transporte = Transport
public typealias VersionMotor = EngineVersion

public extension ChatConfig {
    init(
        urlBase baseURL: URL,
        ruta path: String,
        espacio namespace: String = "/",
        consulta query: [String:String] = [:],
        cabeceras headers: [String:String] = [:],
        preferirTransportes preferTransports: [Transport] = [.websocket, .polling],
        motor engineIO: EngineVersion = .v4,
        reconexion reconnect: ReconnectPolicy = .init(),
        acuse ack: AckPolicy = .init(),
        colaOffline offlineQueue: OfflineQueuePolicy = .init(),
        nivelLog logLevel: LogLevel = .info,
        seguridad security: SecurityEvaluating? = nil,
        autenticacion authProvider: AuthProviding? = nil,
        connectPayload: (() async -> [String:Any]?)? = nil,
        middlewares: [EventMiddleware] = [],
        almacen store: KeyValueStoring? = nil,
        logger: Logging? = nil
    ) {
        self.init(baseURL: baseURL, path: path, namespace: namespace, query: query, headers: headers,
                  preferTransports: preferTransports, engineIO: engineIO, reconnect: reconnect, ack: ack,
                  offlineQueue: offlineQueue, logLevel: logLevel, security: security, authProvider: authProvider,
                  middlewares: middlewares, store: store, logger: logger, connectPayloadProvider: connectPayload)
    }
}

public extension ChatClient {
    func espacio(_ nombre: String) -> Namespace { of(nombre) }
    func unionPersistente(evento: String, payload: Any?) { stickyJoin(event: evento, payload: payload) }
    func emitir(_ evento: String, _ payload: Any?) { emit(evento, payload) }
    func emitir(_ evento: String, _ payload: Any?, en namespace: String, acuse ack: ((Any?) -> Void)? = nil) {
        emit(evento, payload, in: namespace, ack: ack)
    }
    func emitir<T: Encodable>(_ evento: String, json: T, acuse ack: ((Any?) -> Void)? = nil) { emit(evento, json: json, ack: ack) }
}

public extension Namespace {
    func en(_ evento: String, _ cb: @escaping Listener) { on(evento, cb) }
    func quitar(_ evento: String) { off(evento) }
    func emitir(_ evento: String, _ payload: Any?, acuse: ((Any?) -> Void)? = nil) { emit(evento, payload, ack: acuse) }
}
