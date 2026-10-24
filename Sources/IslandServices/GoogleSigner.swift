import Foundation
import IslandCore
import Security

/// Signs Google service-account JWTs with RS256 and swaps them for access tokens.
public enum GoogleSigner {
    public enum SignError: LocalizedError {
        case badKey, signing, token(String)

        public var errorDescription: String? {
            switch self {
            case .badKey: return "That service-account key can't be read."
            case .signing: return "Couldn't sign the request with that key."
            case .token(let message): return message
            }
        }
    }

    public static func signedJWT(_ account: GoogleAnalytics.ServiceAccount, now: Date = Date()) throws -> String {
        guard let der = GoogleAnalytics.der(fromPEM: account.privateKeyPEM) else { throw SignError.badKey }
        let pkcs1 = GoogleAnalytics.pkcs1(fromPKCS8: der) ?? der
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeyClass as String: kSecAttrKeyClassPrivate]
        guard let key = SecKeyCreateWithData(pkcs1 as CFData, attributes as CFDictionary, nil) else { throw SignError.badKey }
        let unsigned = GoogleAnalytics.unsignedJWT(account: account, now: now)
        guard let signature = SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, Data(unsigned.utf8) as CFData, nil) as Data? else {
            throw SignError.signing
        }
        return unsigned + "." + GoogleAnalytics.base64URL(signature)
    }

    /// An access token for the Analytics Data API, valid for about an hour.
    public static func accessToken(_ account: GoogleAnalytics.ServiceAccount) async throws -> (token: String, expires: Date) {
        let jwt = try signedJWT(account)
        var request = URLRequest(url: URL(string: account.tokenURI)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer&assertion=\(jwt)".utf8)
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let token = json["access_token"] as? String else {
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            throw SignError.token((json?["error_description"] as? String) ?? "Google didn't accept that key.")
        }
        let seconds = (json["expires_in"] as? NSNumber)?.doubleValue ?? 3600
        return (token, Date().addingTimeInterval(seconds - 60))
    }
}
