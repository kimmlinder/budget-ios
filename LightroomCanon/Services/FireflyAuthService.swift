import Foundation

/// Mints and caches OAuth Server-to-Server access tokens for Adobe Firefly
/// Services (the Lightroom cloud APIs), via Adobe IMS's client-credentials
/// grant.
///
/// See `AppConfig.Firefly` for the security caveat about where these
/// credentials should actually live.
actor FireflyAuthService {
    static let shared = FireflyAuthService()

    private struct TokenResponse: Decodable {
        let access_token: String
        let expires_in: Int
    }

    private var cachedToken: String?
    private var expiresAt: Date = .distantPast

    /// A valid bearer token, reusing the cached one until shortly before it
    /// expires (Adobe tokens are valid 24h, so this rarely round-trips).
    func accessToken() async throws -> String {
        if let cachedToken, Date() < expiresAt {
            return cachedToken
        }

        var request = URLRequest(url: URL(string: "https://ims-na1.adobelogin.com/ims/token/v3")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "grant_type", value: "client_credentials"),
            URLQueryItem(name: "client_id", value: AppConfig.Firefly.clientId),
            URLQueryItem(name: "client_secret", value: AppConfig.Firefly.clientSecret),
            URLQueryItem(name: "scope", value: "openid,AdobeID,read_organizations"),
        ]
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw CloudServiceError.authenticationFailed
        }
        let token = try JSONDecoder().decode(TokenResponse.self, from: data)

        cachedToken = token.access_token
        // Refresh a couple minutes early rather than cutting it exactly at expiry.
        expiresAt = Date().addingTimeInterval(TimeInterval(token.expires_in - 120))
        return token.access_token
    }
}

/// Errors surfaced by the Firefly/Lightroom cloud pipeline, shown to the user
/// as a single alert message in `EditorView`.
enum CloudServiceError: LocalizedError {
    case renderFailed
    case authenticationFailed
    case uploadFailed
    case jobSubmissionFailed
    case jobFailed
    case downloadFailed
    case notConfigured

    var errorDescription: String? {
        switch self {
        case .renderFailed: return "Couldn't render this photo at full resolution."
        case .authenticationFailed: return "Couldn't authenticate with Adobe's Lightroom API."
        case .uploadFailed: return "Couldn't upload the photo to staging storage."
        case .jobSubmissionFailed: return "Couldn't start the cloud straighten job."
        case .jobFailed: return "Adobe's Lightroom API couldn't straighten this photo."
        case .downloadFailed: return "Couldn't download the straightened photo."
        case .notConfigured: return "Cloud Straighten isn't configured yet — add Adobe and Azure credentials to AppConfig."
        }
    }
}
