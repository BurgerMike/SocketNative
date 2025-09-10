import Foundation

@MainActor
public final class Namespace {
    public typealias Listener = @Sendable (Any?, (@Sendable (Any?) -> Void)?) -> Void
    public let name: String
    unowned let owner: ChatClient
    private var listeners: [String: [Listener]] = [:]
    init(name: String, owner: ChatClient) { self.name = name; self.owner = owner }
    public func on(_ event: String, _ cb: @escaping Listener) { listeners[event, default: []].append(cb) }
    public func off(_ event: String) { listeners.removeValue(forKey: event) }
    func dispatch(event: String, payload: Any?, ack: (@Sendable (Any?) -> Void)?) {
        if let arr = listeners[event] { for cb in arr { cb(payload, ack) } }
    }
    // Emit específico del namespace
    public func emit(_ event: String, _ payload: Any?, ack: (@Sendable (Any?) -> Void)? = nil) {
        owner.emit(event, payload, in: name, ack: ack)
    }
}

@MainActor
public final class ChatClient: NSObject {
    private var cfg: ChatConfig!
    private var logger: Logger!
    private var driver: TransportDriver?
    private var reach: Reachability?

    private var probeWS: WebSocketDriver?

    private var reconnecting = false
    private var attempt = 0
    private var delay: TimeInterval = 0

    private var connected = false
    private var readyForEmits = false
    private var sid: String?

    private var pingInterval: TimeInterval = 25
    private var pingTimeout: TimeInterval = 20
    private let pingTimer = AsyncTimer()
    private let ackTimer = AsyncTimer()

    private var ackSeq = 0
    private var acks: [Int: AckPending] = [:]

    private var namespaces: [String: Namespace] = [:]
    private var stickyJoins: [(String, Any?)] = []
    private var offlineQ: [(String, String, Any?, (@Sendable (Any?) -> Void)?)] = [] // (event, nsp, payload, ack)

    private var binAssembler = BinaryAssembler()

    public var onLog: (@Sendable (String) -> Void)?
    public var onAny: (@Sendable (String, Any?) -> Void)?

    public override init() { super.init() }

    public func of(_ name: String) -> Namespace {
        if let ns = namespaces[name] { return ns }
        let ns = Namespace(name: name, owner: self); namespaces[name] = ns; return ns
    }

    public func stickyJoin(event: String, payload: Any?) { stickyJoins.append((event, payload)) }

    public func connect(_ cfg: ChatConfig) async throws {
        self.cfg = cfg
        self.logger = Logger(cfg.logLevel, custom: cfg.logger)
        self.reach = Reachability()
        self.reach?.onChange = { [weak self] ok in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if ok, !(self.driver != nil && self.connected) {
                    try? await self.start()
                }
            }
        }
        try await start()
    }

    private func buildURLAndHeaders(transport: Transport, sid: String? = nil) async throws -> (URL, [String:String]) {
        var comp = URLComponents(url: cfg.baseURL, resolvingAgainstBaseURL: false)
        comp?.path = cfg.path
        var q: [String:String] = cfg.query
        if let extraQ = await cfg.authProvider?.queryForConnection() { for (k,v) in extraQ { q[k] = v } }
        var items: [URLQueryItem] = [ URLQueryItem(name: "EIO", value: "4"),
                                      URLQueryItem(name: "transport", value: transport.rawValue) ]
        if let sid { items.append(URLQueryItem(name: "sid", value: sid)) }
        for (k,v) in q { items.append(URLQueryItem(name: k, value: v)) }
        comp?.queryItems = items
        guard let url = comp?.url else { throw ChatError.badURL }
        var h = cfg.headers
        if let extraH = await cfg.authProvider?.headersForConnection() { for (k,v) in extraH { h[k] = v } }
        return (url, h)
    }

    private func start() async throws {
        let initial: Transport = cfg.preferTransports.contains(.polling) ? .polling : .websocket
        try await startTransport(initial)
        scheduleAckSweep()
    }

    private func startTransport(_ t: Transport, withSID sid: String? = nil) async throws {
        let (url, headers) = try await buildURLAndHeaders(transport: t, sid: sid)
        switch t {
        case .websocket:
            let ws = WebSocketDriver(logger: logger); ws.delegate = self; driver = ws
            ws.connect(url: url, headers: headers, security: cfg.security)
        case .polling:
            let p = PollingDriver(logger: logger); p.delegate = self; driver = p
            p.connect(url: url, headers: headers, security: cfg.security)
        }
    }

    public func disconnect() {
        driver?.close(); driver = nil; connected = false; readyForEmits = false; sid = nil
        Task { await pingTimer.cancel() }; Task { await ackTimer.cancel() }
    }

    // MARK: - Emit API

    public func emit(_ event: String, _ payload: Any?) { emit(event, payload, in: cfg.namespace, ack: nil) }
    public func emit<T: Encodable>(_ event: String, json: T, ack: (@Sendable (Any?) -> Void)? = nil) { emit(event, AnyEncodable(json), in: cfg.namespace, ack: ack) }

    public func emit(_ event: String, _ payload: Any?, in namespace: String, ack: (@Sendable (Any?) -> Void)? = nil) {
        var ev = event; var pl = payload
        for m in cfg.middlewares { if let out = m.willEmit(event: ev, payload: pl) { ev = out.0; pl = out.1 } else { return } }

        guard readyForEmits else {
            if cfg.offlineQueue.enabled {
                if offlineQ.count >= cfg.offlineQueue.maxItems { _ = offlineQ.removeFirst() }
                offlineQ.append((ev, namespace, pl, ack))
            }
            return
        }

        if let bin = BinaryEncoder.encode(event: ev, args: pl as Any) {
            var head = "4" + (ack == nil ? "5" : "6")
            if namespace != "/" { head += namespace + "," }
            var idStr = ""
            if let ack = ack {
                ackSeq += 1; let cbID = ackSeq; idStr = String(cbID)
                let deadline = Date().addingTimeInterval(cfg.ack.timeout)
                acks[cbID] = AckPending(id: cbID, deadline: deadline, cb: ack)
            }
            head += idStr + bin.header + bin.arrayJSON
            driver?.sendText(head); for data in bin.attachments { driver?.sendBinary(data) }
            return
        }

        var head = "42"; if namespace != "/" { head += namespace + "," }
        var idStr = ""
        if let ack = ack {
            ackSeq += 1; let cbID = ackSeq; idStr = String(cbID)
            let deadline = Date().addingTimeInterval(cfg.ack.timeout)
            acks[cbID] = AckPending(id: cbID, deadline: deadline, cb: ack)
        }
        let bodyJSON: String
        if let s = JSON.stringify(pl) { bodyJSON = "[\(JSON.stringify(ev)! ), \(s)]" } else { bodyJSON = "[\(JSON.stringify(ev)!)]" }
        driver?.sendText(head + idStr + bodyJSON)
    }

    private func flushOffline() {
        guard !offlineQ.isEmpty else { return }
        let items = offlineQ; offlineQ.removeAll()
        for (ev,nsp,pl,ack) in items { emit(ev, pl, in: nsp, ack: ack) }
    }

    private func scheduleReconnect() {
        guard cfg.reconnect.enabled else { return }
        reconnecting = true; attempt += 1
        if attempt > cfg.reconnect.maxAttempts { return }
        delay = attempt == 1 ? cfg.reconnect.initial : min(cfg.reconnect.max, delay * cfg.reconnect.factor)
        let jitter = delay * cfg.reconnect.jitter; let realDelay = max(0.05, delay + Double.random(in: -jitter...jitter))
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(realDelay * 1_000_000_000))
            guard let self else { return }
            try? await self.start()
        }
    }
    private func resetReconnect() { reconnecting = false; attempt = 0; delay = cfg.reconnect.initial }

    private func schedulePing() {
        Task { [weak self] in
            guard let self else { return }
            await self.pingTimer.cancel()
            await self.pingTimer.schedule(every: max(5, self.pingInterval)) {
                Task { @MainActor [weak self] in
                    self?.driver?.sendText(String(EIOType.ping.rawValue))
                }
            }
        }
    }
    private func scheduleAckSweep() {
        Task { [weak self] in
            guard let self else { return }
            await self.ackTimer.cancel()
            await self.ackTimer.schedule(every: 1.0) {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let now = Date()
                    let expired = self.acks.filter { $0.value.deadline < now }.map { $0.key }
                    for id in expired {
                        if let p = self.acks.removeValue(forKey: id) {
                            p.cb(["ackTimeout": true])
                        }
                    }
                }
            }
        }
    }

    // MARK: - Inbound handling

    private func handleText(_ text: String, fromProbe: Bool = false) {
        guard let tchar = text.first, let eio = EIOType(rawValue: tchar) else { return }
        let rest = String(text.dropFirst())
        switch eio {
        case .open:
            if let data = rest.data(using: .utf8), let open = try? JSONDecoder().decode(OpenPayload.self, from: data) {
                sid = open.sid
                pingInterval = (open.pingInterval ?? 25000) / 1000.0
                pingTimeout  = (open.pingTimeout  ?? 20000) / 1000.0
                connected = true; schedulePing()

                // CONNECT de Socket.IO con payload opcional (sin await en contexto sync)
                let nsp = cfg.namespace
                let provider = cfg.connectPayloadProvider
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    var s = "40"
                    if nsp != "/" { s += nsp + "," }
                    if let payload = await provider?(),
                       let data = try? JSONSerialization.data(withJSONObject: payload),
                       let j = String(data: data, encoding: .utf8) {
                        s += j
                    }
                    self.driver?.sendText(s)
                }

                if (driver is PollingDriver), (cfg.preferTransports.contains(.websocket)), (open.upgrades?.contains("websocket") == true), let sid {
                    Task { @MainActor [weak self] in
                        try? await self?.startWebSocketProbe(withSID: sid)
                    }
                }
            }
        case .ping: driver?.sendText(String(EIOType.pong.rawValue))
        case .pong:
            if fromProbe && rest == "probe" {
                probeWS?.sendText(String(EIOType.upgrade.rawValue))
                driver?.close(); driver = probeWS; probeWS = nil
            }
        case .message: handleSocketIO(rest)
        case .close: readyForEmits = false; connected = false; scheduleReconnect()
        default: break
        }
    }

    private func handleBinary(_ data: Data, fromProbe: Bool = false) {
        if let done = binAssembler.appendBinary(data) {
            if done.isAck, let id = done.id, let p = acks.removeValue(forKey: id) {
                p.cb(done.args)
            } else {
                onAny?(done.event, done.args.first)
                of(done.nsp).dispatch(event: done.event, payload: done.args.first, ack: nil)
            }
        }
    }

    private func startWebSocketProbe(withSID sid: String) async throws {
        let (url, headers) = try await buildURLAndHeaders(transport: .websocket, sid: sid)
        let ws = WebSocketDriver(logger: logger); ws.delegate = self; probeWS = ws
        ws.connect(url: url, headers: headers, security: cfg.security)
    }

    private func handleSocketIO(_ s: String) {
        guard let typeChar = s.first, let siotype = SIOType(rawValue: typeChar) else { return }
        var idx = s.index(s.startIndex, offsetBy: 1)
        var nsp = "/"
        if idx < s.endIndex, s[idx] == "/" {
            var end = idx; while end < s.endIndex, s[end] != "," { end = s.index(after: end) }
            nsp = String(s[idx..<end]); idx = end; if idx < s.endIndex, s[idx] == "," { idx = s.index(after: idx) }
        }
        var idStr = ""; while idx < s.endIndex, s[idx].isNumber { idStr.append(s[idx]); idx = s.index(after: idx) }
        let jsonPart = String(s[idx...])

        switch siotype {
        case .connect:
            readyForEmits = true; resetReconnect()
            for (ev, pl) in stickyJoins { emit(ev, pl, in: nsp, ack: nil) }; flushOffline()

        case .event:
            if let data = jsonPart.data(using: .utf8), let arr = try? JSONSerialization.jsonObject(with: data) as? [Any],
               arr.count >= 1, let evName = arr[0] as? String {
                let payload = arr.count >= 2 ? arr[1] : nil
                var transformed = (evName, payload)
                for m in cfg.middlewares { if let out = m.didReceive(event: transformed.0, payload: transformed.1) { transformed = out } else { return } }
                onAny?(transformed.0, transformed.1)
                let ns = of(nsp)
                var ackCB: (@Sendable (Any?) -> Void)? = nil
                if !idStr.isEmpty, let id = Int(idStr) {
                    ackCB = { resp in
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            if let bin = BinaryEncoder.encodeAck(args: (resp ?? [])) {
                                var head = "46" + (nsp != "/" ? nsp + "," : "") + String(id)
                                head += bin.header + bin.arrayJSON
                                self.driver?.sendText(head)
                                for d in bin.attachments { self.driver?.sendBinary(d) }
                            } else {
                                let head = "43" + (nsp != "/" ? nsp + "," : "") + String(id)
                                let body: String = {
                                    if let s = JSON.stringify(resp) { return s.hasPrefix("[") ? s : "[" + s + "]" }
                                    else { return "[]" }
                                }()
                                self.driver?.sendText(head + body)
                            }
                        }
                    }
                }
                ns.dispatch(event: transformed.0, payload: transformed.1, ack: ackCB)
            }

        case .ack:
            if let id = Int(idStr), let p = acks.removeValue(forKey: id) {
                if let data = jsonPart.data(using: .utf8), let arr = try? JSONSerialization.jsonObject(with: data) { p.cb(arr) }
                else { p.cb(nil) }
            }

        case .binaryEvent, .binaryAck:
            var j = jsonPart.startIndex; var countStr = ""
            while j < jsonPart.endIndex, jsonPart[j].isNumber { countStr.append(jsonPart[j]); j = jsonPart.index(after: j) }
            guard j < jsonPart.endIndex, jsonPart[j] == "-" else { return }
            j = jsonPart.index(after: j)
            var nsp2 = nsp; var idLocal: Int? = Int(idStr)
            if j < jsonPart.endIndex, jsonPart[j] == "/" {
                var end = j; while end < jsonPart.endIndex, jsonPart[end] != "," { end = jsonPart.index(after: end) }
                nsp2 = String(jsonPart[j..<end]); j = end; if j < jsonPart.endIndex, jsonPart[j] == "," { j = jsonPart.index(after: j) }
            }
            var idStr2 = ""; while j < jsonPart.endIndex, jsonPart[j].isNumber { idStr2.append(jsonPart[j]); j = jsonPart.index(after: j) }
            if !idStr2.isEmpty { idLocal = Int(idStr2) }
            let arrayPart = String(jsonPart[j...])
            guard let data = arrayPart.data(using: .utf8), let arr = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return }
            binAssembler.startPacket(isAck: (siotype == .binaryAck), nsp: nsp2, id: idLocal, jsonArray: arr)

        case .error:
            Task { @MainActor [weak self] in
                let shouldRetry = await self?.cfg.authProvider?.didReceiveAuthError(code: nil, message: jsonPart) ?? false
                if shouldRetry {
                    self?.disconnect()
                    try? await self?.start()
                }
            }
        default: break
        }
    }
}

extension ChatClient: TransportDriverDelegate {
    public func transportDidOpen(_ transport: TransportDriver) {
        if transport as AnyObject? === probeWS as AnyObject? { probeWS?.sendText("2probe") }
    }
    public func transport(_ transport: TransportDriver, didFail error: Error) {
        connected = false; readyForEmits = false; scheduleReconnect()
    }
    public func transportDidClose(_ transport: TransportDriver, code: Int?, reason: Data?) {
        connected = false; readyForEmits = false; scheduleReconnect()
    }
    public func transport(_ transport: TransportDriver, didReceiveText text: String) {
        handleText(text, fromProbe: (transport as AnyObject? === probeWS as AnyObject?))
    }
    public func transport(_ transport: TransportDriver, didReceiveData data: Data) {
        handleBinary(data, fromProbe: (transport as AnyObject? === probeWS as AnyObject?))
    }
}
