import SwiftUI

/// Small shims so the rest of the UI can stay platform-agnostic.
#if os(macOS)
import AppKit
typealias PlatformImage = NSImage
#else
import UIKit
typealias PlatformImage = UIImage
#endif

extension Image {
    /// Load a SwiftUI `Image` from a file on disk, or `nil` if it can't be read.
    init?(contentsOfFile url: URL) {
        #if os(macOS)
        guard let img = NSImage(contentsOf: url) else { return nil }
        self = Image(nsImage: img)
        #else
        guard let img = UIImage(contentsOfFile: url.path) else { return nil }
        self = Image(uiImage: img)
        #endif
    }
}
