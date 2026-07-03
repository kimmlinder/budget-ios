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
- **Color** — temperature, tint, vibrance, saturation.
- **Crop & rotate** — 90° rotation, straighten, aspect-ratio crop presets.
- **Presets** — save the current look and apply it to any photo.
- **Export** — JPEG or HEIC, with quality and long-edge size options.
- **One codebase** — the same app runs on iOS 17+ and macOS 14+.

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
  Views/                    LibraryView, EditorView, MetalImageView, sliders…
  Resources/Assets.xcassets App icon + accent color
```

## How editing works

`RAWProcessor` builds a lazy Core Image graph per photo:

1. `CIRAWFilter` decodes the Canon RAW and applies exposure + white balance.
2. Standard `CIFilter`s add contrast, highlights/shadows, whites/blacks,
   vibrance/saturation.
3. Geometry (straighten → crop → rotate) is applied last.

The graph is rendered to the screen by `MetalImageView` (an `MTKView`) at
display resolution, which is what keeps slider dragging responsive. Export
re-runs the same graph at full resolution.

## Notes & limitations

- The app uses **local development signing** and is **not sandboxed**, so it
  builds and runs without a paid Apple Developer account. For App Store or
  TestFlight distribution you'll need to add an App Sandbox entitlement (with
  user-selected file access) and a signing team.
- Highlight *recovery* works via `CIHighlightShadowAdjust`; positive
  "highlights" (brightening) is limited in v1 — see the roadmap.

## Roadmap

Local adjustments / masking, healing & clone, per-channel HSL, a tone-curve
editor, detail (sharpening / noise reduction), lens & geometry corrections,
histogram, copy/paste settings between photos, and iCloud/CloudKit sync between
iPhone and Mac. The `AdjustmentValues` model and `RAWProcessor` chain are
structured so these slot in without reworking the core.
```
