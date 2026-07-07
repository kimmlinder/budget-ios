# Lightroom Canon

A native, non-destructive RAW photo editor for **iPhone and Mac**, built with
SwiftUI. It imports **Canon RAW** files (`.CR2` / `.CR3`), organizes them in a
library, and edits them with a Lightroom-style panel of tone, color, and crop
adjustments — all rendered live on the GPU with Metal + Core Image.

RAW decoding is handled by Apple's `CIRAWFilter`, which supports Canon sensors
natively, so there's no third-party decoder to bundle.

## Features (v1)

- **Library** — import Canon `.CR2`/`.CR3`, browse a thumbnail grid, view EXIF
  (camera, lens, ISO, shutter, aperture, date).
- **Non-destructive editing** — originals are never modified; edits are stored
  and re-applied at render time.
- **Light** — exposure, contrast, highlights, shadows, whites, blacks.
- **Presence** — texture, clarity, dehaze.
- **Color** — Black & White treatment, temperature (recognizes the camera's
  as-shot Kelvin, plus Daylight/Cloudy/Shade/Tungsten/Fluorescent/Flash
  presets), tint, vibrance, saturation.
- **Tone Curve** — a 5-point, draggable curve (shadows/quarter/mid/
  three-quarter/highlights), layered on top of whites/blacks.
- **HSL** — per-band Hue/Saturation/Luminance across 8 color bands (red,
  orange, yellow, green, aqua, blue, purple, magenta), via a custom Metal
  color kernel — see below.
- **Detail** — sharpening and noise reduction.
- **Lens Corrections** — distortion/vignette/CA correction, when the RAW has
  an embedded lens profile.
- **Geometry (Upright)** — Auto/Level/Vertical/Full/Guided perspective
  correction; see below for how each mode works.
- **Crop & rotate** — 90° rotation, straighten, aspect-ratio crop presets.
- **Presets** — save the current look and apply it to any photo.
- **Histogram** — live RGB histogram in the editor, updating with every edit.
- **Copy/paste edit settings** — copy one photo's full edit and paste it onto
  another, from the library grid's context menu or from within the editor.
- **Export** — JPEG or HEIC, with quality and long-edge size options.
- **One codebase** — the same app runs on iOS 17+ and macOS 14+.
- **iCloud sync** — scaffolded and off by default; see [iCloud sync](#icloud-sync-optional) below to turn it on.

## Requirements

- macOS with **Xcode 16** or newer.
- [XcodeGen](https://github.com/yonyz/XcodeGen) to generate the Xcode project
  from `project.yml`.

## Getting started

```bash
# 1. Install the project generator (once).
brew install xcodegen

# 2. From the repository root, generate the Xcode project.
xcodegen generate

# 3. Open it and run.
open LightroomCanon.xcodeproj
```

In Xcode, pick the **LightroomCanon (macOS)** scheme and run on *My Mac*, or the
**LightroomCanon (iOS)** scheme and run on a simulator or device. On first run,
use **Import** and select a Canon RAW file.

> The generated `.xcodeproj` is intentionally **not** committed (see
> `.gitignore`) — regenerate it with `xcodegen generate` after pulling changes
> to `project.yml`.

## Project layout

```
project.yml                 XcodeGen spec (targets, platforms, build settings)
LightroomCanon/
  App/                      App entry + SwiftData container
  Models/                   Photo, EditSettings, Preset (SwiftData) + AdjustmentValues
  Services/
    RenderEngine.swift      Shared Metal-backed CIContext
    RAWProcessor.swift      Core Image pipeline (the editing engine)
    ImportService.swift     File import, bookmarks, EXIF extraction
    ThumbnailService.swift  Thumbnail generation + caching
    ExportService.swift     Full-res render to JPEG/HEIC
    HistogramService.swift  RGB histogram bin computation
    EditClipboard.swift     Session-scoped copy/paste edit-settings clipboard
    GeometryDetectionService.swift  Vision-based horizon/rectangle detection
    GuidedGeometry.swift    Turns drawn guide lines into a correction quad
    AutoCropService.swift   Largest-inscribed-rectangle crop after Upright
    HSLKernel.swift         Custom Metal color kernel for 8-band HSL

    Texture/Clarity/Dehaze/B&W live directly in RAWProcessor.swift.
  Views/                    LibraryView, EditorView, MetalImageView, sliders…
  Resources/Assets.xcassets App icon + accent color
  LightroomCanon.entitlements  iCloud/CloudKit template (inert until wired up)
```

## How editing works

`RAWProcessor` builds a lazy Core Image graph per photo:

1. `CIRAWFilter` decodes the Canon RAW and applies exposure, white balance,
   and (when the file has a lens profile) distortion/vignette/CA correction.
2. Standard `CIFilter`s add contrast, highlights/shadows, whites/blacks,
   texture/clarity/dehaze, the tone curve, and vibrance/saturation, then a
   custom Metal kernel applies per-band HSL, then Black & White (if enabled),
   then noise reduction and sharpening.
3. Geometry (straighten → Upright correction → crop → rotate) is applied last.

The graph is rendered to the screen by `MetalImageView` (an `MTKView`) at
display resolution, which is what keeps slider dragging responsive. Export
re-runs the same graph at full resolution.

## Geometry (Upright)

Five modes, matching Lightroom's Transform panel:

- **Level** — detects the photo's horizon tilt (`VNDetectHorizonRequest`) and
  sets Straighten to match. Robust for any photo with a discernible horizon.
- **Guided** — drag on the preview to draw 2 vertical and/or 2 horizontal
  lines along edges that should be straight; `CIKeystoneCorrectionVertical` /
  `Horizontal` / `Combined` warps the quad those lines describe into a
  rectangle. This is the most reliable mode for architectural shots, since
  you're telling it exactly what should be straight. While guides are being
  placed, the preview shows the *uncorrected* image so the lines stay glued
  to the real content — the corrected result appears once you switch away
  from Guided.
- **Vertical** / **Full** / **Auto** — Apple doesn't expose the vanishing-point
  detection Lightroom's Upright uses internally, so these approximate it:
  `VNDetectRectanglesRequest` finds the most prominent rectangle in frame and
  squares it up (Vertical → `CIKeystoneCorrectionVertical`, Full/Auto →
  `CIKeystoneCorrectionCombined`; Auto also runs Level). This works well when
  there's a clear rectangular subject (a building facade, a door, a screen)
  and does nothing when there isn't — the panel shows a note when detection
  finds nothing, and suggests Guided instead.

`RAWProcessor` only ever looks at `geometryCorrectionKind` +
`geometryCorners` (a resolved 4-point quad) to decide what to render — it
doesn't care whether those came from Guided lines or a Vision detector, which
keeps the render path simple regardless of which mode produced them.

Keystone correction doesn't crop the result itself — the warped-away corners
render fully transparent (verified empirically: alpha 0). `AutoCropService`
takes advantage of that: it rasterizes the corrected image's alpha channel at
low resolution and finds the largest axis-aligned fully-opaque rectangle with
a standard maximal-rectangle-in-a-binary-matrix algorithm, then sets the crop
to it automatically. This runs after every successful Vertical/Full/Auto
detection and after Guided lines resolve to a correction; a per-photo
"Auto-crop ragged corners" toggle (on by default) turns it off if you'd rather
crop by hand.

## HSL

Core Image has no built-in per-band HSL filter, so `HSLKernel` compiles a
small stitchable Metal color kernel at runtime (via
`CIKernel.kernels(withMetalString:)` — no `.metal` file or build-phase
wiring needed). For a pixel's hue, it finds the two nearest of the 8
evenly-spaced band centers and linearly blends their (hue, saturation,
luminance) offsets — a partition-of-unity by construction, so band-to-band
transitions are smooth with no double-counting or gaps at the seams.
Verified against a real photo: pushing only the Green band's saturation up
and luminance down darkens and intensifies foliage while leaving the sky and
stone completely untouched.

## Presence (Texture, Clarity, Dehaze)

Texture and Clarity are both `CIUnsharpMask` — local contrast at two
different spatial scales, each scaled to the image's own size so the effect
is resolution-independent: a small radius (~0.4% of the image's long edge)
for Texture, a large one (~2%) for Clarity. `CIUnsharpMask`'s intensity
doesn't go negative (verified empirically — below 0 it's a no-op), so
negative Texture/Clarity instead dissolve toward a same-radius Gaussian blur
for genuine softening.

Dehaze has no Core Image equivalent — there's no public dark-channel-prior
filter to reach for — so it's an approximation: positive values add local
contrast, crush the black point, and nudge saturation up, the combination
that *reads* as cutting through haze even though it isn't modeling
atmospheric scattering. Negative values do the reverse for a soft, hazy look.
Black & White is a plain desaturation applied after HSL, so HSL's per-band
Luminance sliders double as a basic B&W Mix.

## Notes & limitations

- The app uses **local development signing** and is **not sandboxed**, so it
  builds and runs without a paid Apple Developer account. For App Store or
  TestFlight distribution you'll need to add an App Sandbox entitlement (with
  user-selected file access) and a signing team.
- Highlight *recovery* works via `CIHighlightShadowAdjust`; positive
  "highlights" (brightening) is limited in v1 — see the roadmap.

## iCloud sync (optional)

The SwiftData store is already structured for CloudKit (see
`LightroomCanonApp.swift`), but it's **off by default** so the app keeps
building and running under local development signing with no paid Apple
Developer account. To turn it on:

1. Get a paid Apple Developer Program membership and set `DEVELOPMENT_TEAM`
   in `project.yml` to your team ID.
2. Create an iCloud container (e.g. `iCloud.com.example.LightroomCanon`) at
   developer.apple.com → Certificates, Identifiers & Profiles, and update the
   identifier in `LightroomCanon/LightroomCanon.entitlements` to match.
3. In `project.yml`, uncomment the `CODE_SIGN_ENTITLEMENTS` line pointing at
   that entitlements file.
4. Flip `AppConfig.iCloudSyncEnabled` to `true`.
5. Run `xcodegen generate` and rebuild.

Without these steps, `LightroomCanon.entitlements` sits unused in the source
tree and has no effect on the build.

## Roadmap

Local adjustments / masking and a healing & clone tool. The
`AdjustmentValues` model and `RAWProcessor` chain are structured so these slot
in without reworking the core.
