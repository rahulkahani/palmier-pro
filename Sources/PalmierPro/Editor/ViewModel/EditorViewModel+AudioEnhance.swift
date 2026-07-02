import Foundation

extension EditorViewModel {
    /// Enables/disables denoise (optionally setting the dry/wet amount) on `clipIds` as one
    /// undoable action, then kicks off any needed bakes. Shared by the inspector and agent tool.
    func setDenoise(clipIds: Set<String>, enabled: Bool, amount: Double? = nil, actionName: String) {
        let clamped = amount.map { min(1, max(0, $0)) }
        mutateClips(ids: clipIds, actionName: actionName) { clip in
            var stack = clip.effects ?? []
            let current = stack.first { $0.type == Clip.denoiseEffectType }
            stack.removeAll { $0.type == Clip.denoiseEffectType }
            if enabled {
                let value = clamped ?? current?.params["amount"]?.value ?? Clip.defaultDenoiseAmount
                stack.append(Effect(type: Clip.denoiseEffectType, enabled: true, params: [
                    "amount": EffectParam(value: value),
                ]))
            }
            clip.effects = stack.isEmpty ? nil : stack
        }
        guard enabled else { return }
        for id in clipIds {
            if let live = clipFor(id: id) { enhanceAudioIfNeeded(for: live) }
        }
    }

    /// Kicks off the offline denoise bake for `clip`'s source if not already cached/in-flight.
    /// Fire-and-forget; `CompositionBuilder` picks up the cached result on next rebuild.
    func enhanceAudioIfNeeded(for clip: Clip) {
        guard clip.hasDenoiseEnabled, !denoiseInFlight.contains(clip.mediaRef),
              let url = mediaResolver.resolveURL(for: clip.mediaRef) else { return }
        denoiseInFlight.insert(clip.mediaRef)
        let mediaRef = clip.mediaRef
        let amount = clip.denoiseAmount
        Task.detached(priority: .utility) { [weak self] in
            do {
                _ = try await AudioEnhancer.enhancedAudio(for: url, mediaRef: mediaRef, amount: amount)
            } catch {
                Log.preview.error("denoise bake failed mediaRef=\(mediaRef): \(error.localizedDescription)")
            }
            await MainActor.run { [self] in
                self?.denoiseInFlight.remove(mediaRef)
                self?.notifyTimelineChanged()
            }
        }
    }
}
