import Foundation
import Testing
@testable import PalmierPro

@MainActor
private func editor(_ tracks: [Track]) -> EditorViewModel {
    let e = EditorViewModel()
    e.timeline = Fixtures.timeline(tracks: tracks)
    return e
}

@Suite("EditorViewModel — rollEditPoint")
@MainActor
struct RollEditTests {

    /// Two adjacent clips sharing an edit point at frame 100 — the multicam
    /// angle-cut shape. Left has tail headroom, right has head headroom.
    private func angleCutTrack() -> Track {
        Fixtures.videoTrack(clips: [
            Fixtures.clip(id: "left0000", start: 0, duration: 100, trimEnd: 50),
            Fixtures.clip(id: "right000", start: 100, duration: 100, trimStart: 40),
        ])
    }

    @Test func neighborLookupFindsAdjacentClipOnly() {
        let e = editor([angleCutTrack()])
        #expect(e.rollNeighbor(of: "left0000", edge: .right)?.id == "right000")
        #expect(e.rollNeighbor(of: "right000", edge: .left)?.id == "left0000")
        #expect(e.rollNeighbor(of: "left0000", edge: .left) == nil)
        #expect(e.rollNeighbor(of: "right000", edge: .right) == nil)
    }

    @Test func rollRightLengthensLeftAndShortensRight() {
        let e = editor([angleCutTrack()])
        e.rollEditPoint(clipId: "left0000", edge: .right, deltaFrames: 20, propagateToLinked: false)

        let clips = e.timeline.tracks[0].clips.sorted { $0.startFrame < $1.startFrame }
        // Boundary moved 100 → 120; total extent unchanged; still adjacent.
        #expect(clips[0].endFrame == 120)
        #expect(clips[1].startFrame == 120)
        #expect(clips[1].endFrame == 200)
        // Source bookkeeping: left revealed 20 tail frames, right consumed 20 head frames.
        #expect(clips[0].trimEndFrame == 30)
        #expect(clips[1].trimStartFrame == 60)
    }

    @Test func rollLeftLengthensRightAndShortensLeft() {
        let e = editor([angleCutTrack()])
        e.rollEditPoint(clipId: "right000", edge: .left, deltaFrames: -20, propagateToLinked: false)

        let clips = e.timeline.tracks[0].clips.sorted { $0.startFrame < $1.startFrame }
        #expect(clips[0].endFrame == 80)
        #expect(clips[1].startFrame == 80)
        #expect(clips[1].endFrame == 200)
        #expect(clips[0].trimEndFrame == 70)
        #expect(clips[1].trimStartFrame == 20)
    }

    @Test func rollClampsToGrowingSideHeadroom() {
        // Left only has 50 tail frames — a +80 drag lands at +50.
        let e = editor([angleCutTrack()])
        #expect(e.clampedRollDelta(clipId: "left0000", edge: .right, deltaFrames: 80) == 50)
        e.rollEditPoint(clipId: "left0000", edge: .right, deltaFrames: 80, propagateToLinked: false)
        let clips = e.timeline.tracks[0].clips.sorted { $0.startFrame < $1.startFrame }
        #expect(clips[0].endFrame == 150)
        #expect(clips[0].trimEndFrame == 0)
        #expect(clips[1].startFrame == 150)
    }

    @Test func rollClampsToShrinkingSideMinimumDuration() {
        // Right is 100 frames; boundary can move at most +99 before it vanishes.
        let track = Fixtures.videoTrack(clips: [
            Fixtures.clip(id: "left0000", start: 0, duration: 100, trimEnd: 500),
            Fixtures.clip(id: "right000", start: 100, duration: 100, trimStart: 40),
        ])
        let e = editor([track])
        #expect(e.clampedRollDelta(clipId: "left0000", edge: .right, deltaFrames: 200) == 99)
    }

    @Test func rollWithGapDoesNothing() {
        let track = Fixtures.videoTrack(clips: [
            Fixtures.clip(id: "left0000", start: 0, duration: 100, trimEnd: 50),
            Fixtures.clip(id: "right000", start: 120, duration: 100, trimStart: 40),
        ])
        let e = editor([track])
        let before = e.timeline
        e.rollEditPoint(clipId: "left0000", edge: .right, deltaFrames: 20, propagateToLinked: false)
        #expect(e.timeline == before)
    }
}
