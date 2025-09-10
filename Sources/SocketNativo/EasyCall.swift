//
//  EasyCall.swift
//  SocketNativo
//
//  Created by Miguel Carlos Elizondo Martinez on 09/09/25.
//

import Foundation

/// Fachada muy simple para conectar y trabajar con un namespace.
/// Entra y sale por `ChatClient`, pero sin exponer su complejidad.
public final class EasyChat {
    public let client: ChatClient
    public let namespace: String

    private let config: ChatConfig
    private lazy var room = client.of(namespace)

    /// Crea una instancia lista para conectar.
    public init(
        baseURL: URL,
        path: String = "/socket.io",
        namespace: String = "/",
        headers: [String:String] = [:],
        query: [String:String] = [:],
        logLevel: LogLevel = .info,
        security: SecurityEvaluating? = nil
    ) {
        self.client = ChatClient()
        self.namespace = namespace
        self.config = ChatConfig(
            baseURL: baseURL,
            path: path,
            namespace: namespace,
            query: query,
            headers: headers,
            preferTransports: [.websocket, .polling],
            engineIO: .v4,
            reconnect: .init(),
            ack: .init(),
            offlineQueue: .init(),
            logLevel: logLevel,
            security: security,
            authProvider: nil,
            middlewares: [],
            store: nil,
            logger: nil
        )
    }

    /// Abre la conexión.
    @discardableResult
    public func connect() async throws -> ChatClient {
        try await client.connect(config)
        return client
    }

    /// Cierra la conexión.
    public func disconnect() {
        client.disconnect()
    }

    // MARK: - Listeners

    /// onAny global
    public func onAny(_ cb: @escaping (String, Any?) -> Void) {
        client.onAny = cb
    }

    /// on por evento (namespace actual)
    public func on(_ event: String, _ cb: @escaping (Any?) -> Void) {
        room.on(event) { payload, _ in cb(payload) }
    }

    /// on por evento con ACK (namespace actual)
    public func onAck(_ event: String, _ cb: @escaping (Any?, (Any?) -> Void) -> Void) {
        room.on(event) { payload, ack in
            cb(payload, { resp in ack?(resp) })
        }
    }

    // MARK: - Emit

    public func emit(_ event: String, _ payload: Any?) {
        client.emit(event, payload)
    }

    public func emitJSON<T: Encodable>(_ event: String, _ json: T, ack: ((Any?) -> Void)? = nil) {
        client.emit(event, json: json, ack: ack)
    }
}

// MARK: - Alias en español (opcionales)
public typealias ChatFacil = EasyChat
public extension EasyChat {
    func enCualquierEvento(_ cb: @escaping (String, Any?) -> Void) { onAny(cb) }
    func en(_ evento: String, _ cb: @escaping (Any?) -> Void) { on(evento, cb) }
    func emitir(_ evento: String, _ payload: Any?) { emit(evento, payload) }
    func emitir<T: Encodable>(_ evento: String, json: T, acuse: ((Any?) -> Void)? = nil) {
        emitJSON(evento, json, ack: acuse)
    }
}
