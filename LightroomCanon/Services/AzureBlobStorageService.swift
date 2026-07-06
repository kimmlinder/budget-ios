import CryptoKit
import Foundation

/// Generates Shared Access Signature (SAS) URLs for Azure Blob Storage and
/// performs the PUT/GET/DELETE calls the Lightroom cloud pipeline needs to
/// stage images there. See `AppConfig.CloudStorage` for the account this
/// reads from.
///
/// Implements Azure's service-SAS (blob) signing algorithm for storage
/// service version 2020-12-06 directly — HMAC-SHA256 over a canonicalized
/// string — since there's no first-party Azure SDK for Swift covering this.
enum AzureBlobStorageService {
    private static let apiVersion = "2020-12-06"

    enum Permission: String {
        case read = "r"
        case createWrite = "cw"
        case delete = "d"
    }

    /// A presigned URL for `blobName` in the configured container, valid for
    /// `validFor` (default 1 hour — a single cloud-straighten round trip only
    /// needs a few minutes of this). `nil` if storage isn't configured.
    static func sasURL(
        for blobName: String, permission: Permission, validFor: TimeInterval = 3600
    ) -> URL? {
        guard !AppConfig.CloudStorage.accountName.isEmpty,
              !AppConfig.CloudStorage.accountKey.isEmpty,
              let keyData = Data(base64Encoded: AppConfig.CloudStorage.accountKey)
        else { return nil }

        let account = AppConfig.CloudStorage.accountName
        let container = AppConfig.CloudStorage.containerName

        let expiry = isoFormatter.string(from: Date().addingTimeInterval(validFor))
        // "/blob/{account}/{container}/{blob}" — Azure's canonicalized
        // resource form for a blob-level service SAS.
        let canonicalizedResource = "/blob/\(account)/\(container)/\(blobName)"

        // Field order and count are fixed by Azure's spec for this storage
        // version: permissions, start, expiry, resource, identifier, IP,
        // protocol, version, signedResource, snapshotTime, encryptionScope,
        // then the five response-header overrides (all unused here).
        let stringToSign = [
            permission.rawValue, "", expiry, canonicalizedResource, "", "", "https",
            apiVersion, "b", "", "", "", "", "", "", "",
        ].joined(separator: "\n")

        let signature = HMAC<SHA256>.authenticationCode(
            for: Data(stringToSign.utf8), using: SymmetricKey(data: keyData))
        let signatureBase64 = Data(signature).base64EncodedString()

        guard let baseURL = URL(string: "https://\(account).blob.core.windows.net/\(container)/\(blobName)"),
              var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        else { return nil }
        components.queryItems = [
            URLQueryItem(name: "sv", value: apiVersion),
            URLQueryItem(name: "sr", value: "b"),
            URLQueryItem(name: "sp", value: permission.rawValue),
            URLQueryItem(name: "se", value: expiry),
            URLQueryItem(name: "spr", value: "https"),
            URLQueryItem(name: "sig", value: signatureBase64),
        ]
        return components.url
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func upload(_ data: Data, to url: URL) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("BlockBlob", forHTTPHeaderField: "x-ms-blob-type")
        request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw CloudServiceError.uploadFailed
        }
    }

    static func download(from url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw CloudServiceError.downloadFailed
        }
        return data
    }

    /// Best-effort cleanup of a staging blob after a job finishes — a failure
    /// here doesn't affect the user-visible result, so this doesn't throw.
    static func delete(at url: URL) async {
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        _ = try? await URLSession.shared.data(for: request)
    }
}
