import Foundation

public protocol SocketNamespaceProtocol: AnyObject {
    @discardableResult func on(_ event: String, _ handler: @escaping (_ data: Any?, _ ack: ((Any?)->Void)?)->Void) -> Self
    @discardableResult func onBinary(_ event: String, _ handler: @escaping (_ data: Any?, _ attachments: [Data]?, _ ack: ((Any?, [Data]?)->Void)?)->Void) -> Self
    func emit(_ event: String, _ data: Any)
    func emit(_ event: String, _ data: Any, ack: ((Any?)->Void)?)
    func emitBinary(_ event: String, json: Any, attachments: [Data], ack: ((Any?, [Data]?)->Void)?)
}

public protocol ChatClientProtocol: AnyObject {
    var onAny: ((_ event: SocketEvent, _ payload: Any?) -> Void)? { get set }
    var onLog: ((String)->Void)? { get set }
    func connect(_ cfg: ChatConfig) async throws
    func disconnect()
    func of(_ namespace: String) -> SocketNamespaceProtocol
}

public final class SocketNamespace: SocketNamespaceProtocol {
    let ns: String
    weak var manager: ChatClient?
    private var jsonHandlers: [String: (_ data: Any?, _ ack: ((Any?)->Void)?)->Void] = [:]
    private var binHandlers: [String: (_ data: Any?, _ attachments: [Data]?, _ ack: ((Any?, [Data]?)->Void)?)->Void] = [:]

    init(ns: String, manager: ChatClient) { self.ns = ns; self.manager = manager }

    @discardableResult
    public func on(_ event: String, _ handler: @escaping (_ data: Any?, _ ack: ((Any?)->Void)?)->Void) -> Self { jsonHandlers[event] = handler; return self }
    @discardableResult
    public func onBinary(_ event: String, _ handler: @escaping (_ data: Any?, _ attachments: [Data]?, _ ack: ((Any?, [Data]?)->Void)?)->Void) -> Self { binHandlers[event] = handler; return self }

    public func emit(_ event: String, _ data: Any) { manager?.emit(ns: ns, event: event, data: data, ack: nil) }
    public func emit(_ event: String, _ data: Any, ack: ((Any?)->Void)?) { manager?.emit(ns: ns, event: event, data: data, ack: ack) }
    public func emitBinary(_ event: String, json: Any, attachments: [Data], ack: ((Any?, [Data]?)->Void)?) { manager?.emitBinary(ns: ns, event: event, json: json, attachments: attachments, ack: ack) }

    func dispatchJSON(_ event: String, _ data: Any?, ackResponder: ((Any?)->Void)?) {
        if let h = jsonHandlers[event] { h(data, ackResponder) } else { manager?.onAny?(.custom(event, data), data) }
    }
    func dispatchBinary(_ event: String, _ data: Any?, attachments: [Data]?, ackResponder: ((Any?, [Data]?)->Void)?) {
        if let h = binHandlers[event] { h(data, attachments, ackResponder) } else { manager?.onAny?(.custom(event, data), data) }
    }
}
