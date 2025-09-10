import Foundation
import Security
#if canImport(CryptoKit)
import CryptoKit
#endif

public final class DefaultSecurityPolicy: NSObject, SecurityEvaluating {
    public enum Pin {
        case none
        case certificates([Data])
        case spki([Data])
    }
    private let pin: Pin
    public init(pin: Pin) { self.pin = pin }

    public func evaluate(challenge: URLAuthenticationChallenge, for host: String)
      -> (disposition: URLSession.AuthChallengeDisposition, credential: URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            return (.performDefaultHandling, nil)
        }

        var error: CFError?
        guard SecTrustEvaluateWithError(trust, &error) else { return (.cancelAuthenticationChallenge, nil) }

        switch pin {
        case .none:
            return (.useCredential, URLCredential(trust: trust))

        case .certificates(let pinned):
            if let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first {
                let data = SecCertificateCopyData(leaf) as Data
                if pinned.contains(data) {
                    return (.useCredential, URLCredential(trust: trust))
                }
            }
            return (.cancelAuthenticationChallenge, nil)

        case .spki(let pinnedHashes):
            if let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first,
               let spki = DefaultSecurityPolicy.spkiHash(for: leaf),
               pinnedHashes.contains(spki) {
                return (.useCredential, URLCredential(trust: trust))
            }
            return (.cancelAuthenticationChallenge, nil)
        }
    }

    public static func loadCerts(named names: [String], in bundle: Bundle = .main) -> [Data] {
        names.compactMap { name in
            guard let url = bundle.url(forResource: name, withExtension: "cer"),
                  let data = try? Data(contentsOf: url) else { return nil }
            return data
        }
    }

    public static func spkiHash(for cert: SecCertificate) -> Data? {
        guard let key = SecCertificateCopyKey(cert),
              let pkData = SecKeyCopyExternalRepresentation(key, nil) as Data? else { return nil }
        #if canImport(CryptoKit)
        return Data(SHA256.hash(data: pkData))
        #else
        return nil
        #endif
    }
}
