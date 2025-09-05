import Foundation
import Network

public final class ChatClient: ChatClientProtocol {
    public var onAny: ((_ event: SocketEvent, _ payload: Any?) -> Void)?
    public var onLog: ((String)->Void)?

    private var cfg: ChatConfig!
    private var transport: Transport?
    private var currentKind: TransportKind?
    private var sid: String?

    private var nextAckID: Int = 1
    private enum AckCB { case json((Any?)->Void), binary((Any?, [Data]?)->Void) }
    private var pendingAcks: [Int: AckCB] = [:]
    private var offlineQueueJSON: [(String, String, Any, ((Any?)->Void)?)] = [] // (ns,event,data,ack)
    private var offlineQueueBIN: [(String, String, Any, [Data], ((Any?, [Data]?)->Void)?)] = []

    private var backoff: TimeInterval = 0
    private var attempts = 0
    private var reconnecting = false

    private var sockets: [String: SocketNamespace] = [:]
    private var nsConnected: Set<String> = []

    private let netMon = NWPathMonitor()
    private let netQueue = DispatchQueue(label: "socket.native.netmon")

    // Upgrade (polling -> websocket)
    private var upgradingWS: WebSocketTransport?

    // Binarios pendientes (BINARY_EVENT/BINARY_ACK)
    private struct PendingBin { let isAck: Bool; let ns: String; let id: Int?; let json: String; let expected: Int; var parts: [Data] }
    private var binQueue: [PendingBin] = []

    public init() {
        netMon.start(queue: netQueue)
        netMon.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            if path.status == .satisfied, self.transport == nil, self.cfg != nil {
                Task { try? await self.connect(self.cfg) }
            }
        }
    }

    // MARK: Public API
    public func of(_ namespace: String) -> SocketNamespaceProtocol {
        if let s = sockets[namespace] { return s }
        let s = SocketNamespace(ns: namespace, manager: self)
        sockets[namespace] = s
        if transport != nil, !nsConnected.contains(namespace) { sendNamespaceConnect(namespace) }
        return s
    }

    public func connect(_ cfg: ChatConfig) async throws {
        self.cfg = cfg
        attempts = 0; backoff = cfg.reconnectionDelay
        let initialNS: String = { switch cfg.namespace { case .fixed(let s): return s; case .auto(let p, _): return p } }()
        _ = of(initialNS)
        try await openWithFallback()
        onAny?(.connect(initialNS), nil)
        flushOffline()
    }

    public func disconnect() {
        upgradingWS?.close(); upgradingWS = nil
        transport?.close(); transport = nil
        nsConnected.removeAll()
        onAny?(.disconnect("/"), nil)
    }

    // MARK: Emit JSON/BIN con namespace
    func emit(ns: String, event: String, data: Any, ack: ((Any?)->Void)?) {
        guard let _ = transport else { offlineQueueJSON.append((ns, event, data, ack)); log("buffer emit: \(event)@\(ns)"); return }
        let id = ack != nil ? allocateAck(.json(ack!)) : nil
        let frame = makeEventFrame(event: event, data: data, ns: ns, id: id)
        transport?.send(frame)
        if !nsConnected.contains(ns) { sendNamespaceConnect(ns) }
    }

    func emitBinary(ns: String, event: String, json: Any, attachments: [Data], ack: ((Any?, [Data]?)->Void)?) {
        guard let transport else { offlineQueueBIN.append((ns, event, json, attachments, ack)); log("buffer emitBinary: \(event)@\(ns)"); return }
        let id = ack != nil ? allocateAck(.binary(ack!)) : nil
        let (jsonWithPH, count) = makePlaceholders(json: [event, json], attachments: attachments)
        var header = "45" + String(count) + "-"
        if ns != "/" { header += ns + "," }
        if let id { header += String(id) }
        let jsonStr = (try? JSONSerialization.data(withJSONObject: jsonWithPH)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        transport.send(header + jsonStr)
        attachments.forEach { transport.sendBinary($0) }
        if !nsConnected.contains(ns) { sendNamespaceConnect(ns) }
    }

    // =================================================
    // Internals — open/fallback/upgrade
    // =================================================
    private func openWithFallback() async throws {
        var lastErr: Error?
        for path in pathCandidates(cfg.path) {
            for kind in cfg.preferTransports {
                do {
                    try await open(kind: kind, path: path)
                    return
                } catch { lastErr = error; log("falló \(kind) @\(path): \(error.localizedDescription)") }
            }
        }
        throw SocketNativeError.allCombosFailed(last: lastErr)
    }

    private func open(kind: TransportKind, path: String) async throws {
        let (openURL, _) = try makeOpenURL(kind: kind, path: path)
        let t: Transport = (kind == .websocket) ? WebSocketTransport() : PollingTransport()
        self.transport = t; self.currentKind = kind
        t.onText = { [weak self] s in self?.handleIncoming(fromUpgradeProbe: false, text: s) }
        t.onBinary = { [weak self] d in self?.handleBinaryAttachment(d) }
        t.onClose = { [weak self] err in self?.handleClose(err) }
        let first = try await t.open(url: openURL, headers: cfg.headers, timeout: cfg.connectTimeout)
        if first.hasPrefix("0"), let info = try? Self.decodeOpen(from: String(first.dropFirst())) {
            self.sid = info.sid
            for ns in sockets.keys { sendNamespaceConnect(ns) }
            if kind == .polling, (info.upgrades?.contains("websocket") ?? false) {
                Task { await self.tryUpgradeToWebSocket(path: path, sid: info.sid) }
            }
        }
    }

    private func makeOpenURL(kind: TransportKind, path: String) throws -> (URL, URLComponents) {
        var comps = URLComponents(url: cfg.baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        var items = cfg.query.map { URLQueryItem(name: $0.key, value: $0.value) }
        items.append(.init(name: "EIO", value: String(cfg.engineIO.rawValue)))
        items.append(.init(name: "transport", value: kind == .websocket ? "websocket" : "polling"))
        comps.queryItems = (comps.queryItems ?? []) + items
        guard let httpURL = comps.url else { throw SocketNativeError.invalidURL }
        let openURL = (kind == .websocket) ? httpURL.toWS() : httpURL
        return (openURL, comps)
    }

    private func tryUpgradeToWebSocket(path: String, sid: String) async {
        do {
            var (_, comps) = try makeOpenURL(kind: .websocket, path: path)
            comps.queryItems = (comps.queryItems ?? []) + [URLQueryItem(name: "sid", value: sid)]
            guard let httpURL = comps.url else { return }
            let wsURL = httpURL.toWS()
            let probe = WebSocketTransport()
            upgradingWS = probe
            probe.onText = { [weak self] s in self?.handleIncoming(fromUpgradeProbe: true, text: s) }
            probe.onBinary = { _ in }
            probe.onClose = { [weak self] _ in self?.upgradingWS = nil }
            _ = try await probe.open(url: wsURL, headers: cfg.headers, timeout: 5)
            probe.send("2probe")
            log("upgrade probe iniciado")
        } catch { log("upgrade probe error: \(error.localizedDescription)") }
    }

    private func finalizeUpgrade() {
        guard let probe = upgradingWS else { return }
        probe.send("5")
        log("upgrade a WebSocket confirmado")
        transport?.close(); transport = probe; currentKind = .websocket
        upgradingWS = nil
    }

    private static func decodeOpen(from json: String) throws -> (sid: String, upgrades: [String]?, pingInterval: Int?, pingTimeout: Int?) {
        struct Open: Decodable { let sid: String; let upgrades: [String]?; let pingInterval: Int?; let pingTimeout: Int? }
        let o = try JSONDecoder().decode(Open.self, from: Data(json.utf8))
        return (o.sid, o.upgrades, o.pingInterval, o.pingTimeout)
    }

    private func sendNamespaceConnect(_ ns: String) {
        var frame = "40"
        if ns == "/" { frame += ",{}" }
        else {
            let authJSON: String = {
                if let a = cfg.auth, let d = try? JSONSerialization.data(withJSONObject: a), let s = String(data: d, encoding: .utf8) { return s }
                return "{}"
            }()
            frame += ns + "," + authJSON
        }
        transport?.send(frame)
        nsConnected.insert(ns)
    }

    private func handleClose(_ err: Error?) {
        log("close: \(err?.localizedDescription ?? "-")")
        upgradingWS?.close(); upgradingWS = nil
        transport?.close(); transport = nil
        nsConnected.removeAll()
        if reconnecting { return }
        reconnecting = true
        Task { await self.reconnectLoop() }
    }

    private func reconnectLoop() async {
        defer { reconnecting = false }
        let maxAttempts = cfg.reconnectionAttempts
        while attempts < maxAttempts {
            attempts += 1
            let delay = min(cfg.reconnectionDelayMax, backoff == 0 ? cfg.reconnectionDelay : min(cfg.reconnectionDelayMax, backoff*2))
            let jitter = Double.random(in: 0...0.3)
            let wait = delay + jitter
            backoff = delay
            log("reconnect attempt #\(attempts) in \(String(format: "%.2f", wait))s")
            await sleepSeconds(wait)
            do {
                try await openWithFallback()
                attempts = 0; backoff = cfg.reconnectionDelay
                for ns in sockets.keys { onAny?(.connect(ns), nil) }
                flushOffline()
                return
            } catch { log("reconnect failed: \(error.localizedDescription)") }
        }
        onAny?(.error("Reconexión agotada"), nil)
    }

    private func flushOffline() {
        guard transport != nil else { return }
        if !offlineQueueJSON.isEmpty {
            let q = offlineQueueJSON; offlineQueueJSON.removeAll()
            for (ns, ev, data, ack) in q { emit(ns: ns, event: ev, data: data, ack: ack) }
        }
        if !offlineQueueBIN.isEmpty {
            let q = offlineQueueBIN; offlineQueueBIN.removeAll()
            for (ns, ev, json, blobs, ack) in q { emitBinary(ns: ns, event: ev, json: json, attachments: blobs, ack: ack) }
        }
    }

    // MARK: Incoming frames (incluye upgrade y ACKs)
    private func handleIncoming(fromUpgradeProbe: Bool, text s: String) {
        guard let t = s.first else { return }
        switch t {
        case "0":
            log("OPEN: \(s)")
        case "2":
            if s == "2probe" { upgradingWS?.send("3probe") }
            else { onAny?(.ping, nil); transport?.send("3") }
        case "3":
            if s == "3probe" && fromUpgradeProbe { finalizeUpgrade() }
            else { onAny?(.pong, nil) }
        case "4":
            guard s.count >= 2 else { return }
            let subtype = s[s.index(s.startIndex, offsetBy: 1)]
            let slice = s.dropFirst(2)
            switch subtype {
            case "0":
                let (ns, _) = splitNSAndRest(slice)
                nsConnected.insert(ns)
                onAny?(.connect(ns), nil)
            case "1":
                let (ns, _) = splitNSAndRest(slice)
                nsConnected.remove(ns)
                onAny?(.disconnect(ns), nil)
            case "2": // EVENT JSON → 42[/ns,][id][json]
                let (ns, rest) = splitNSAndRest(slice)
                let (maybeID, json) = splitIDAndJSON(rest)
                if let arr = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [Any], let ev = arr.first as? String {
                    let payload = arr.count > 1 ? arr[1] : nil
                    let ackResponder: ((Any?)->Void)? = maybeID.map { [weak self] id in
                        return { data in
                            let json = (try? JSONSerialization.data(withJSONObject: [data as Any]))
                                .flatMap { String(data: $0, encoding: .utf8) } ?? "[null]"
                            var prefix = "43"
                            if ns != "/" { prefix += ns + "," }
                            prefix += String(id)
                            self?.transport?.send(prefix + json)
                        }
                    }
                    sockets[ns]?.dispatchJSON(ev, payload, ackResponder: ackResponder)
                }
            case "3": // ACK JSON → 43[/ns,]id[json]
                let (_, rest) = splitNSAndRest(slice)
                let (id, json) = splitIDAndJSON(rest)
                let obj: Any? = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) ?? nil
                if let id, let cb = pendingAcks.removeValue(forKey: id) {
                    switch cb { case .json(let f): f(obj); case .binary(let f): f(obj, nil) }
                    onAny?(.ack(id, obj), obj)
                }
            case "5": // BINARY_EVENT header → 45<att>-[/ns,][id][json]
                if let header = parseBinaryHeader(slice, isAck: false) { binQueue.append(header) }
            case "6": // BINARY_ACK header → 46<att>-[/ns,][id][json]
                if let header = parseBinaryHeader(slice, isAck: true) { binQueue.append(header) }
 // BINARY_ACK header → 46<att>-[/ns,][id][json]
                guard let header = parseBinaryHeader(slice, isAck: true) else { return }
                binQueue.append(header)
            case "4":
                let (ns, rest) = splitNSAndRest(slice)
                onAny?(.connectError(ns, String(rest)), nil)
            default:
                log("SIO 4? subtype=\(subtype) raw=\(s)")
            }
        default:
            log("Engine.IO ? raw=\(s)")
        }
    }

    private func handleBinaryAttachment(_ data: Data) {
        guard !binQueue.isEmpty else { return }
        for i in binQueue.indices {
            if binQueue[i].parts.count < binQueue[i].expected {
                binQueue[i].parts.append(data)
                if binQueue[i].parts.count == binQueue[i].expected {
                    let pending = binQueue.remove(at: i)
                    processCompletedBinary(pending)
                }
                break
            }
        }
    }

    private func processCompletedBinary(_ pb: PendingBin) {
        guard let arr = try? JSONSerialization.jsonObject(with: Data(pb.json.utf8)) as? [Any], let ev = arr.first as? String else { return }
        let payloadAny = arr.count > 1 ? arr[1] : nil
        let rebuilt = payloadAny.map { injectAttachments(jsonAny: $0, blobs: pb.parts) }
        if pb.isAck {
            if let id = pb.id, let cb = pendingAcks.removeValue(forKey: id) {
                switch cb { case .json(let f): f(rebuilt); case .binary(let f): f(rebuilt, pb.parts) }
                onAny?(.ack(id, rebuilt), rebuilt)
            }
        } else {
            let ns = pb.ns
            let ackResponder: ((Any?, [Data]?)->Void)? = pb.id.map { [weak self] id in
                return { data, blobs in
                    let json = (try? JSONSerialization.data(withJSONObject: [data as Any]))
                        .flatMap { String(data: $0, encoding: .utf8) } ?? "[null]"
                    let count = blobs?.count ?? 0
                    var header = "46" + String(count) + "-"
                    if ns != "/" { header += ns + "," }
                    header += String(id)
                    self?.transport?.send(header + json)
                    blobs?.forEach { self?.transport?.sendBinary($0) }
                }
            }
            sockets[ns]?.dispatchBinary(ev, rebuilt, attachments: pb.parts, ackResponder: ackResponder)
        }
    }

    private func parseBinaryHeader(_ slice: Substring, isAck: Bool) -> PendingBin? {
        var rest = slice
        var attStr = ""
        while let ch = rest.first, ch.isNumber { attStr.append(ch); rest = rest.dropFirst() }
        guard rest.first == "-", let expected = Int(attStr) else { return nil }
        rest = rest.dropFirst()
        let (ns, afterNS) = splitNSAndRest(rest)
        let (id, json) = splitIDAndJSON(afterNS)
        let jsonStr = String(json)
        return PendingBin(isAck: isAck, ns: ns, id: id, json: jsonStr, expected: expected, parts: [])
    }

    // MARK: Builders
    private func makeEventFrame(event: String, data: Any, ns: String, id: Int?) -> String {
        let arr: [Any] = [event, data]
        let json = (try? JSONSerialization.data(withJSONObject: arr)).flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\(event)\"]"
        var prefix = "42"
        if ns != "/" { prefix += ns + "," }
        if let id { prefix += String(id) }
        return prefix + json
    }

    private func allocateAck(_ cb: AckCB) -> Int { let id = nextAckID; nextAckID += 1; pendingAcks[id] = cb; return id }

    private func log(_ s: String) { if cfg?.logLevel.rawValue ?? 0 >= LogLevel.info.rawValue { onLog?(s) } }

    private func pathCandidates(_ strategy: PathStrategy) -> [String] { switch strategy { case .fixed(let p): return [p]; case .auto(let arr): return arr } }
}
