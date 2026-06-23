import AVFoundation
import CoreImage
import Foundation

extension ToolExecutor {
    fileprivate struct SetColorGradeInput: DecodableToolArgs {
        let clipIds: [String]
        let reset: Bool?
        let exposure: Double?
        let contrast: Double?
        let saturation: Double?
        let vibrance: Double?
        let temperature: Double?
        let tint: Double?
        let highlights: Double?
        let shadows: Double?
        let blacks: Double?
        let whites: Double?
        let shadowsHue: Double?; let shadowsAmount: Double?; let shadowsLum: Double?
        let midsHue: Double?; let midsAmount: Double?; let midsGamma: Double?
        let highsHue: Double?; let highsAmount: Double?; let highsGain: Double?
        let masterCurve: [[Double]]?
        let redCurve: [[Double]]?
        let greenCurve: [[Double]]?
        let blueCurve: [[Double]]?
        static let allowedKeys: Set<String> = [
            "clipIds", "reset", "exposure", "contrast", "saturation", "vibrance", "temperature", "tint",
            "highlights", "shadows", "blacks", "whites",
            "shadowsHue", "shadowsAmount", "shadowsLum",
            "midsHue", "midsAmount", "midsGamma",
            "highsHue", "highsAmount", "highsGain",
            "masterCurve", "redCurve", "greenCurve", "blueCurve",
        ]
        var hasAnyParam: Bool {
            [exposure, contrast, saturation, vibrance, temperature, tint, highlights, shadows, blacks, whites,
             shadowsHue, shadowsAmount, shadowsLum, midsHue, midsAmount, midsGamma, highsHue, highsAmount, highsGain]
                .contains { $0 != nil }
                || [masterCurve, redCurve, greenCurve, blueCurve].contains { $0 != nil }
        }
    }

    func setColorGrade(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let input: SetColorGradeInput = try decodeToolArgs(args, path: "set_color_grade")
        guard !input.clipIds.isEmpty else { throw ToolError("clipIds is empty.") }
        guard input.hasAnyParam else { throw ToolError("No grade parameters provided.") }
        for id in input.clipIds {
            guard let clip = editor.clipFor(id: id) else { throw ToolError("Clip not found: \(id)") }
            guard clip.mediaType == .video || clip.mediaType == .image else {
                throw ToolError("Clip \(id) is a \(clip.mediaType.rawValue) clip; set_color_grade needs a video or image clip.")
            }
        }
        let reset = input.reset ?? false
        let actionName = input.clipIds.count == 1 ? "Color Grade (Agent)" : "Color Grade ×\(input.clipIds.count) (Agent)"
        withUndoGroup(editor, actionName: actionName) {
            editor.mutateClips(ids: Set(input.clipIds), actionName: actionName) { clip in
                var state = GradeState(effects: reset ? nil : clip.effects)
                state.apply(input)
                let nonColor = (clip.effects ?? []).filter { !$0.type.hasPrefix("color.") }
                clip.effects = nonColor + state.buildStack()
            }
        }
        return .ok("Graded \(input.clipIds.count) clip\(input.clipIds.count == 1 ? "" : "s") (\(reset ? "reset" : "merged")). Verify with inspect_timeline.")
    }

    fileprivate struct ApplyLutInput: DecodableToolArgs {
        let clipIds: [String]
        let path: String
        let strength: Double?
        static let allowedKeys: Set<String> = ["clipIds", "path", "strength"]
    }

    /// Applies an existing .cube 3D LUT file to clips
    func applyLut(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let input: ApplyLutInput = try decodeToolArgs(args, path: "apply_lut")
        guard !input.clipIds.isEmpty else { throw ToolError("clipIds is empty.") }
        let strength = clamp3(min(1, max(0, input.strength ?? 1)))

        for id in input.clipIds {
            guard let clip = editor.clipFor(id: id) else { throw ToolError("Clip not found: \(id)") }
            guard clip.mediaType == .video || clip.mediaType == .image else {
                throw ToolError("Clip \(id) is a \(clip.mediaType.rawValue) clip; apply_lut needs a video or image clip.")
            }
        }

        let sourceURL = URL(fileURLWithPath: (input.path as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw ToolError("No file at path: \(sourceURL.path)")
        }
        guard LUTLoader.load(path: sourceURL.path) != nil else {
            throw ToolError("Not a valid .cube 3D LUT: \(sourceURL.lastPathComponent)")
        }

        let lutDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PalmierPro/luts/\(editor.projectId ?? "default")", isDirectory: true)
        try FileManager.default.createDirectory(at: lutDir, withIntermediateDirectories: true)
        let dest = lutDir.appendingPathComponent(sourceURL.lastPathComponent)
        if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
        try FileManager.default.copyItem(at: sourceURL, to: dest)

        let actionName = input.clipIds.count == 1 ? "Apply LUT (Agent)" : "Apply LUT ×\(input.clipIds.count) (Agent)"
        withUndoGroup(editor, actionName: actionName) {
            editor.mutateClips(ids: Set(input.clipIds), actionName: actionName) { clip in
                var effects = (clip.effects ?? []).filter { $0.type != "color.lut" } // replace prior LUT, keep primaries
                effects.append(Effect(type: "color.lut", params: [
                    "path": EffectParam(string: dest.path),
                    "intensity": EffectParam(value: strength),
                ]))
                clip.effects = effects
            }
        }
        return .ok("""
        Applied LUT \(sourceURL.lastPathComponent) to \(input.clipIds.count) clip\(input.clipIds.count == 1 ? "" : "s") \
        (intensity \(String(format: "%.2f", strength))). Verify with inspect_timeline.
        """)
    }

    fileprivate struct InspectColorInput: DecodableToolArgs {
        let clipId: String?
        let mediaRef: String?
        let atFrame: Int?
        let reference: String?
        static let allowedKeys: Set<String> = ["clipId", "mediaRef", "atFrame", "reference"]
    }

    /// Measures color scopes of a clip's current graded look (clipId) or a raw media asset
    /// (mediaRef), with the rendered frame. With `reference`, also measures that asset (raw)
    /// and returns the subject−reference gap.
    func inspectColor(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        let input: InspectColorInput = try decodeToolArgs(args, path: "inspect_color")

        let image: CIImage, scopes: Scopes, subjectKey: String
        if let clipId = input.clipId {
            (image, scopes) = try await gradedClip(clipId, atFrame: input.atFrame, editor: editor)
            subjectKey = "clip"
        } else if let mediaRef = input.mediaRef {
            (image, scopes) = try await rawAsset(mediaRef, editor: editor, label: "Media")
            subjectKey = "media"
        } else {
            throw ToolError("Provide either clipId (measures the graded clip) or mediaRef (measures the raw asset).")
        }

        var blocks: [ToolResult.Block] = []
        if let jpeg = Self.encodeJPEG(image) {
            blocks.append(.image(base64: jpeg.base64EncodedString(), mediaType: "image/jpeg"))
        }
        var payload: [String: Any] = [subjectKey: Self.readout(scopes)]

        if let reference = input.reference {
            let (refImage, refScopes) = try await rawAsset(reference, editor: editor, label: "Reference")
            if let jpeg = Self.encodeJPEG(refImage) {
                blocks.append(.image(base64: jpeg.base64EncodedString(), mediaType: "image/jpeg"))
            }
            payload["reference"] = Self.readout(refScopes)
            payload["gap"] = Self.gap(current: scopes, reference: refScopes)
        }

        guard let json = Self.jsonString(payload) else { throw ToolError("Failed to encode scopes.") }
        blocks.append(.text(json))
        return ToolResult(content: blocks, isError: false)
    }

    /// The clip's graded look (existing effects applied) at a representative frame.
    private func gradedClip(_ clipId: String, atFrame: Int?, editor: EditorViewModel) async throws -> (CIImage, Scopes) {
        guard let clip = editor.clipFor(id: clipId) else { throw ToolError("Clip not found: \(clipId)") }
        guard clip.mediaType == .video || clip.mediaType == .image else {
            throw ToolError("Clip \(clipId) is a \(clip.mediaType.rawValue) clip; inspect_color needs a video or image clip.")
        }
        let srcAsset = try asset(clip.mediaRef, editor: editor, label: "Clip source")
        guard let srcURL = editor.mediaResolver.resolveURL(for: clip.mediaRef) else {
            throw ToolError("Could not resolve a source URL for clip \(clipId).")
        }
        let fps = srcAsset.sourceFPS ?? Double(editor.timeline.fps)
        let sourceFrame: Double
        if let f = atFrame {
            let rel = max(0, min(clip.durationFrames, f - clip.startFrame))
            sourceFrame = Double(clip.trimStartFrame) + Double(rel) * clip.speed
        } else {
            sourceFrame = Double(clip.trimStartFrame) + Double(clip.sourceFramesConsumed) / 2
        }
        guard let frame = await Self.frameImage(url: srcURL, type: clip.mediaType, atSeconds: sourceFrame / max(1, fps)) else {
            throw ToolError("Could not decode a frame for clip \(clipId).")
        }
        let graded = Self.applyingEffects(frame, clip: clip, atOffset: clip.durationFrames / 2)
        guard let scopes = ColorScopes.measure(graded) else { throw ToolError("Could not measure the clip frame.") }
        return (graded, scopes)
    }

    /// A raw media asset's frame (no effects), at its midpoint.
    private func rawAsset(_ mediaRef: String, editor: EditorViewModel, label: String) async throws -> (CIImage, Scopes) {
        let media = try asset(mediaRef, editor: editor, label: label)
        guard media.type == .video || media.type == .image else {
            throw ToolError("\(label) \(mediaRef) is a \(media.type.rawValue) asset; inspect_color needs a video or image asset.")
        }
        guard let url = editor.mediaResolver.resolveURL(for: mediaRef) else {
            throw ToolError("Could not resolve a URL for \(mediaRef).")
        }
        guard let image = await Self.frameImage(url: url, type: media.type, atSeconds: media.duration / 2),
              let scopes = ColorScopes.measure(image) else {
            throw ToolError("Could not measure \(mediaRef).")
        }
        return (image, scopes)
    }

    // MARK: - Color helpers

    fileprivate static func frameImage(url: URL, type: ClipType, atSeconds: Double) async -> CIImage? {
        if type == .image { return CIImage(contentsOf: url, options: [.colorSpace: NSNull()]) }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        let tolerance = CMTime(seconds: 1, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        let time = CMTime(seconds: max(0, atSeconds), preferredTimescale: 600)
        guard let cg = try? await generator.image(at: time).image else { return nil }
        return CIImage(cgImage: cg, options: [.colorSpace: NSNull()])
    }

    fileprivate static func applyingEffects(_ image: CIImage, clip: Clip, atOffset offset: Int) -> CIImage {
        guard let effects = clip.effects else { return image }
        var out = image
        for effect in effects where effect.enabled {
            guard let descriptor = EffectRegistry.descriptor(id: effect.type) else { continue }
            out = descriptor.render(out, effect: effect, atOffset: offset)
        }
        return out
    }

    fileprivate static func encodeJPEG(_ image: CIImage) -> Data? {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0,
              let cg = ColorScopes.context.createCGImage(
                image, from: extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else { return nil }
        return ImageEncoder.encodeJPEG(cg, quality: 0.8)
    }

    // NSDecimalNumber so JSONSerialization renders clean 3-decimal values, not float noise.
    private static func r3(_ v: Float) -> NSDecimalNumber { NSDecimalNumber(string: String(format: "%.3f", Double(v))) }
    private static func rgb(_ v: SIMD3<Float>) -> [NSDecimalNumber] { [r3(v.x), r3(v.y), r3(v.z)] }

    private static func readout(_ s: Scopes) -> [String: Any] {
        [
            "luma": [
                "black": r3(s.lumaBlack), "white": r3(s.lumaWhite), "mean": r3(s.lumaMean),
                "clipLowPct": r3(s.clipLow * 100), "clipHighPct": r3(s.clipHigh * 100),
                "histogram16": s.lumaHistogram.map { r3($0) },
            ],
            "meanRGB": rgb(s.meanRGB),
            "blackRGB": rgb(s.blackRGB), "whiteRGB": rgb(s.whiteRGB),
            "zones": ["shadows": rgb(s.shadowRGB), "mids": rgb(s.midRGB), "highs": rgb(s.highRGB)],
            "saturation": r3(s.saturationMean),
            "balance": ["warmCool": r3(s.warmCoolBias), "greenMagenta": r3(s.greenMagentaBias)],
        ]
    }

    /// current − reference for the key metrics, plus knob-mapped hints.
    private static func gap(current c: Scopes, reference r: Scopes) -> [String: Any] {
        var hints: [String] = []
        let db = c.lumaBlack - r.lumaBlack
        if abs(db) > 0.03 { hints.append(db > 0 ? "blacks higher than ref → lower 'blacks' / deepen shadows" : "blacks lower than ref → raise 'blacks'") }
        let dw = c.warmCoolBias - r.warmCoolBias
        if abs(dw) > 0.03 { hints.append(dw > 0 ? "warmer than ref → cooler 'temperature'" : "cooler than ref → warmer 'temperature'") }
        let dg = c.greenMagentaBias - r.greenMagentaBias
        if abs(dg) > 0.02 { hints.append(dg > 0 ? "greener than ref → 'tint' toward magenta" : "more magenta than ref → 'tint' toward green") }
        let dsat = c.saturationMean - r.saturationMean
        if abs(dsat) > 0.03 { hints.append(dsat > 0 ? "more saturated than ref → lower 'saturation'" : "less saturated than ref → raise 'saturation'") }
        return [
            "lumaBlack": r3(db), "lumaWhite": r3(c.lumaWhite - r.lumaWhite), "lumaMean": r3(c.lumaMean - r.lumaMean),
            "warmCool": r3(dw), "greenMagenta": r3(dg), "saturation": r3(dsat),
            "shadowsRGB": rgb(c.shadowRGB - r.shadowRGB),
            "midsRGB": rgb(c.midRGB - r.midRGB),
            "highsRGB": rgb(c.highRGB - r.highRGB),
            "hints": hints,
        ]
    }
}

private func clamp3(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }

private struct GradeState {
    var exposure, temperature, tint, contrast, highlights, shadows, blacks, whites: Double?
    var shadowsHue, shadowsAmount, shadowsLum: Double?
    var midsHue, midsAmount, midsGamma: Double?
    var highsHue, highsAmount, highsGain: Double?
    var vibrance, saturation: Double?
    var curve: GradeCurve?

    init(effects: [Effect]?) {
        guard let effects else { return }
        for e in effects {
            let p = e.params
            switch e.type {
            case "color.exposure": exposure = p["ev"]?.value
            case "color.temperature": temperature = p["temperature"]?.value; tint = p["tint"]?.value
            case "color.contrast": contrast = p["amount"]?.value
            case "color.highlightsShadows": highlights = p["highlights"]?.value; shadows = p["shadows"]?.value
            case "color.blacksWhites": blacks = p["blacks"]?.value; whites = p["whites"]?.value
            case "color.vibrance": vibrance = p["amount"]?.value
            case "color.saturation": saturation = p["amount"]?.value
            case "color.curves": curve = (p["curve"]?.string).flatMap { GradeCurve(json: $0) }
            case "color.wheels":
                (shadowsHue, shadowsAmount) = Self.hueAmount(p["lift_x"]?.value ?? 0, p["lift_y"]?.value ?? 0)
                shadowsLum = p["lift_m"]?.value
                (midsHue, midsAmount) = Self.hueAmount(p["gamma_x"]?.value ?? 0, p["gamma_y"]?.value ?? 0)
                midsGamma = p["gamma_m"]?.value
                (highsHue, highsAmount) = Self.hueAmount(p["gain_x"]?.value ?? 0, p["gain_y"]?.value ?? 0)
                highsGain = p["gain_m"]?.value
            default: break
            }
        }
    }

    mutating func apply(_ i: ToolExecutor.SetColorGradeInput) {
        if let v = i.exposure { exposure = v }
        if let v = i.temperature { temperature = v }
        if let v = i.tint { tint = v }
        if let v = i.contrast { contrast = v }
        if let v = i.highlights { highlights = v }
        if let v = i.shadows { shadows = v }
        if let v = i.blacks { blacks = v }
        if let v = i.whites { whites = v }
        if let v = i.shadowsHue { shadowsHue = v }
        if let v = i.shadowsAmount { shadowsAmount = v }
        if let v = i.shadowsLum { shadowsLum = v }
        if let v = i.midsHue { midsHue = v }
        if let v = i.midsAmount { midsAmount = v }
        if let v = i.midsGamma { midsGamma = v }
        if let v = i.highsHue { highsHue = v }
        if let v = i.highsAmount { highsAmount = v }
        if let v = i.highsGain { highsGain = v }
        if let v = i.vibrance { vibrance = v }
        if let v = i.saturation { saturation = v }
        func points(_ arr: [[Double]]?) -> [CurvePoint]? {
            arr?.compactMap { $0.count >= 2 ? CurvePoint(x: clamp3($0[0]), y: clamp3($0[1])) : nil }
        }
        if i.masterCurve != nil || i.redCurve != nil || i.greenCurve != nil || i.blueCurve != nil {
            var c = curve ?? GradeCurve()
            if let p = points(i.masterCurve) { c.master = p }
            if let p = points(i.redCurve) { c.red = p }
            if let p = points(i.greenCurve) { c.green = p }
            if let p = points(i.blueCurve) { c.blue = p }
            curve = c
        }
    }

    func buildStack() -> [Effect] {
        var stack: [Effect] = []
        if let v = exposure { stack.append(.make("color.exposure", ["ev": clamp3(v)])) }
        if temperature != nil || tint != nil {
            stack.append(.make("color.temperature", ["temperature": clamp3(temperature ?? 6500), "tint": clamp3(tint ?? 0)]))
        }
        if let v = contrast { stack.append(.make("color.contrast", ["amount": clamp3(v)])) }
        if highlights != nil || shadows != nil {
            stack.append(.make("color.highlightsShadows", ["highlights": clamp3(highlights ?? 0), "shadows": clamp3(shadows ?? 0)]))
        }
        if blacks != nil || whites != nil {
            stack.append(.make("color.blacksWhites", ["blacks": clamp3(blacks ?? 0), "whites": clamp3(whites ?? 0)]))
        }
        if let curve, !curve.isIdentity, let json = curve.encoded() {
            var e = Effect(type: "color.curves")
            e.params["curve"] = EffectParam(string: json)
            stack.append(e)
        }
        let wheelFields = [shadowsHue, shadowsAmount, shadowsLum, midsHue, midsAmount, midsGamma, highsHue, highsAmount, highsGain]
        if wheelFields.contains(where: { $0 != nil }) {
            let (lx, ly) = Self.xy(shadowsHue, shadowsAmount)
            let (gx, gy) = Self.xy(midsHue, midsAmount)
            let (hx, hy) = Self.xy(highsHue, highsAmount)
            stack.append(.make("color.wheels", [
                "lift_x": clamp3(lx), "lift_y": clamp3(ly), "lift_m": clamp3(shadowsLum ?? 0),
                "gamma_x": clamp3(gx), "gamma_y": clamp3(gy), "gamma_m": clamp3(midsGamma ?? 1),
                "gain_x": clamp3(hx), "gain_y": clamp3(hy), "gain_m": clamp3(highsGain ?? 1),
            ]))
        }
        if let v = vibrance { stack.append(.make("color.vibrance", ["amount": clamp3(v)])) }
        if let v = saturation { stack.append(.make("color.saturation", ["amount": clamp3(v)])) }
        return stack
    }

    private static func hueAmount(_ x: Double, _ y: Double) -> (Double?, Double?) {
        let amt = (x * x + y * y).squareRoot()
        guard amt > 1e-6 else { return (nil, nil) }
        var deg = atan2(y, x) * 180 / .pi
        if deg < 0 { deg += 360 }
        return (deg, amt)
    }

    private static func xy(_ hue: Double?, _ amount: Double?) -> (Double, Double) {
        let a = (hue ?? 0) * .pi / 180, r = amount ?? 0
        return (r * cos(a), r * sin(a))
    }
}
