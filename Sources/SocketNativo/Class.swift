//
//  Class.swift
//  SocketNativo
//
//  Created by Miguel Carlos Elizondo Martinez on 04/09/25.
//

import Foundation

public final class ChatClient {
    public static let shared = ChatClient()
    private init() {}

    private var engine: Engine?
    public private(set) var connected: Bool = false
    public var onAny: ((String, [Any]) -> Void)?

    private func wire(_ e: Engine) {
        e.onAny = { [weak self] evt, args in
            self?.onAny?(evt, args)
            if evt == "connect" { self?.connected = true }
            if evt == "disconnect" { self?.connected = false }
        }
    }

    public func connect(_ cfg: ChatConfig) async {
        do {
            switch cfg.mode {
            case .socketIO:
                let e = EngineSocketIO()
                wire(e)
                try await e.connect(cfg)
                engine = e
            case .plainWS:
                let e = EnginePlainWS()
                wire(e)
                try await e.connect(cfg)
                engine = e
            case .auto:
                do {
                    let e = EngineSocketIO()
                    wire(e)
                    try await e.connect(cfg)
                    engine = e
                } catch {
                    let e = EnginePlainWS()
                    wire(e)
                    try await e.connect(cfg)
                    engine = e
                }
            }
        } catch {
            onAny?("connect_error", [error.localizedDescription])
        }
    }

    public func disconnect() {
        engine?.disconnect()
        engine = nil
        connected = false
    }

    public func send(event: String, payload: Any) {
        engine?.send(event: event, payload: payload)
    }

    public func sendMessage(_ text: String, extras: [String: Any] = [:]) {
        var p: [String: Any] = ["content": text]
        extras.forEach { p[$0] = $1 }
        send(event: "sendMessage", payload: p)
    }

    public func typing(_ isTyping: Bool, extras: [String: Any] = [:]) {
        var p: [String: Any] = ["isTyping": isTyping]
        extras.forEach { p[$0] = $1 }
        send(event: "userTyping", payload: p)
    }
}


final class EngineSocketIO: NSObject, Engine, URLSessionWebSocketDelegate {
    var connected: Bool = false
    var onAny: ((String, [Any]) -> Void)?

    private var cfg: ChatConfig!
    private var session: URLSession!
    private var task: URLSessionWebSocketTask?
    private var receiving = false
    private var fulfilled = false

    func connect(_ cfg: ChatConfig) async throws {
        self.cfg = cfg
        let url = makeHandshakeURL(cfg)
        let conf = URLSessionConfiguration.default
        session = URLSession(configuration: conf, delegate: self, delegateQueue: nil)
        task = session.webSocketTask(with: URLRequest(url: url))
        task?.resume()
        receiving = true
        receiveNext()

        // Espera a “40” (Socket.IO connect)
        try await withThrowingTaskGroup(of: Void.self) { g in
            g.addTask { [weak self] in
                try await Task.sleep(nanoseconds: UInt64(cfg.connectTimeout * 1_000_000_000))
                guard let self, !self.fulfilled else { return }
                throw NSError(domain: "RTChat", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: "Socket.IO handshake timeout"])
            }
            g.addTask { [weak self] in
                while let self, !self.fulfilled {
                    try await Task.sleep(nanoseconds: 50_000_000)
                }
            }
            try await g.next()
            g.cancelAll()
        }
    }

    func send(event: String, payload: Any) {
        let arr: [Any] = [event, payload]
        guard let data = try? JSONSerialization.data(withJSONObject: arr),
              let body = String(data: data, encoding: .utf8) else { return }
        let prefix = siEventPrefix(cfg.namespace)  // "42" o "42/ns,"
        sendText(prefix + body)
    }

    func sendRaw(_ text: String) { sendText(text) }

    func disconnect() {
        connected = false
        receiving = false
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        dispatch("disconnect", [])
    }

    // MARK: - URLSessionWebSocketDelegate
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        // el server enviará "0{...}" (Engine.IO open); nosotros respondemos "40"
    }
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        connected = false
        dispatch("disconnect", [closeCode.rawValue])
    }

    // MARK: - Internos
    private func makeHandshakeURL(_ cfg: ChatConfig) -> URL {
        var comps = URLComponents(url: cfg.baseURL.appendingPathComponent(cfg.path), resolvingAgainstBaseURL: false)!
        var q = [
            URLQueryItem(name: "EIO", value: "4"),
            URLQueryItem(name: "transport", value: "websocket")
        ]
        q.append(contentsOf: cfg.query.map { .init(name: $0.key, value: $0.value) })
        comps.queryItems = q
        return comps.url!
    }

    private func receiveNext() {
        task?.receive { [weak self] res in
            guard let self else { return }
            switch res {
            case .failure(let err):
                self.dispatch("connect_error", [err.localizedDescription])
                self.connected = false
            case .success(let msg):
                switch msg {
                case .string(let s): self.handle(s)
                case .data(let d):
                    if let s = String(data: d, encoding: .utf8) { self.handle(s) }
                @unknown default: break
                }
                if self.receiving { self.receiveNext() }
            }
        }
    }

    private func handle(_ text: String) {
        guard let first = text.first else { return }
        switch first {
        case "0": // Engine.IO open → respondemos "40" (Socket.IO connect)
            sendText(siOpenFrame(cfg.namespace))
        case "2": // ping → pong
            sendText("3")
        case "4": // Engine.IO message → payload SI
            handleSIPayload(String(text.dropFirst()))
        default: break
        }
    }

    private func handleSIPayload(_ payload: String) {
        if payload.hasPrefix("40") {
            connected = true
            fulfilled = true
            dispatch("connect", [])
            return
        }
        let afterNS = stripNamespace(payload)
        if let idx = afterNS.firstIndex(of: "["),
           afterNS.hasPrefix("42") {
            let json = String(afterNS[idx...])
            if let arr = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [Any],
               let evt = arr.first as? String {
                let data = Array(arr.dropFirst())
                dispatch(evt, data)
            }
        }
    }

    private func stripNamespace(_ s: String) -> String {
        guard let slash = s.firstIndex(of: "/"),
              let comma = s[slash...].firstIndex(of: ","),
              slash > s.startIndex else { return s }
        var r = s
        r.removeSubrange(slash..<comma)
        return r
    }

    private func siOpenFrame(_ ns: String) -> String { ns == "/" ? "40" : "40\(ns)," }
    private func siEventPrefix(_ ns: String) -> String { ns == "/" ? "42" : "42\(ns)," }

    private func sendText(_ s: String) {
        task?.send(.string(s)) { err in
            if let err = err { print("RTChat send error:", err) }
        }
    }
}



final class EnginePlainWS: NSObject, Engine, URLSessionWebSocketDelegate {
    var connected: Bool = false
    var onAny: ((String, [Any]) -> Void)?

    private var cfg: ChatConfig!
    private var session: URLSession!
    private var task: URLSessionWebSocketTask?
    private var receiving = false

    func connect(_ cfg: ChatConfig) async throws {
        self.cfg = cfg
        var comps = URLComponents(url: cfg.baseURL.appendingPathComponent(cfg.path), resolvingAgainstBaseURL: false)!
        if !cfg.query.isEmpty {
            comps.queryItems = cfg.query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        let url = comps.url!

        let conf = URLSessionConfiguration.default
        session = URLSession(configuration: conf, delegate: self, delegateQueue: nil)
        task = session.webSocketTask(with: URLRequest(url: url))
        task?.resume()

        try await withThrowingTaskGroup(of: Void.self) { g in
            g.addTask { [weak self] in
                try await Task.sleep(nanoseconds: UInt64(cfg.connectTimeout * 1_000_000_000))
                guard let self, !self.connected else { return }
                throw NSError(domain: "RTChat", code: -2,
                              userInfo: [NSLocalizedDescriptionKey: "WS connect timeout"])
            }
            g.addTask { [weak self] in
                while let self, !self.connected {
                    try await Task.sleep(nanoseconds: 50_000_000)
                }
            }
            try await g.next()
            g.cancelAll()
        }

        receiving = true
        receiveNext()
        dispatch("connect", [])
    }

    func send(event: String, payload: Any) {
        var obj: [String: Any] = [:]
        obj[cfg.plainMap.eventKey] = event
        obj[cfg.plainMap.dataKey]  = payload
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: data, encoding: .utf8) else { return }
        sendText(s)
    }

    func sendRaw(_ text: String) { sendText(text) }

    func disconnect() {
        connected = false
        receiving = false
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        dispatch("disconnect", [])
    }

    // MARK: - URLSessionWebSocketDelegate
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol `protocol`: String?) {
        connected = true
    }
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        connected = false
        dispatch("disconnect", [closeCode.rawValue])
    }

    private func receiveNext() {
        task?.receive { [weak self] res in
            guard let self else { return }
            switch res {
            case .failure(let err):
                self.dispatch("error", [err.localizedDescription])
                self.connected = false
            case .success(let msg):
                switch msg {
                case .string(let s): self.handle(s)
                case .data(let d):
                    if let s = String(data: d, encoding: .utf8) { self.handle(s) }
                @unknown default: break
                }
                if self.receiving { self.receiveNext() }
            }
        }
    }

    private func handle(_ text: String) {
        if let data = text.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let evt = (obj[cfg.plainMap.eventKey] as? String) ?? "message"
            let pay = obj[cfg.plainMap.dataKey].map { [$0] } ?? []
            dispatch(evt, pay)
        } else {
            dispatch("message", [text])
        }
    }

    private func sendText(_ s: String) {
        task?.send(.string(s)) { err in
            if let err = err { print("RTChat send error:", err) }
        }
    }
}
