import Foundation

struct BinaryAssembler {
    struct Pending {
        let isAck: Bool
        let nsp: String
        let id: Int?
        let event: String
        var args: [Any]
        let expected: Int
        var attachments: [Data] = []
    }
    private(set) var queue: [Pending] = []

    mutating func startPacket(isAck: Bool, nsp: String, id: Int?, header: String, jsonArray: [Any]) -> Pending {
        let expected = countPlaceholders(in: jsonArray)
        let event = (jsonArray.first as? String) ?? ""
        let args = Array(jsonArray.dropFirst())
        let p = Pending(isAck: isAck, nsp: nsp, id: id, event: event, args: args, expected: expected)
        queue.append(p); return p
    }

    mutating func appendBinary(_ data: Data) -> (String, [Any])? {
        guard !queue.isEmpty else { return nil }
        queue[0].attachments.append(data)
        if queue[0].attachments.count == queue[0].expected {
            var args = queue[0].args
            for i in 0..<args.count { args[i] = replacePlaceholders(in: args[i], with: queue[0].attachments) }
            let ev = queue[0].event; queue.removeFirst()
            return (ev, args)
        }
        return nil
    }

    private func countPlaceholders(in value: Any) -> Int {
        if let dict = value as? [String:Any], (dict["_placeholder"] as? Bool) == true, dict["num"] is Int { return 1 }
        if let arr = value as? [Any] { return arr.map(countPlaceholders).reduce(0,+) }
        if let dict = value as? [String:Any] { return dict.values.map(countPlaceholders).reduce(0,+) }
        return 0
    }

    private func replacePlaceholders(in value: Any, with attachments: [Data]) -> Any {
        if let dict = value as? [String:Any], (dict["_placeholder"] as? Bool) == true, let num = dict["num"] as? Int, num < attachments.count { return attachments[num] }
        if var arr = value as? [Any] { for i in 0..<arr.count { arr[i] = replacePlaceholders(in: arr[i], with: attachments) }; return arr }
        if var dict = value as? [String:Any] { for (k,v) in dict { dict[k] = replacePlaceholders(in: v, with: attachments) }; return dict }
        return value
    }
}

struct BinaryEncoder {
    static func encode(event: String, args: Any) -> (header: String, arrayJSON: String, attachments: [Data])? {
        let (replaced, attachments) = extractDataAndReplace(value: args, collected: [])
        guard !attachments.isEmpty else { return nil }
        let array: [Any] = [event, replaced]
        let jsonData = try! JSONSerialization.data(withJSONObject: array, options: [])
        let jsonStr = String(data: jsonData, encoding: .utf8)!
        let header = String(attachments.count) + "-"
        return (header, jsonStr, attachments)
    }

    private static func extractDataAndReplace(value: Any, collected: [Data]) -> (Any, [Data]) {
        var attachments = collected
        if let d = value as? Data { let num = attachments.count; attachments.append(d); return (["_placeholder": true, "num": num], attachments) }
        if let arr = value as? [Any] {
            var out:[Any]=[]; var att = attachments
            for v in arr { let (nv, na) = extractDataAndReplace(value: v, collected: att); out.append(nv); att = na }
            return (out, att)
        }
        if let dict = value as? [String:Any] {
            var out:[String:Any]=[:]; var att = attachments
            for (k,v) in dict { let (nv, na) = extractDataAndReplace(value: v, collected: att); out[k]=nv; att=na }
            return (out, att)
        }
        return (value, attachments)
    }
}
