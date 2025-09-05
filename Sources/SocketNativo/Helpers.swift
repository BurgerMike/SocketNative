import Foundation

extension URL {
    func toWS() -> URL {
        var c = URLComponents(url: self, resolvingAgainstBaseURL: false)!
        c.scheme = (c.scheme == "https") ? "wss" : "ws"
        return c.url!
    }
}

func sleepSeconds(_ s: TimeInterval) async {
    try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000))
}

// Engine.IO polling framing helpers
struct PollPacket { let type: String; let data: String }
func parsePollingPayload(_ s: String) -> [PollPacket] {
    var packets: [PollPacket] = []
    var idx = s.startIndex
    while idx < s.endIndex {
        var lenStr = ""
        while idx < s.endIndex, s[idx].isNumber { lenStr.append(s[idx]); idx = s.index(after: idx) }
        guard idx < s.endIndex, s[idx] == ":", let len = Int(lenStr) else { break }
        idx = s.index(after: idx)
        let end = s.index(idx, offsetBy: len, limitedBy: s.endIndex) ?? s.endIndex
        let packet = String(s[idx..<end])
        if let t = packet.first { packets.append(.init(type: String(t), data: String(packet.dropFirst()))) }
        idx = end
    }
    if packets.isEmpty, let first = s.first { packets.append(.init(type: String(first), data: String(s.dropFirst()))) }
    return packets
}
func makePollingBody(_ frames: [String]) -> Data {
    let joined = frames.map { "\($0.count):\($0)" }.joined()
    return Data(joined.utf8)
}

// Split "[/ns,]..." -> (ns, rest)
func splitNSAndRest(_ slice: Substring) -> (String, String) {
    if slice.first == "/" {
        if let comma = slice.firstIndex(of: ",") {
            return (String(slice[..<comma]), String(slice[slice.index(after: comma)...]))
        }
        return (String(slice), "")
    }
    if slice.first == "," { return ("/", String(slice.dropFirst())) }
    return ("/", String(slice))
}

// Extract numeric id when exists before JSON
func splitIDAndJSON(_ s: String) -> (Int?, String) {
    var idStr = ""
    var i = s.startIndex
    while i < s.endIndex, s[i].isNumber { idStr.append(s[i]); i = s.index(after: i) }
    let id = Int(idStr)
    return (id, String(s[i...]))
}

// Replace placeholders {"_placeholder":true,"num":N} with attachments
func injectAttachments(jsonAny: Any, blobs: [Data]) -> Any {
    if let dict = jsonAny as? [String: Any], let ph = dict["_placeholder"] as? Bool, ph, let num = dict["num"] as? Int, num < blobs.count {
        return blobs[num]
    }
    if let dict = jsonAny as? [String: Any] {
        var out: [String: Any] = [:]
        for (k,v) in dict { out[k] = injectAttachments(jsonAny: v, blobs: blobs) }
        return out
    }
    if let arr = jsonAny as? [Any] { return arr.map { injectAttachments(jsonAny: $0, blobs: blobs) } }
    return jsonAny
}

// Walk JSON and replace Data with placeholders; returns (jsonWithPH, count)
func makePlaceholders(json: Any, attachments: [Data]) -> (Any, Int) {
    var idx = 0
    func walk(_ any: Any) -> Any {
        if any is Data { let i = idx; idx += 1; return ["_placeholder": true, "num": i] }
        if let d = any as? [String: Any] {
            var out: [String: Any] = [:]; d.forEach { out[$0] = walk($1) }; return out
        }
        if let a = any as? [Any] { return a.map { walk($0) } }
        return any
    }
    let replaced = walk(json)
    return (replaced, attachments.count)
}
