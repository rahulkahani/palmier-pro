import Foundation

extension EditorViewModel {

    /// Transform + crop placing `clip` into `rect` without distorting it: `.fill` covers the slot
    /// (crops to its aspect), `.fit` letterboxes the source inside it. `anchorX`/`anchorY` (0–1)
    /// bias which part survives — anchorY 0 keeps the top (a face).
    func layoutPlacement(
        for clip: Clip,
        in rect: LayoutRect,
        fit: LayoutFit,
        anchorX: Double = 0.5,
        anchorY: Double = 0.5
    ) -> (transform: Transform, crop: Crop) {
        let canvasAspect = Double(timeline.width) / Double(max(1, timeline.height))
        let slotPixelAspect = rect.h > 0 ? (rect.w / rect.h) * canvasAspect : canvasAspect

        switch fit {
        case .fill:
            // Renderer maps the whole frame into transform.w×h, so expand it by the crop's
            // visible fraction (and shift by the inset) or the crop just floats in a stretched box.
            let crop = cropFittingAspect(for: clip, targetPixelAspect: slotPixelAspect, anchorX: anchorX, anchorY: anchorY)
            let vw = crop.visibleWidthFraction
            let vh = crop.visibleHeightFraction
            guard vw > 0, vh > 0 else {
                return (Transform(topLeft: (rect.x, rect.y), width: rect.w, height: rect.h), crop)
            }
            let w = rect.w / vw
            let h = rect.h / vh
            let x = rect.x - crop.left * w
            let y = rect.y - crop.top * h
            return (Transform(topLeft: (x, y), width: w, height: h), crop)

        case .fit:
            guard let rel = mediaCanvasAspect(for: clip), rel > 0 else {
                return (Transform(topLeft: (rect.x, rect.y), width: rect.w, height: rect.h), Crop())
            }
            var drawW = rect.w
            var drawH = rect.h
            if rel * rect.h <= rect.w {
                drawH = rect.h
                drawW = rel * rect.h
            } else {
                drawW = rect.w
                drawH = rect.w / rel
            }
            let ax = min(1, max(0, anchorX))
            let ay = min(1, max(0, anchorY))
            let x = rect.x + (rect.w - drawW) * ax
            let y = rect.y + (rect.h - drawH) * ay
            return (Transform(topLeft: (x, y), width: drawW, height: drawH), Crop())
        }
    }
}
