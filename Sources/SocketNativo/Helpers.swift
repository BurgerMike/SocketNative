import Foundation
#if canImport(UIKit)
import UIKit
#endif
import Network

final class Logger {
    let level: LogLevel
    let custom: Logging?
    init(_ level: LogLevel, custom: Logging? = nil) { self.level = level; self.custom = custom }
    func emit(_ lvl: LogLevel, _ msg: @autoclosure () -> String) {
        custom?.log(lvl, msg())
        if lvl.rawValue <= level.rawValue {
            switch lvl {
            case .error: print("[SocketNativo][E] \(msg())")
            case .info:  print("[SocketNativo][I] \(msg())")
            case .debug: print("[SocketNativo][D] \(msg())")
            default: break
            }
        }
    }
    func error(_ msg: @autoclosure () -> String) { emit(.error, msg()) }
    func info (_ msg: @autoclosure () -> String) { emit(.info,  msg()) }
    func debug(_ msg: @autoclosure () -> String) { emit(.debug, msg()) }
}

enum JSON {
    static let enc: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()
    static let dec: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()

    static func stringify(_ value: Any?) -> String? {
        if value == nil { return "null" }
        if let s = value as? String {
            return try? String(data: enc.encode([s]), encoding: .utf8).flatMap { String($0.dropFirst().dropLast()) }
        }
        if let d = value as? Data { return String(data: d, encoding: .utf8) }
        if let e = value as? Encodable {
            if let val = e as? AnyEncodable {
                return String(data: (try? enc.encode(val)) ?? Data("null".utf8), encoding: .utf8)
            }
        }
        if let obj = value, JSONSerialization.isValidJSONObject(obj) {
            return String(data: try! JSONSerialization.data(withJSONObject: obj, options: []), encoding: .utf8)
        }
        return nil
    }
}

public struct AnyEncodable: Encodable {
    private let _encode: (Encoder) throws -> Void
    public init<T: Encodable>(_ wrapped: T) {
        self._encode = wrapped.encode
    }
    public func encode(to encoder: Encoder) throws {
        try _encode(encoder)
    }
}

actor AsyncTimer {
    private var task: Task<Void, Never>?

    func schedule(every seconds: TimeInterval, _ block: @escaping @Sendable () -> Void) {
        cancel()
        task = Task.detached { [seconds] in
            let ns = UInt64(seconds * 1_000_000_000)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: ns)
                if Task.isCancelled { break }
                block()
            }
        }
    }

    func after(_ seconds: TimeInterval, _ block: @escaping @Sendable () -> Void) {
        cancel()
        task = Task.detached {
            let ns = UInt64(seconds * 1_000_000_000)
            try? await Task.sleep(nanoseconds: ns)
            if !Task.isCancelled { block() }
        }
    }
    func cancel() { task?.cancel(); task = nil }
}

final class Reachability {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "SocketNativo.Reachability")
    var onChange: (@Sendable (Bool) -> Void)?
    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.onChange?(path.status == .satisfied)
        }
        monitor.start(queue: queue)
    }
    deinit { monitor.cancel() }
}

extension Reachability: @unchecked Sendable {}
