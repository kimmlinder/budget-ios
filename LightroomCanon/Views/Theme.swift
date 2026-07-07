import SwiftUI

/// Design tokens lifted from the reference dark-room-style editor mockup at
/// https://jargon-thorn-99651647.figma.site (colors sampled directly from
/// its rendered screenshots): a near-black canvas, a slightly lighter
/// charcoal for panels/sidebars, and a warm amber accent used for active
/// tabs/buttons/ratings/slider fills in place of the system default blue
/// (see `AccentColor` in the asset catalog, set to the same amber).
enum Theme {
    /// The main preview/canvas area — near-black, darker than `panelBackground`
    /// so the photo itself reads as the brightest thing on screen.
    static let canvasBackground = Color(red: 17 / 255, green: 17 / 255, blue: 19 / 255)

    /// Sidebars, the adjustments panel, the histogram card — one step up
    /// from `canvasBackground` so panel chrome reads as distinct from the
    /// photo without competing with it.
    static let panelBackground = Color(red: 22 / 255, green: 22 / 255, blue: 24 / 255)

    /// Inactive pill/segment backgrounds (e.g. an unselected tab).
    static let controlBackground = Color(red: 82 / 255, green: 82 / 255, blue: 84 / 255)

    /// The warm amber/gold accent — active tabs, primary buttons, star
    /// ratings, and (via `AdjustmentSlider`) the filled portion of a slider
    /// track when its value is off-neutral.
    static let accent = Color(red: 216 / 255, green: 150 / 255, blue: 66 / 255)
}
