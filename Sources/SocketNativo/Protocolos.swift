//
//  Protocolos.swift
//  SocketNativo
//
//  Created by Miguel Carlos Elizondo Martinez on 04/09/25.
//

import Foundation

protocol Engine: AnyObject {
    var connected: Bool { get }
    var onAny: ((String, [Any]) -> Void)? { get set }
    func connect(_ cfg: ChatConfig) async throws
    func send(event: String, payload: Any)
    func sendRaw(_ text: String)
    func disconnect()
}
