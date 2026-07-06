import Foundation

/// App-wide feature flags that depend on account/provisioning setup rather
/// than code readiness.
enum AppConfig {
    /// Whether the SwiftData store syncs through CloudKit.
    ///
    /// Off by default so the app keeps building and running with **local
    /// development signing and no paid Apple Developer account** — the
    /// baseline this project targets (see README.md). CloudKit requires an
    /// iCloud container and the Push Notifications capability, both of which
    /// Apple restricts to paid Developer Program accounts.
    ///
    /// To turn this on:
    /// 1. Get a paid Apple Developer Program membership and set `DEVELOPMENT_TEAM`
    ///    in `project.yml` to your team ID.
    /// 2. Create an iCloud container (e.g. `iCloud.com.example.LightroomCanon`)
    ///    in developer.apple.com → Certificates, Identifiers & Profiles.
    /// 3. In `project.yml`, add `CODE_SIGN_ENTITLEMENTS: LightroomCanon/LightroomCanon.entitlements`
    ///    to the target's settings, and update the container identifier inside
    ///    `LightroomCanon.entitlements` to match step 2.
    /// 4. Flip this flag to `true`.
    /// 5. Run `xcodegen generate` and rebuild.
    static let iCloudSyncEnabled = false

    /// Adobe Developer Console OAuth Server-to-Server credentials for
    /// Firefly Services (Lightroom APIs), used by `LightroomCloudService`
    /// for the optional "Cloud Straighten" action.
    ///
    /// **Development placeholder only.** Anything embedded here ships inside
    /// the app binary and can be extracted by anyone who downloads it. Before
    /// distributing this app, delete these constants and move token minting
    /// behind a backend proxy that holds the real secret and returns only a
    /// short-lived access token to the client.
    enum Firefly {
        static let clientId = ""
        static let clientSecret = ""
    }

    /// Azure Blob Storage account used to stage images for the Lightroom
    /// cloud API — Adobe's API requires the source/output to be reachable via
    /// a presigned URL, and provides no storage of its own for arbitrary
    /// customer images, so the caller supplies its own (S3/Azure/Dropbox/etc).
    ///
    /// **Development placeholder only** — same caveat as `Firefly` above: the
    /// account key lets anyone forge SAS tokens for this account. Move SAS
    /// signing server-side before distributing this app.
    enum CloudStorage {
        static let accountName = ""
        static let accountKey = ""
        static let containerName = "lightroom-canon-staging"
    }
}
