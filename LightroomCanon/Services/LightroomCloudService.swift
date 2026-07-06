import Foundation

/// Orchestrates the Firefly Services / Lightroom cloud "Auto Straighten"
/// pipeline: stage the photo in Azure Blob Storage (Adobe's API needs a
/// presigned URL to read from and write to — it hosts no storage of its own
/// for customer images), submit the job, poll until it finishes, then
/// download the corrected image.
///
/// This is a genuinely different code path from the on-device
/// `GeometryDetectionService`: that returns parameters (a `straighten` angle,
/// corner points) that stay inside the non-destructive `AdjustmentValues`
/// model, while this returns a finished, already-corrected image — see
/// `EditorView.runCloudStraighten()` for how the two are kept separate.
enum LightroomCloudService {
    enum UprightMode: String {
        case auto, level, vertical, full
    }

    private struct JobResponse: Decodable {
        struct Links: Decodable {
            struct Ref: Decodable { let href: String }
            let linkSelf: Ref
            enum CodingKeys: String, CodingKey { case linkSelf = "self" }
        }
        let _links: Links
    }

    private struct StatusResponse: Decodable {
        struct Output: Decodable { let status: String }
        let outputs: [Output]
    }

    /// Uploads `imageData`, runs Auto Straighten in `mode`, and returns the
    /// corrected image's data. Throws `CloudServiceError`, including
    /// `.notConfigured` if the Adobe/Azure credentials are still blank
    /// placeholders (see `AppConfig`).
    static func straighten(
        _ imageData: Data, mode: UprightMode, constrainCrop: Bool
    ) async throws -> Data {
        let id = UUID().uuidString
        let inputBlob = "\(id)-input.jpg"
        let outputBlob = "\(id)-output.jpg"

        guard let inputWriteURL = AzureBlobStorageService.sasURL(for: inputBlob, permission: .createWrite),
              let inputReadURL = AzureBlobStorageService.sasURL(for: inputBlob, permission: .read),
              let outputWriteURL = AzureBlobStorageService.sasURL(for: outputBlob, permission: .createWrite),
              let outputReadURL = AzureBlobStorageService.sasURL(for: outputBlob, permission: .read)
        else { throw CloudServiceError.notConfigured }

        defer {
            Task {
                await AzureBlobStorageService.delete(at: inputWriteURL)
                await AzureBlobStorageService.delete(at: outputWriteURL)
            }
        }

        try await AzureBlobStorageService.upload(imageData, to: inputWriteURL)

        let token = try await FireflyAuthService.shared.accessToken()
        let statusURL = try await submitJob(
            input: inputReadURL, output: outputWriteURL,
            mode: mode, constrainCrop: constrainCrop, token: token)

        try await pollUntilComplete(statusURL: statusURL, token: token)
        return try await AzureBlobStorageService.download(from: outputReadURL)
    }

    /// Directory where cloud-straightened override images live, keyed by
    /// photo id — mirrors `ThumbnailService.directory`.
    static var overrideDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("CloudStraightened", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func overrideURL(for filename: String) -> URL {
        overrideDirectory.appendingPathComponent(filename)
    }

    /// Writes `data` to disk for `photoID` and returns the stored filename,
    /// or `nil` on a write failure.
    static func saveOverride(_ data: Data, for photoID: UUID) -> String? {
        let filename = "\(photoID.uuidString).jpg"
        do {
            try data.write(to: overrideURL(for: filename), options: .atomic)
            return filename
        } catch {
            return nil
        }
    }

    private static func submitJob(
        input: URL, output: URL, mode: UprightMode, constrainCrop: Bool, token: String
    ) async throws -> URL {
        guard !AppConfig.Firefly.clientId.isEmpty, !AppConfig.Firefly.clientSecret.isEmpty else {
            throw CloudServiceError.notConfigured
        }

        var request = URLRequest(url: URL(string: "https://image.adobe.io/lrService/autoStraighten")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(AppConfig.Firefly.clientId, forHTTPHeaderField: "x-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let body: [String: Any] = [
            "inputs": ["href": input.absoluteString, "storage": "azure"],
            "options": ["uprightMode": mode.rawValue, "constrainCrop": constrainCrop],
            "outputs": [["href": output.absoluteString, "storage": "azure", "type": "image/jpeg"]],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw CloudServiceError.jobSubmissionFailed
        }
        let job = try JSONDecoder().decode(JobResponse.self, from: data)
        guard let url = URL(string: job._links.linkSelf.href) else {
            throw CloudServiceError.jobSubmissionFailed
        }
        return url
    }

    /// Polls the job's status URL with a short, fixed backoff — these jobs
    /// typically finish in a few seconds, and there's no webhook option for a
    /// client-only integration like this one.
    private static func pollUntilComplete(
        statusURL: URL, token: String, maxAttempts: Int = 30
    ) async throws {
        for _ in 0..<maxAttempts {
            var request = URLRequest(url: statusURL)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue(AppConfig.Firefly.clientId, forHTTPHeaderField: "x-api-key")

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
                throw CloudServiceError.jobFailed
            }
            let status = try JSONDecoder().decode(StatusResponse.self, from: data)
            if let outputStatus = status.outputs.first?.status {
                if outputStatus == "succeeded" { return }
                if outputStatus == "failed" { throw CloudServiceError.jobFailed }
            }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        throw CloudServiceError.jobFailed
    }
}
