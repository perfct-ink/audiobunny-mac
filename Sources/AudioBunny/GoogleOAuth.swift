import AppKit
import AuthenticationServices
import CryptoKit
import Foundation

// No official macOS (AppKit) Google Sign-In SDK exists — GoogleSignIn-iOS is
// iOS/macCatalyst only. This does a plain PKCE authorization-code flow via
// ASWebAuthenticationSession against a Google OAuth client registered to
// accept the "audiobunny://oauth-callback/google" redirect (see Info.plist).
//
// Needs GoogleOAuthClientID / GoogleOAuthClientSecret set in Info.plist.
// Unlike Apple, Google's code exchange for this client type does require a
// client secret in the request body (Google states it isn't treated as
// confidential for installed apps, but the field is required).
enum GoogleOAuthError: LocalizedError {
    case notConfigured
    case missingCode
    case missingIdToken

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Google sign-in is not configured"
        case .missingCode: return "Google did not return an authorization code"
        case .missingIdToken: return "Google did not return an identity token"
        }
    }
}

enum GoogleOAuth {
    private static let redirectURI = "audiobunny://oauth-callback/google"
    private static let scheme = "audiobunny"

    static func signIn() async throws -> String {
        guard
            let clientID = Bundle.main.object(forInfoDictionaryKey: "GoogleOAuthClientID") as? String,
            let clientSecret = Bundle.main.object(forInfoDictionaryKey: "GoogleOAuthClientSecret") as? String,
            !clientID.isEmpty, !clientSecret.isEmpty
        else {
            throw GoogleOAuthError.notConfigured
        }

        let verifier = Self.codeVerifier()
        let challenge = Self.codeChallenge(for: verifier)
        let authURL = Self.authorizationURL(clientID: clientID, codeChallenge: challenge)

        let callbackURL = try await Self.presentSession(url: authURL)
        guard let code = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "code" })?.value
        else {
            throw GoogleOAuthError.missingCode
        }

        return try await Self.exchangeCode(code, verifier: verifier, clientID: clientID, clientSecret: clientSecret)
    }

    private static func authorizationURL(clientID: String, codeChallenge: String) -> URL {
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "openid email"),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        return components.url!
    }

    private static func exchangeCode(_ code: String, verifier: String, clientID: String, clientSecret: String) async throws -> String {
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let params = [
            "client_id": clientID,
            "client_secret": clientSecret,
            "code": code,
            "code_verifier": verifier,
            "redirect_uri": redirectURI,
            "grant_type": "authorization_code",
        ]
        req.httpBody = params
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, _) = try await URLSession.shared.data(for: req)
        struct TokenResponse: Decodable { let idToken: String?
            enum CodingKeys: String, CodingKey { case idToken = "id_token" }
        }
        guard let idToken = try JSONDecoder().decode(TokenResponse.self, from: data).idToken else {
            throw GoogleOAuthError.missingIdToken
        }
        return idToken
    }

    @MainActor
    private static func presentSession(url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme) { callbackURL, error in
                if let callbackURL {
                    continuation.resume(returning: callbackURL)
                } else {
                    continuation.resume(throwing: error ?? GoogleOAuthError.missingCode)
                }
            }
            session.presentationContextProvider = Self.contextProvider
            session.prefersEphemeralWebBrowserSession = true
            session.start()
        }
    }

    private static func codeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncodedString()
    }

    private static func codeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64URLEncodedString()
    }

    private static let contextProvider = PresentationContextProvider()
}

private final class PresentationContextProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApplication.shared.windows.first ?? ASPresentationAnchor()
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
