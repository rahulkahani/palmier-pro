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
            guard let live = clipFor(id: id) else { continue }
            // An explicit user/agent change is the retry gesture after a failed bake.
            denoiseFailed.remove(live.mediaRef)
            enhanceAudioIfNeeded(for: live)
        }
    }

    /// Re-checks every denoise-enabled clip and bakes anything missing from the cache.
    /// Cheap no-op when nothing is pending (one file-exists check per denoised clip), so it's
    /// safe to call after any timeline change — project open, undo/redo, agent edits.
    func enhancePendingDenoises() {
        for track in timeline.tracks {
            for clip in track.clips where clip.hasDenoiseEnabled {
                enhanceAudioIfNeeded(for: clip)
            }
        }
    }

    /// Kicks off the offline denoise bake for `clip`'s source if not already cached/in-flight.
    /// Fire-and-forget; `CompositionBuilder` picks up the cached result on next rebuild.
    func enhanceAudioIfNeeded(for clip: Clip) {
        guard clip.hasDenoiseEnabled,
              !denoiseInFlight.contains(clip.mediaRef), !denoiseFailed.contains(clip.mediaRef),
              let url = mediaResolver.resolveURL(for: clip.mediaRef),
              AudioEnhancer.cachedURL(for: url, mediaRef: clip.mediaRef, amount: clip.denoiseAmount) == nil
        else { return }
        denoiseInFlight.insert(clip.mediaRef)
        let mediaRef = clip.mediaRef
        let amount = clip.denoiseAmount
        Task.detached(priority: .utility) { [weak self] in
            var failed = false
            do {
                _ = try await AudioEnhancer.enhancedAudio(for: url, mediaRef: mediaRef, amount: amount)
            } catch {
                failed = true
                Log.preview.error("denoise bake failed mediaRef=\(mediaRef): \(error.localizedDescription)")
            }
            await MainActor.run { [self] in
                self?.denoiseInFlight.remove(mediaRef)
                if failed { self?.denoiseFailed.insert(mediaRef) }
                // Also rescans pending denoises: strength may have changed while this bake
                // ran; the cache check above makes the rescan converge instead of looping.
                self?.notifyTimelineChanged()
            }
        }
    }
}
