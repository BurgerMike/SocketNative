import Foundation

struct OpenPayload: Decodable {
    let sid: String
    let pingInterval: TimeInterval?
    let pingTimeout: TimeInterval?
    let upgrades: [String]?
}
