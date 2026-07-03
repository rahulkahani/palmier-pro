import Foundation

/// Multicam groups: N-way source sync, timeline layout, and angle-switch math.
/// Groups live in the media manifest; the timeline stays ordinary clips.
extension EditorViewModel {

    // MARK: - Lookup

    var multicamGroups: [MulticamGroup] { mediaManifest.multicamGroups }

    func multicamGroup(id: String) -> MulticamGroup? {
        mediaManifest.multicamGroups.first { $0.id == id }
    }

    func multicamGroup(containing mediaRef: String) -> MulticamGroup? {
        mediaManifest.multicamGroups.first { $0.member(for: mediaRef) != nil }
    }

    /// (group, member) the clip's source belongs to, if any.
    func multicamMembership(of clip: Clip) -> (group: MulticamGroup, member: MulticamGroup.Member)? {
        guard clip.mediaType == .video || clip.mediaType == .audio else { return nil }
        guard let group = multicamGroup(containing: clip.mediaRef),
              let member = group.member(for: clip.mediaRef) else { return nil }
        return (group, member)
    }

    /// Speaker/angle badge text for a multicam clip, or nil.
    func multicamBadgeLabel(for clip: Clip) -> String? {
        guard let (_, member) = multicamMembership(of: clip) else { return nil }
        if let speaker = member.speaker, !speaker.isEmpty { return speaker }
        return member.role == .camera ? "Cam" : "Mic"
    }

    // MARK: - Mutation

    func addMulticamGroup(_ group: MulticamGroup) {
        mediaManifest.multicamGroups.append(group)
        let groupId = group.id
        undoManager?.registerUndo(withTarget: self) { vm in
            vm.removeMulticamGroup(id: groupId)
        }
        undoManager?.setActionName("Create Multicam Group")
        isDocumentEdited = true
    }

    func updateMulticamGroup(_ group: MulticamGroup) {
        guard let idx = mediaManifest.multicamGroups.firstIndex(where: { $0.id == group.id }) else { return }
        let previous = mediaManifest.multicamGroups[idx]
        guard previous != group else { return }
        mediaManifest.multicamGroups[idx] = group
        undoManager?.registerUndo(withTarget: self) { vm in
            vm.updateMulticamGroup(previous)
        }
        undoManager?.setActionName("Edit Multicam Group")
        isDocumentEdited = true
    }

    func removeMulticamGroup(id: String) {
        guard let idx = mediaManifest.multicamGroups.firstIndex(where: { $0.id == id }) else { return }
        let removed = mediaManifest.multicamGroups[idx]
        mediaManifest.multicamGroups.remove(at: idx)
        undoManager?.registerUndo(withTarget: self) { vm in
            vm.addMulticamGroup(removed)
        }
        undoManager?.setActionName("Remove Multicam Group")
        isDocumentEdited = true
    }

    // MARK: - N-way source sync

    struct MulticamSyncReport: Sendable {
        var offsets: [String: Int] = [:]
        var confidences: [String: Double] = [:]
        var failures: [(mediaRef: String, message: String)] = []
    }

    /// Cross-correlates each member's source audio against `referenceRef`'s and
    /// returns per-member offsets on the group timebase (reference = 0).
    /// Operates on source media directly — no clips need to be on the timeline.
    func computeMulticamOffsets(
        memberRefs: [String],
        referenceRef: String,
        searchWindowSeconds: Double = AudioSyncDefaults.searchWindowSeconds,
        minConfidence: Double = AudioSyncDefaults.minConfidence
    ) async -> MulticamSyncReport {
        var report = MulticamSyncReport()
        let fps = Double(timeline.fps)
        guard fps > 0 else {
            report.failures = memberRefs.map { ($0, "Timeline fps unavailable.") }
            return report
        }
        guard let refURL = mediaResolver.resolveURL(for: referenceRef) else {
            report.failures = memberRefs.map { ($0, "Reference media unavailable.") }
            return report
        }
        guard let refEnv = try? await AudioEnvelopeExtractor.extract(from: refURL), !refEnv.samples.isEmpty else {
            report.failures = memberRefs.map { ($0, "Reference media has no readable audio.") }
            return report
        }
        report.offsets[referenceRef] = 0
        report.confidences[referenceRef] = 1.0

        let maxLag = max(1, Int((searchWindowSeconds / AudioEnvelopeExtractor.hopSeconds).rounded()))
        let refSamples = refEnv.samples

        for ref in memberRefs where ref != referenceRef {
            guard let url = mediaResolver.resolveURL(for: ref) else {
                report.failures.append((ref, "Media unavailable.")); continue
            }
            guard let env = try? await AudioEnvelopeExtractor.extract(from: url), !env.samples.isEmpty else {
                report.failures.append((ref, "No readable audio.")); continue
            }
            let samples = env.samples
            let match = await Task.detached(priority: .userInitiated) {
                AudioSyncCorrelator.correlate(reference: refSamples, target: samples, maxLagHops: maxLag)
            }.value
            guard let match, match.confidence >= minConfidence else {
                report.failures.append((ref, "No confident alignment — recordings may not overlap.")); continue
            }
            // target source frame 0 ≈ reference source frame lag → group time = lag.
            let offset = Int((Double(match.lagHops) * AudioEnvelopeExtractor.hopSeconds * fps).rounded())
            report.offsets[ref] = offset
            report.confidences[ref] = match.confidence
        }
        return report
    }

    // MARK: - Layout

    struct MulticamLayoutResult: Sendable {
        var programTrackIndex: Int = 0
        var placedClipIds: [String] = []
        var skipped: [(mediaRef: String, message: String)] = []
    }

    /// Lays the group onto the timeline: each mic full-length on its own
    /// sync-locked audio track, one default camera on a new program video track.
    /// Members are positioned by sync offset so everything lines up; the
    /// earliest member lands at `startFrame`.
    @discardableResult
    func layoutMulticamGroup(
        _ group: MulticamGroup,
        defaultCameraRef: String? = nil,
        startFrame: Int = 0
    ) -> MulticamLayoutResult {
        var result = MulticamLayoutResult()
        let camera = defaultCameraRef.flatMap { group.member(for: $0) } ?? group.cameras.first
        var toPlace: [MulticamGroup.Member] = []
        if let camera { toPlace.append(camera) }
        toPlace.append(contentsOf: group.mics)

        let assetsById = Dictionary(mediaAssets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let placeable = toPlace.filter { assetsById[$0.mediaRef] != nil }
        for member in toPlace where assetsById[member.mediaRef] == nil {
            result.skipped.append((member.mediaRef, "Asset not found in library."))
        }
        guard !placeable.isEmpty else { return result }
        let minOffset = placeable.map(\.syncOffsetFrames).min() ?? 0

        withTimelineSwap(actionName: "Multicam Layout") {
            let programTrackIndex = insertTrack(at: 0, type: .video)
            result.programTrackIndex = programTrackIndex

            if let camera, let asset = assetsById[camera.mediaRef] {
                let duration = clipDurationFrames(for: asset, segment: nil)
                let frame = startFrame + camera.syncOffsetFrames - minOffset
                let ids = placeClip(
                    asset: asset, trackIndex: programTrackIndex,
                    startFrame: frame, durationFrames: duration,
                    addLinkedAudio: false
                )
                result.placedClipIds.append(contentsOf: ids)
            }

            for mic in group.mics {
                guard let asset = assetsById[mic.mediaRef] else { continue }
                let duration = clipDurationFrames(for: asset, segment: nil)
                let frame = startFrame + mic.syncOffsetFrames - minOffset
                let trackIndex = insertTrack(at: timeline.tracks.count, type: .audio)
                let ids = placeClip(
                    asset: asset, trackIndex: trackIndex,
                    startFrame: frame, durationFrames: duration,
                    addLinkedAudio: false
                )
                result.placedClipIds.append(contentsOf: ids)
            }
        }
        return result
    }

    // MARK: - Angle switching

    struct AngleSwitchOutcome: Sendable {
        var switchedClipIds: [String] = []
        var splitCount: Int = 0
        var skipped: [(range: FrameRange, message: String)] = []
    }

    /// Swap the program-track clips inside each range to another camera of the
    /// same multicam group. Content time never shifts: the new clip's trim is
    /// derived from the group's sync offsets, so audio stays aligned by construction.
    func switchAngle(
        trackIndex: Int,
        switches: [(range: FrameRange, toMediaRef: String)]
    ) -> AngleSwitchOutcome {
        var outcome = AngleSwitchOutcome()
        guard timeline.tracks.indices.contains(trackIndex) else {
            outcome.skipped = switches.map { ($0.range, "Track index out of range.") }
            return outcome
        }
        let assetsById = Dictionary(mediaAssets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let trackId = timeline.tracks[trackIndex].id

        undoManager?.beginUndoGrouping()
        defer {
            undoManager?.endUndoGrouping()
            undoManager?.setActionName("Switch Angle")
        }

        func toSourceLen(_ ref: String) -> Int {
            assetsById[ref].map { secondsToFrame(seconds: $0.duration, fps: timeline.fps) } ?? 0
        }

        for (range, toRef) in switches {
            guard let ti = timeline.tracks.firstIndex(where: { $0.id == trackId }) else { break }
            guard let group = multicamGroup(containing: toRef),
                  let toMember = group.member(for: toRef) else {
                outcome.skipped.append((range, "Target media is not in a multicam group.")); continue
            }

            // Pre-validate against every group clip overlapping the range, so a
            // range that can't switch leaves no stray splits behind.
            let overlapping = timeline.tracks[ti].clips.filter { clip in
                clip.startFrame < range.end && clip.endFrame > range.start
                    && multicamMembership(of: clip)?.group.id == group.id
            }
            let candidates = overlapping.filter { $0.mediaRef != toRef }
            guard !overlapping.isEmpty else {
                outcome.skipped.append((range, "No multicam clips of this group inside the range.")); continue
            }
            guard !candidates.isEmpty else { continue }  // already showing the target angle

            var failure: String?
            let sourceLen = toSourceLen(toRef)
            for clip in candidates {
                guard let fromMember = group.member(for: clip.mediaRef) else { continue }
                let overlapStart = max(range.start, clip.startFrame)
                let overlapEnd = min(range.end, clip.endFrame)
                let speed = max(clip.speed, 0.0001)
                let sourceAtOverlapStart = clip.trimStartFrame
                    + Int((Double(overlapStart - clip.startFrame) * speed).rounded())
                let converted = MulticamGroup.convertedTrimStart(sourceAtOverlapStart, from: fromMember, to: toMember)
                if converted < 0 {
                    failure = "\(toRef) wasn't recording yet at frame \(overlapStart)."; break
                }
                let consumed = Int((Double(overlapEnd - overlapStart) * speed).rounded())
                if sourceLen > 0, converted + consumed > sourceLen {
                    failure = "\(toRef) ends before frame \(overlapEnd)."; break
                }
            }
            if let failure {
                outcome.skipped.append((range, failure)); continue
            }

            // Insert boundaries so only the requested span switches.
            var points: [(trackIndex: Int, atFrame: Int)] = []
            for edge in [range.start, range.end] {
                if timeline.tracks[ti].clips.contains(where: { edge > $0.startFrame && edge < $0.endFrame }) {
                    points.append((ti, edge))
                }
            }
            if !points.isEmpty {
                outcome.splitCount += splitClips(at: points).count
            }

            // Rewrite every group-member clip now fully inside the range.
            var targets: [(id: String, newTrimStart: Int, newTrimEnd: Int)] = []
            for clip in timeline.tracks[ti].clips
            where clip.startFrame >= range.start && clip.endFrame <= range.end {
                guard let (clipGroup, fromMember) = multicamMembership(of: clip), clipGroup.id == group.id else { continue }
                if clip.mediaRef == toRef { continue }
                let newTrimStart = MulticamGroup.convertedTrimStart(clip.trimStartFrame, from: fromMember, to: toMember)
                guard newTrimStart >= 0 else { continue }  // pre-validated; defensive
                let consumed = clip.sourceFramesConsumed
                let newTrimEnd = sourceLen > 0 ? max(0, sourceLen - newTrimStart - consumed) : 0
                targets.append((clip.id, newTrimStart, newTrimEnd))
            }

            let fit = assetsById[toRef].map { fitTransform(for: $0) }
            for target in targets {
                mutateClips(ids: [target.id], actionName: "Switch Angle") { clip in
                    clip.mediaRef = toRef
                    clip.trimStartFrame = target.newTrimStart
                    clip.trimEndFrame = target.newTrimEnd
                    if let fit { clip.transform = fit }
                }
                outcome.switchedClipIds.append(target.id)
            }
        }
        if !outcome.switchedClipIds.isEmpty || outcome.splitCount > 0 {
            notifyTimelineChanged()
        }
        return outcome
    }

    // MARK: - Speaker activity

    /// Per-mic envelope tracks read through the mics' timeline clips, so activity
    /// lands in project frames and survives edits (word cuts, ripples, splits).
    func speakerActivityTracks(
        group: MulticamGroup,
        window: Range<Int>? = nil
    ) async -> (tracks: [SpeakerActivity.MicTrack], micsWithoutClips: [String]) {
        var tracks: [SpeakerActivity.MicTrack] = []
        var missing: [String] = []
        let fps = Double(timeline.fps)
        guard fps > 0 else { return ([], group.mics.map(\.mediaRef)) }

        for mic in group.mics {
            let speaker = mic.speaker
                ?? mediaAssets.first(where: { $0.id == mic.mediaRef })?.name
                ?? mic.mediaRef
            let clips = timeline.tracks.flatMap(\.clips).filter {
                $0.mediaRef == mic.mediaRef && $0.mediaType == .audio
            }
            guard !clips.isEmpty, let url = mediaResolver.resolveURL(for: mic.mediaRef) else {
                missing.append(mic.mediaRef)
                continue
            }
            for clip in clips {
                var projectStart = clip.startFrame
                var projectEnd = clip.endFrame
                if let window {
                    projectStart = max(projectStart, window.lowerBound)
                    projectEnd = min(projectEnd, window.upperBound)
                }
                guard projectEnd > projectStart else { continue }
                let speed = max(clip.speed, AudioSyncDefaults.minSpeed)
                let sourceStart = (Double(clip.trimStartFrame) + Double(projectStart - clip.startFrame) * speed) / fps
                let sourceEnd = (Double(clip.trimStartFrame) + Double(projectEnd - clip.startFrame) * speed) / fps
                guard let env = try? await AudioEnvelopeExtractor.extract(
                    from: url,
                    range: sourceStart...max(sourceStart + AudioEnvelopeExtractor.hopSeconds, sourceEnd)
                ), !env.samples.isEmpty else { continue }
                tracks.append(SpeakerActivity.MicTrack(
                    speaker: speaker,
                    samples: env.samples,
                    hopSeconds: env.hopSeconds,
                    startFrame: projectStart,
                    speed: clip.speed
                ))
            }
        }
        return (tracks, missing)
    }

    // MARK: - Create from selection (media panel affordance)

    /// Builds a group from selected assets (videos → cameras, audio → mics),
    /// syncs them against the first mic (or first camera), and lays out the timeline.
    func createMulticamGroupFromAssets(ids: [String], name: String? = nil) {
        let assets = ids.compactMap { id in mediaAssets.first { $0.id == id } }
        let avAssets = assets.filter { $0.type == .video || $0.type == .audio }
        guard avAssets.count >= 2 else { return }
        let members = avAssets.map { asset in
            MulticamGroup.Member(mediaRef: asset.id, role: asset.type == .audio ? .mic : .camera)
        }
        let referenceRef = (avAssets.first { $0.type == .audio } ?? avAssets[0]).id
        let groupName = name ?? "Multicam \(mediaManifest.multicamGroups.count + 1)"

        Task { @MainActor [weak self] in
            guard let self else { return }
            let report = await self.computeMulticamOffsets(
                memberRefs: members.map(\.mediaRef), referenceRef: referenceRef
            )
            var synced = members
            for i in synced.indices {
                if let offset = report.offsets[synced[i].mediaRef] {
                    synced[i].syncOffsetFrames = offset
                }
            }
            let group = MulticamGroup(name: groupName, members: synced)
            self.undoManager?.beginUndoGrouping()
            self.addMulticamGroup(group)
            self.layoutMulticamGroup(group)
            self.undoManager?.endUndoGrouping()
            self.undoManager?.setActionName("Create Multicam Group")
        }
    }
}
