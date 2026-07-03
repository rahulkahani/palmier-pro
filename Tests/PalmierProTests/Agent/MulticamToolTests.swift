import Foundation
import Testing
@testable import PalmierPro

@Suite("Multicam — offset math")
struct MulticamOffsetMathTests {

    @Test func convertedTrimStartUsesOffsetDifference() {
        let a = MulticamGroup.Member(mediaRef: "a", role: .camera, syncOffsetFrames: 0)
        let b = MulticamGroup.Member(mediaRef: "b", role: .camera, syncOffsetFrames: 60)

        // Group time at a's trim 100 is 100; b shows it at source 40.
        #expect(MulticamGroup.convertedTrimStart(100, from: a, to: b) == 40)
        // Reverse direction adds the offset back.
        #expect(MulticamGroup.convertedTrimStart(40, from: b, to: a) == 100)
        // Before b started recording → negative (caller must reject).
        #expect(MulticamGroup.convertedTrimStart(10, from: a, to: b) == -50)
    }

    @Test func manifestRoundTripsGroups() throws {
        var manifest = MediaManifest()
        manifest.multicamGroups = [MulticamGroup(
            name: "Episode 1",
            members: [
                MulticamGroup.Member(mediaRef: "cam-wide", role: .camera),
                MulticamGroup.Member(mediaRef: "mic-alice", role: .mic, syncOffsetFrames: 12, speaker: "Alice"),
            ]
        )]
        let data = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(MediaManifest.self, from: data)
        #expect(decoded.multicamGroups == manifest.multicamGroups)
    }

    @Test func manifestWithoutGroupsKeyDecodes() throws {
        let json = #"{"version": 2, "entries": [], "folders": []}"#
        let decoded = try JSONDecoder().decode(MediaManifest.self, from: Data(json.utf8))
        #expect(decoded.multicamGroups.isEmpty)
    }
}

@Suite("ToolExecutor — create_multicam")
@MainActor
struct CreateMulticamTests {

    private func harness() -> ToolHarness {
        let h = ToolHarness(timeline: Fixtures.timeline())
        h.addAsset(id: "cam-alice-0000", type: .video, duration: 10)
        h.addAsset(id: "cam-wide-00000", type: .video, duration: 10)
        h.addAsset(id: "mic-alice-0000", type: .audio, duration: 10)
        h.addAsset(id: "mic-bob-000000", type: .audio, duration: 10)
        return h
    }

    private func createArgs(offsets: [Int] = [0, 0, 0, 0]) -> [String: Any] {
        [
            "name": "Episode 1",
            "sync": false,
            "members": [
                ["mediaRef": "cam-alice-0000", "role": "camera", "speaker": "Alice", "syncOffsetFrames": offsets[0]],
                ["mediaRef": "cam-wide-00000", "role": "camera", "syncOffsetFrames": offsets[1]],
                ["mediaRef": "mic-alice-0000", "role": "mic", "speaker": "Alice", "syncOffsetFrames": offsets[2]],
                ["mediaRef": "mic-bob-000000", "role": "mic", "speaker": "Bob", "syncOffsetFrames": offsets[3]],
            ],
        ]
    }

    @Test func persistsGroupAndLaysOutTracks() async throws {
        let h = harness()
        let result = try await h.runOK("create_multicam", args: createArgs()) as? [String: Any]

        #expect(h.editor.multicamGroups.count == 1)
        let group = try #require(h.editor.multicamGroups.first)
        #expect(group.name == "Episode 1")
        #expect(group.cameras.count == 2)
        #expect(group.mics.count == 2)
        #expect(group.member(for: "mic-bob-000000")?.speaker == "Bob")

        // One program video track + one audio track per mic, all sync-locked.
        #expect(result?["programTrackIndex"] as? Int == 0)
        #expect(h.editor.timeline.tracks.count == 3)
        #expect(h.editor.timeline.tracks[0].type == .video)
        #expect(h.editor.timeline.tracks[1].type == .audio)
        #expect(h.editor.timeline.tracks[2].type == .audio)
        #expect(h.editor.timeline.tracks.allSatisfy(\.syncLocked))
        // Default camera (first) on the program track; mics full length.
        #expect(h.editor.timeline.tracks[0].clips.first?.mediaRef == "cam-alice-0000")
        #expect(h.editor.timeline.tracks[1].clips.count == 1)
        #expect(h.editor.timeline.tracks[2].clips.count == 1)
    }

    @Test func layoutPositionsMembersBySyncOffset() async throws {
        let h = harness()
        // Wide cam started 30 frames after the earliest member.
        _ = try await h.runOK("create_multicam", args: createArgs(offsets: [0, 30, 0, 15]))

        let program = h.editor.timeline.tracks[0].clips
        #expect(program.first?.startFrame == 0)
        let micAlice = h.editor.timeline.tracks[1].clips.first
        let micBob = h.editor.timeline.tracks[2].clips.first
        #expect(micAlice?.startFrame == 0)
        #expect(micBob?.startFrame == 15)
    }

    @Test func rejectsAudioAssetAsCamera() async {
        let h = harness()
        let result = await h.runRaw("create_multicam", args: [
            "sync": false,
            "members": [
                ["mediaRef": "mic-alice-0000", "role": "camera"],
                ["mediaRef": "cam-wide-00000", "role": "camera"],
            ],
        ])
        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("camera members must be video"))
    }

    @Test func layoutFalseLeavesTimelineUntouched() async throws {
        let h = harness()
        var args = createArgs()
        args["layout"] = false
        _ = try await h.runOK("create_multicam", args: args)
        #expect(h.editor.timeline.tracks.isEmpty)
        #expect(h.editor.multicamGroups.count == 1)
    }
}

@Suite("ToolExecutor — switch_angle")
@MainActor
struct SwitchAngleTests {

    /// Program track with one 300-frame clip of camera A; group has camera B
    /// whose recording started 60 group-frames later (offset 60).
    private func harness(camAOffset: Int = 0, camBOffset: Int = 60) -> ToolHarness {
        let h = ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [
                Fixtures.clip(id: "program-clip-01", mediaRef: "cam-a-00000000", start: 0, duration: 300, trimEnd: 0),
            ]),
        ]))
        h.addAsset(id: "cam-a-00000000", type: .video, duration: 10) // 300 frames @30
        h.addAsset(id: "cam-b-00000000", type: .video, duration: 10)
        h.editor.mediaManifest.multicamGroups = [MulticamGroup(
            id: "group-00000000",
            name: "Test",
            members: [
                MulticamGroup.Member(mediaRef: "cam-a-00000000", role: .camera, syncOffsetFrames: camAOffset, speaker: "Alice"),
                MulticamGroup.Member(mediaRef: "cam-b-00000000", role: .camera, syncOffsetFrames: camBOffset, speaker: "Bob"),
            ]
        )]
        return h
    }

    @Test func switchesMiddleRangeWithOffsetCorrectedTrim() async throws {
        let h = harness()
        let result = try await h.runOK("switch_angle", args: [
            "trackIndex": 0,
            "switches": [["startFrame": 100, "endFrame": 200, "mediaRef": "cam-b-00000000"]],
        ]) as? [String: Any]

        #expect(result?["switched"] as? Int == 1)
        #expect(result?["splits"] as? Int == 2)

        let clips = h.editor.timeline.tracks[0].clips.sorted { $0.startFrame < $1.startFrame }
        #expect(clips.count == 3)
        // Left third untouched.
        #expect(clips[0].mediaRef == "cam-a-00000000")
        #expect(clips[0].startFrame == 0 && clips[0].durationFrames == 100)
        // Middle switched: source position corrected by the offset difference.
        // Group time at frame 100 = trim 100 in A; B shows it at 100 - 60 = 40.
        #expect(clips[1].mediaRef == "cam-b-00000000")
        #expect(clips[1].startFrame == 100 && clips[1].durationFrames == 100)
        #expect(clips[1].trimStartFrame == 40)
        // 300-frame source: trimEnd = 300 - 40 - 100.
        #expect(clips[1].trimEndFrame == 160)
        // Right third untouched.
        #expect(clips[2].mediaRef == "cam-a-00000000")
        #expect(clips[2].startFrame == 200 && clips[2].trimStartFrame == 200)
    }

    @Test func contentTimeNeverShifts() async throws {
        let h = harness()
        _ = try await h.runOK("switch_angle", args: [
            "trackIndex": 0,
            "switches": [["startFrame": 100, "endFrame": 200, "mediaRef": "cam-b-00000000"]],
        ])
        let clips = h.editor.timeline.tracks[0].clips.sorted { $0.startFrame < $1.startFrame }
        // No gaps, no overlaps, same total extent.
        #expect(clips[0].endFrame == clips[1].startFrame)
        #expect(clips[1].endFrame == clips[2].startFrame)
        #expect(clips.last?.endFrame == 300)
    }

    @Test func skipsRangeWhereTargetWasNotRecording() async throws {
        let h = harness()
        // Frames 0..50 map to B source −60..−10 — B wasn't rolling yet.
        let result = await h.runRaw("switch_angle", args: [
            "trackIndex": 0,
            "switches": [["startFrame": 0, "endFrame": 50, "mediaRef": "cam-b-00000000"]],
        ])
        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("wasn't recording"))
        // Program clip may have been split, but every fragment still shows camera A.
        #expect(h.editor.timeline.tracks[0].clips.allSatisfy { $0.mediaRef == "cam-a-00000000" })
    }

    @Test func rejectsNonGroupMedia() async {
        let h = harness()
        h.addAsset(id: "loose-video-00", type: .video, duration: 10)
        let result = await h.runRaw("switch_angle", args: [
            "trackIndex": 0,
            "switches": [["startFrame": 100, "endFrame": 200, "mediaRef": "loose-video-00"]],
        ])
        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("not a member of any multicam group"))
    }

    @Test func batchedSwitchesApplyInOneCall() async throws {
        let h = harness(camBOffset: 0)
        let result = try await h.runOK("switch_angle", args: [
            "trackIndex": 0,
            "switches": [
                ["startFrame": 50, "endFrame": 100, "mediaRef": "cam-b-00000000"],
                ["startFrame": 150, "endFrame": 200, "mediaRef": "cam-b-00000000"],
            ],
        ]) as? [String: Any]
        #expect(result?["switched"] as? Int == 2)
        let byB = h.editor.timeline.tracks[0].clips.filter { $0.mediaRef == "cam-b-00000000" }
        #expect(byB.map(\.startFrame).sorted() == [50, 150])
        #expect(byB.allSatisfy { $0.trimStartFrame == $0.startFrame })
    }
}

@Suite("ToolExecutor — switch_angle layouts")
@MainActor
struct SwitchAngleLayoutTests {

    /// Program track with one 300-frame clip of camera A; camera B offset +60.
    private func harness() -> ToolHarness {
        let h = ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [
                Fixtures.clip(id: "program-clip-01", mediaRef: "cam-a-00000000", start: 0, duration: 300),
            ]),
        ]))
        h.addAsset(id: "cam-a-00000000", type: .video, duration: 10)
        h.addAsset(id: "cam-b-00000000", type: .video, duration: 10)
        h.editor.mediaManifest.multicamGroups = [MulticamGroup(
            id: "group-00000000", name: "Test",
            members: [
                MulticamGroup.Member(mediaRef: "cam-a-00000000", role: .camera, syncOffsetFrames: 0, speaker: "Alice"),
                MulticamGroup.Member(mediaRef: "cam-b-00000000", role: .camera, syncOffsetFrames: 60, speaker: "Bob"),
            ]
        )]
        return h
    }

    @Test func sideBySidePlacesOverlayWithOffsetCorrectedTrim() async throws {
        let h = harness()
        let result = try await h.runOK("switch_angle", args: [
            "trackIndex": 0,
            "switches": [[
                "startFrame": 100, "endFrame": 200,
                "layout": "side_by_side",
                "slots": [
                    ["slot": "left", "mediaRef": "cam-a-00000000"],
                    ["slot": "right", "mediaRef": "cam-b-00000000"],
                ],
            ]],
        ]) as? [String: Any]

        #expect(result?["overlayClips"] as? Int == 1)
        #expect(result?["createdOverlayTracks"] as? Int == 1)

        // Overlay track inserted above the program track.
        #expect(h.editor.timeline.tracks.count == 2)
        let overlay = h.editor.timeline.tracks[0]
        let program = h.editor.timeline.tracks[1]

        // Program's middle segment keeps camera A but is framed into the left half.
        let mid = try #require(program.clips.first { $0.startFrame == 100 })
        #expect(mid.mediaRef == "cam-a-00000000")
        #expect(abs(mid.transform.width - 0.5) < 0.001)
        #expect(abs(mid.transform.centerX - 0.25) < 0.001)

        // Overlay shows camera B over the same span with the offset-corrected trim.
        let over = try #require(overlay.clips.first)
        #expect(over.mediaRef == "cam-b-00000000")
        #expect(over.startFrame == 100 && over.endFrame == 200)
        #expect(over.trimStartFrame == 40)
        #expect(abs(over.transform.centerX - 0.75) < 0.001)
    }

    @Test func fullFrameEntryEndsLayoutInSameCall() async throws {
        let h = harness()
        _ = try await h.runOK("switch_angle", args: [
            "trackIndex": 0,
            "switches": [
                [
                    "startFrame": 100, "endFrame": 200,
                    "layout": "side_by_side",
                    "slots": [
                        ["slot": "left", "mediaRef": "cam-a-00000000"],
                        ["slot": "right", "mediaRef": "cam-b-00000000"],
                    ],
                ],
                ["startFrame": 100, "endFrame": 200, "mediaRef": "cam-a-00000000"],
            ],
        ])

        // Overlay cleared, program restored to full-frame camera A.
        let overlay = h.editor.timeline.tracks[0]
        #expect(overlay.clips.isEmpty)
        let program = h.editor.timeline.tracks[1]
        let mid = try #require(program.clips.first { $0.startFrame == 100 })
        #expect(mid.mediaRef == "cam-a-00000000")
        #expect(abs(mid.transform.width - 1.0) < 0.001)
    }

    @Test func layoutRejectsMissingSlots() async {
        let h = harness()
        let result = await h.runRaw("switch_angle", args: [
            "trackIndex": 0,
            "switches": [[
                "startFrame": 100, "endFrame": 200,
                "layout": "side_by_side",
                "slots": [["slot": "left", "mediaRef": "cam-a-00000000"]],
            ]],
        ])
        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("every slot filled"))
    }

    @Test func layoutSkipsWhenAnAngleWasNotRecording() async {
        let h = harness()
        // Frames 0..50 → camera B source −60..−10.
        let result = await h.runRaw("switch_angle", args: [
            "trackIndex": 0,
            "switches": [[
                "startFrame": 0, "endFrame": 50,
                "layout": "side_by_side",
                "slots": [
                    ["slot": "left", "mediaRef": "cam-a-00000000"],
                    ["slot": "right", "mediaRef": "cam-b-00000000"],
                ],
            ]],
        ])
        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("wasn't recording"))
        // Nothing placed, nothing split.
        #expect(h.editor.timeline.tracks.count == 1)
        #expect(h.editor.timeline.tracks[0].clips.count == 1)
    }

    @Test func rejectsMixingMediaRefAndLayout() async {
        let h = harness()
        let result = await h.runRaw("switch_angle", args: [
            "trackIndex": 0,
            "switches": [[
                "startFrame": 100, "endFrame": 200,
                "mediaRef": "cam-b-00000000",
                "layout": "side_by_side",
                "slots": [
                    ["slot": "left", "mediaRef": "cam-a-00000000"],
                    ["slot": "right", "mediaRef": "cam-b-00000000"],
                ],
            ]],
        ])
        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("exactly one of"))
    }
}

@Suite("ToolExecutor — set_multicam_speakers")
@MainActor
struct SetMulticamSpeakersTests {

    @Test func updatesSpeakerMapping() async throws {
        let h = ToolHarness(timeline: Fixtures.timeline())
        h.addAsset(id: "mic-1-00000000", type: .audio, duration: 10)
        h.editor.mediaManifest.multicamGroups = [MulticamGroup(
            id: "group-00000000", name: "Test",
            members: [MulticamGroup.Member(mediaRef: "mic-1-00000000", role: .mic)]
        )]

        _ = await h.runRaw("set_multicam_speakers", args: [
            "groupId": "group-00000000",
            "speakers": [["mediaRef": "mic-1-00000000", "speaker": "Alice"]],
        ])
        #expect(h.editor.multicamGroups.first?.members.first?.speaker == "Alice")
    }

    @Test func rejectsNonMember() async {
        let h = ToolHarness(timeline: Fixtures.timeline())
        h.addAsset(id: "mic-1-00000000", type: .audio, duration: 10)
        h.addAsset(id: "other-00000000", type: .audio, duration: 10)
        h.editor.mediaManifest.multicamGroups = [MulticamGroup(
            id: "group-00000000", name: "Test",
            members: [MulticamGroup.Member(mediaRef: "mic-1-00000000", role: .mic)]
        )]
        let result = await h.runRaw("set_multicam_speakers", args: [
            "groupId": "group-00000000",
            "speakers": [["mediaRef": "other-00000000", "speaker": "Bob"]],
        ])
        #expect(result.isError)
    }
}

@Suite("Multicam — ripple alignment")
@MainActor
struct MulticamRippleAlignmentTests {

    /// A multicam layout (program cam + two mics, all sync-locked) must stay
    /// aligned through a word-cut style ripple delete on a mic track.
    @Test func rippleDeletePreservesGroupAlignment() async throws {
        let h = ToolHarness(timeline: Fixtures.timeline())
        h.addAsset(id: "cam-a-00000000", type: .video, duration: 10)
        h.addAsset(id: "mic-1-00000000", type: .audio, duration: 10)
        h.addAsset(id: "mic-2-00000000", type: .audio, duration: 10)
        _ = try await h.runOK("create_multicam", args: [
            "sync": false,
            "members": [
                ["mediaRef": "cam-a-00000000", "role": "camera"],
                ["mediaRef": "mic-1-00000000", "role": "mic", "speaker": "Alice"],
                ["mediaRef": "mic-2-00000000", "role": "mic", "speaker": "Bob"],
            ],
        ])

        // Cut frames [100, 130) on Alice's mic track (index 1) — dead air removal.
        _ = try await h.runOK("ripple_delete_ranges", args: [
            "trackIndex": 1,
            "ranges": [[100, 130]],
            "units": "frames",
        ])

        // Every track absorbed the same 30-frame cut...
        for track in h.editor.timeline.tracks {
            #expect(track.endFrame == 270, "track should end at 270 after cutting 30 frames")
        }
        // ...and the fragments after the cut resume at the same source position,
        // so group-time alignment holds across camera and mics.
        for track in h.editor.timeline.tracks {
            let fragment = try #require(track.clips.first { $0.startFrame == 100 })
            #expect(fragment.trimStartFrame == 130)
        }
    }
}
