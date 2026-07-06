import Foundation

/// Parses Adobe Camera Raw XMP preset files (the `.xmp` sidecars Lightroom
/// presets are distributed as) into this app's `AdjustmentValues`.
///
/// Maps the Basic + Detail panel equivalents this app already has sliders
/// for, plus the master and per-channel Tone Curves, Calibration, HSL, and
/// Color Grading/Split Toning — all flat `crs:` scalar attributes (e.g.
/// `crs:RedHue`, `crs:HueAdjustmentRed`, `crs:ColorGradeShadowHue`),
/// confirmed against a real exported preset. `crs:CameraProfile` names a
/// camera profile but doesn't carry the actual profile/LUT table (that lives
/// in a separate, proprietary `.dcp` file Adobe ships separately) — there's
/// no data here to apply even if we read the name, so it's ignored.
enum XMPPresetParser {
    enum XMPError: LocalizedError {
        case invalidXML
        case noSettingsFound

        var errorDescription: String? {
            switch self {
            case .invalidXML: return "This .xmp file couldn't be parsed."
            case .noSettingsFound: return "This .xmp file doesn't contain any recognizable Develop settings."
            }
        }
    }

    /// Parses `data` (the raw contents of one `.xmp` file) into
    /// `AdjustmentValues`, starting from `.neutral` and overwriting only the
    /// fields this XMP actually specifies. Fields outside our own slider
    /// ranges are clamped rather than rejected, since Adobe's scales don't
    /// all match ours 1:1 (e.g. `Exposure2012` is raw EV; ours is -100...100
    /// representing ±5 EV).
    static func parse(_ data: Data) throws -> AdjustmentValues {
        let delegate = XMPParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else { throw XMPError.invalidXML }
        guard !delegate.fields.isEmpty || !delegate.curves.isEmpty else { throw XMPError.noSettingsFound }

        var values = AdjustmentValues.neutral
        let f = delegate.fields

        if let v = f["Exposure2012"] { values.exposure = clamp(v * 20, -100, 100) }
        if let v = f["Contrast2012"] { values.contrast = clamp(v, -100, 100) }
        if let v = f["Highlights2012"] { values.highlights = clamp(v, -100, 100) }
        if let v = f["Shadows2012"] { values.shadows = clamp(v, -100, 100) }
        if let v = f["Whites2012"] { values.whites = clamp(v, -100, 100) }
        if let v = f["Blacks2012"] { values.blacks = clamp(v, -100, 100) }
        if let v = f["Texture"] { values.texture = clamp(v, -100, 100) }
        if let v = f["Clarity2012"] { values.clarity = clamp(v, -100, 100) }
        if let v = f["Dehaze"] { values.dehaze = clamp(v, -100, 100) }
        if let v = f["Temperature"] { values.temperature = v }
        if let v = f["Tint"] { values.tint = clamp(v, -100, 100) }
        if let v = f["Vibrance"] { values.vibrance = clamp(v, -100, 100) }
        if let v = f["Saturation"] { values.saturation = clamp(v, -100, 100) }
        if let v = f["Sharpness"] { values.sharpness = clamp(v, 0, 100) }
        if let v = f["LuminanceSmoothing"] { values.noiseReduction = clamp(v, 0, 100) }

        if let v = f["RedHue"] { values.redHue = clamp(v, -100, 100) }
        if let v = f["RedSaturation"] { values.redSaturation = clamp(v, -100, 100) }
        if let v = f["GreenHue"] { values.greenHue = clamp(v, -100, 100) }
        if let v = f["GreenSaturation"] { values.greenSaturation = clamp(v, -100, 100) }
        if let v = f["BlueHue"] { values.blueHue = clamp(v, -100, 100) }
        if let v = f["BlueSaturation"] { values.blueSaturation = clamp(v, -100, 100) }

        // A preset signals Black & White by referencing Adobe's Monochrome
        // camera profile in its embedded `crs:Look`, not a plain boolean —
        // confirmed against real presets (there's no `ConvertToGrayscale`
        // attribute; the only signal is `crs:Look/rdf:Description`'s
        // `crs:Name`, e.g. "Adobe Monochrome").
        if let profileName = delegate.lookProfileName,
           profileName.localizedCaseInsensitiveContains("Monochrome") {
            values.isBlackAndWhite = true
        }

        for band in HSLColorBand.allCases {
            let name = band.label.replacingOccurrences(of: " ", with: "")
            var bandValues = values.hslBands[band.rawValue]
            if let v = f["HueAdjustment\(name)"] { bandValues.hue = clamp(v, -100, 100) }
            if let v = f["SaturationAdjustment\(name)"] { bandValues.saturation = clamp(v, -100, 100) }
            if let v = f["LuminanceAdjustment\(name)"] { bandValues.luminance = clamp(v, -100, 100) }
            // The B&W Mix panel's per-channel field, `crs:GrayMixer*` —
            // same slot as `LuminanceAdjustment*` (this app's B&W Mix is the
            // HSL Luminance sliders doing double duty, see
            // `RAWProcessor.applyBlackAndWhite`), so it overrides that value
            // when both happen to be present since it's the more specific,
            // monochrome-authored one.
            if let v = f["GrayMixer\(name)"] { bandValues.luminance = clamp(v, -100, 100) }
            values.hslBands[band.rawValue] = bandValues
        }

        // Color Grading (modern) takes priority; Split Toning (legacy —
        // Shadow/Highlight only, no Midtone wheel) is used per-zone only
        // when the modern field for that same zone is absent. Real presets
        // often emit both for backward compatibility, with Color Grade
        // being the authoritative modern data.
        if let v = f["ColorGradeShadowHue"] { values.colorGradeShadowHue = normalizeHue(v) }
        if let v = f["ColorGradeShadowSat"] { values.colorGradeShadowSaturation = clamp(v, 0, 100) }
        if let v = f["ColorGradeShadowLum"] { values.colorGradeShadowLuminance = clamp(v, -100, 100) }
        if let v = f["ColorGradeMidtoneHue"] { values.colorGradeMidtoneHue = normalizeHue(v) }
        if let v = f["ColorGradeMidtoneSat"] { values.colorGradeMidtoneSaturation = clamp(v, 0, 100) }
        if let v = f["ColorGradeMidtoneLum"] { values.colorGradeMidtoneLuminance = clamp(v, -100, 100) }
        if let v = f["ColorGradeHighlightHue"] { values.colorGradeHighlightHue = normalizeHue(v) }
        if let v = f["ColorGradeHighlightSat"] { values.colorGradeHighlightSaturation = clamp(v, 0, 100) }
        if let v = f["ColorGradeHighlightLum"] { values.colorGradeHighlightLuminance = clamp(v, -100, 100) }
        if let v = f["ColorGradeGlobalHue"] { values.colorGradeGlobalHue = normalizeHue(v) }
        if let v = f["ColorGradeGlobalSat"] { values.colorGradeGlobalSaturation = clamp(v, 0, 100) }
        if let v = f["ColorGradeGlobalLum"] { values.colorGradeGlobalLuminance = clamp(v, -100, 100) }
        if let v = f["ColorGradeBlending"] { values.colorGradeBlending = clamp(v, 0, 100) }

        if f["ColorGradeShadowHue"] == nil, let v = f["SplitToningShadowHue"] {
            values.colorGradeShadowHue = normalizeHue(v)
        }
        if f["ColorGradeShadowSat"] == nil, let v = f["SplitToningShadowSaturation"] {
            values.colorGradeShadowSaturation = clamp(v, 0, 100)
        }
        if f["ColorGradeHighlightHue"] == nil, let v = f["SplitToningHighlightHue"] {
            values.colorGradeHighlightHue = normalizeHue(v)
        }
        if f["ColorGradeHighlightSat"] == nil, let v = f["SplitToningHighlightSaturation"] {
            values.colorGradeHighlightSaturation = clamp(v, 0, 100)
        }
        if let v = f["SplitToningBalance"] { values.colorGradeBalance = clamp(v, -100, 100) }

        if let points = delegate.curves["ToneCurvePV2012"], let curve = sampleCurve(points) {
            values.toneCurve = curve
        }
        // The Tone Curve panel's *region* sliders — a separate shaping
        // mechanism from the explicit point curve above, which Lightroom
        // combines with it into one final curve. Our fixed 5 x-positions
        // (0, .25, .5, .75, 1) happen to line up with Adobe's *default*
        // region split points (0/25/50/75/100), so this folds each slider's
        // contribution onto the nearest matching point(s) as an additive
        // delta — a reasonable approximation only when a preset uses those
        // default splits (`ParametricShadowSplit`/`MidtoneSplit`/
        // `HighlightSplit`, not parsed here); a customized split position
        // would shift where each slider's influence actually falls.
        values.toneCurve = applyParametricCurve(
            to: values.toneCurve,
            shadows: f["ParametricShadows"] ?? 0, darks: f["ParametricDarks"] ?? 0,
            lights: f["ParametricLights"] ?? 0, highlights: f["ParametricHighlights"] ?? 0)
        if let points = delegate.curves["ToneCurvePV2012Red"], let curve = sampleCurve(points) {
            values.redToneCurve = curve
        }
        if let points = delegate.curves["ToneCurvePV2012Green"], let curve = sampleCurve(points) {
            values.greenToneCurve = curve
        }
        if let points = delegate.curves["ToneCurvePV2012Blue"], let curve = sampleCurve(points) {
            values.blueToneCurve = curve
        }

        return values
    }

    private static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
        min(max(v, lo), hi)
    }

    private static func normalizeHue(_ v: Double) -> Double {
        let r = v.truncatingRemainder(dividingBy: 360)
        return r < 0 ? r + 360 : r
    }

    /// Folds the Tone Curve panel's region sliders onto `curve`'s 5 points as
    /// an additive delta — see the call site in `parse()` for why this only
    /// approximates presets using Adobe's default region splits. Scale
    /// matches this app's own Whites/Blacks convention (±100 -> ±0.2).
    private static func applyParametricCurve(
        to curve: [Double], shadows: Double, darks: Double, lights: Double, highlights: Double
    ) -> [Double] {
        guard curve.count == 5, shadows != 0 || darks != 0 || lights != 0 || highlights != 0
        else { return curve }
        var result = curve
        let scale = 0.002 // ±100 -> ±0.2
        result[0] = clamp(result[0] + shadows * scale, 0, 1)
        result[1] = clamp(result[1] + (shadows + darks) / 2 * scale, 0, 1)
        result[3] = clamp(result[3] + (lights + highlights) / 2 * scale, 0, 1)
        result[4] = clamp(result[4] + highlights * scale, 0, 1)
        return result
    }

    /// Adobe stores a tone curve as however many (x, y) control points the
    /// preset defines, in 0...255 space — not always 5 points, and not
    /// necessarily at our curve editor's fixed x-positions (0, .25, .5, .75,
    /// 1). Since our own model only supports those 5 fixed positions, this
    /// samples a `MonotoneCubicSpline` through Adobe's actual control points
    /// at exactly those five x's, matching the same smooth, overshoot-free
    /// interpolation Adobe's own curve (and `CIToneCurve`) uses, instead of
    /// copying points directly.
    private static func sampleCurve(_ points: [(x: Double, y: Double)]) -> [Double]? {
        guard points.count >= 2 else { return nil }
        let spline = MonotoneCubicSpline(points: points)
        return AdjustmentValues.toneCurveIdentity.map { spline.evaluate(at: $0 * 255) / 255 }
    }

    /// Collects every attribute (and, as a fallback, element text content)
    /// across the whole document whose local name — ignoring the `crs:`/
    /// other namespace prefix — matches a known Camera Raw field, parsed as
    /// a `Double`. Real-world `.xmp` files vary in whether Develop settings
    /// show up as attributes on `rdf:Description` or as nested elements;
    /// reading both (attributes take priority) is what makes this robust to
    /// that variation instead of assuming one specific exporter's layout.
    ///
    /// Tone curves are a separate structure: `crs:ToneCurvePV2012[Red/Green/
    /// Blue]` wraps an `rdf:Seq` of `rdf:li` entries, each a literal "x, y"
    /// pair — tracked independently of the scalar-field state above since
    /// it's a nested list, not a single value.
    private final class XMPParserDelegate: NSObject, XMLParserDelegate {
        private static let knownFields: Set<String> = [
            "Exposure2012", "Contrast2012", "Highlights2012", "Shadows2012",
            "Whites2012", "Blacks2012", "Texture", "Clarity2012", "Dehaze",
            "Temperature", "Tint", "Vibrance", "Saturation", "Sharpness",
            "LuminanceSmoothing",
            "RedHue", "RedSaturation", "GreenHue", "GreenSaturation", "BlueHue", "BlueSaturation",
            "HueAdjustmentRed", "HueAdjustmentOrange", "HueAdjustmentYellow", "HueAdjustmentGreen",
            "HueAdjustmentAqua", "HueAdjustmentBlue", "HueAdjustmentPurple", "HueAdjustmentMagenta",
            "SaturationAdjustmentRed", "SaturationAdjustmentOrange", "SaturationAdjustmentYellow",
            "SaturationAdjustmentGreen", "SaturationAdjustmentAqua", "SaturationAdjustmentBlue",
            "SaturationAdjustmentPurple", "SaturationAdjustmentMagenta",
            "LuminanceAdjustmentRed", "LuminanceAdjustmentOrange", "LuminanceAdjustmentYellow",
            "LuminanceAdjustmentGreen", "LuminanceAdjustmentAqua", "LuminanceAdjustmentBlue",
            "LuminanceAdjustmentPurple", "LuminanceAdjustmentMagenta",
            "ColorGradeShadowHue", "ColorGradeShadowSat", "ColorGradeShadowLum",
            "ColorGradeMidtoneHue", "ColorGradeMidtoneSat", "ColorGradeMidtoneLum",
            "ColorGradeHighlightHue", "ColorGradeHighlightSat", "ColorGradeHighlightLum",
            "ColorGradeGlobalHue", "ColorGradeGlobalSat", "ColorGradeGlobalLum", "ColorGradeBlending",
            "SplitToningShadowHue", "SplitToningShadowSaturation",
            "SplitToningHighlightHue", "SplitToningHighlightSaturation", "SplitToningBalance",
            "GrayMixerRed", "GrayMixerOrange", "GrayMixerYellow", "GrayMixerGreen",
            "GrayMixerAqua", "GrayMixerBlue", "GrayMixerPurple", "GrayMixerMagenta",
            "ParametricShadows", "ParametricDarks", "ParametricLights", "ParametricHighlights",
        ]
        private static let curveFields: Set<String> = [
            "ToneCurvePV2012", "ToneCurvePV2012Red", "ToneCurvePV2012Green", "ToneCurvePV2012Blue",
        ]

        var fields: [String: Double] = [:]
        var curves: [String: [(x: Double, y: Double)]] = [:]
        /// `crs:Name` off the nested `crs:Look/rdf:Description` — the only
        /// signal a preset gives for "this is a Black & White look" (see
        /// `parse()`).
        var lookProfileName: String?

        private var currentFieldName: String?
        private var currentText = ""

        private var currentCurveField: String?
        private var currentCurvePoints: [(x: Double, y: Double)] = []
        private var insideLi = false
        private var currentLiText = ""

        private var insideLook = false

        func parser(
            _ parser: XMLParser, didStartElement elementName: String,
            namespaceURI: String?, qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            let elementLocalName = localName(of: qName ?? elementName)

            if elementLocalName == "Look" {
                insideLook = true
            } else if insideLook, elementLocalName == "Description", lookProfileName == nil {
                for (key, value) in attributeDict where localName(of: key) == "Name" {
                    lookProfileName = value
                }
            }

            for (key, value) in attributeDict {
                let name = localName(of: key)
                guard Self.knownFields.contains(name), fields[name] == nil,
                      let number = parseDouble(value)
                else { continue }
                fields[name] = number
            }

            if Self.curveFields.contains(elementLocalName) {
                currentCurveField = elementLocalName
                currentCurvePoints = []
                return
            }
            if currentCurveField != nil, elementLocalName == "li" {
                insideLi = true
                currentLiText = ""
                return
            }
            if Self.knownFields.contains(elementLocalName) {
                currentFieldName = elementLocalName
                currentText = ""
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if insideLi {
                currentLiText += string
                return
            }
            guard currentFieldName != nil else { return }
            currentText += string
        }

        func parser(
            _ parser: XMLParser, didEndElement elementName: String,
            namespaceURI: String?, qualifiedName qName: String?
        ) {
            let localName = localName(of: qName ?? elementName)

            if localName == "Look" {
                insideLook = false
            }
            if insideLi, localName == "li" {
                insideLi = false
                if let point = parsePoint(currentLiText) {
                    currentCurvePoints.append(point)
                }
                return
            }
            if let curveField = currentCurveField, localName == curveField {
                curves[curveField] = currentCurvePoints
                currentCurveField = nil
                return
            }
            if let field = currentFieldName, localName == field {
                currentFieldName = nil
                guard fields[field] == nil, let number = parseDouble(currentText) else { return }
                fields[field] = number
            }
        }

        private func parsePoint(_ raw: String) -> (x: Double, y: Double)? {
            // Pretty-printed `.xmp` often wraps each `<rdf:li>`'s text across
            // lines (e.g. "\n  0, 0\n") — `.whitespaces` alone doesn't strip
            // the newlines, which then fails `Double(...)` parsing for every
            // single point and silently drops the whole curve.
            let parts = raw.split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard parts.count == 2, let x = Double(parts[0]), let y = Double(parts[1]) else { return nil }
            return (x, y)
        }

        private func localName(of qualified: String) -> String {
            qualified.split(separator: ":").last.map(String.init) ?? qualified
        }

        private func parseDouble(_ raw: String) -> Double? {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = trimmed.hasPrefix("+") ? String(trimmed.dropFirst()) : trimmed
            return Double(normalized)
        }
    }
}
