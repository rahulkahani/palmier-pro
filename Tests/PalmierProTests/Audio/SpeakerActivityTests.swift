import Foundation
import Testing
@testable import PalmierPro

@Suite("SpeakerActivity — VAD segmentation")
struct SpeakerActivityTests {

    /// hop = exactly one project frame at 30fps, so hops map 1:1 to frames.
    private let hop = 1.0 / 30.0
    private let fps = 30

    private func envelope(length: Int, loud: [Range<Int>], loudLevel: Float = 1.0, quietLevel: Float = 0.01) -> [Float] {
        var samples = [Float](repeating: quietLevel, count: length)
        for range in loud {
            for i in range where i < length { samples[i] = loudLevel }
        }
        return samples
    }

    private func mic(_ speaker: String, samples: [Float], startFrame: Int = 0) -> SpeakerActivity.MicTrack {
        SpeakerActivity.MicTrack(speaker: speaker, samples: samples, hopSeconds: hop, startFrame: startFrame)
    }

    @Test func singleSpeechSpanBecomesOneSegment() {
        let mics = [mic("Alice", samples: envelope(length: 200, loud: [20..<60]))]
        let segments = SpeakerActivity.segments(mics: mics, fps: fps)

        #expect(segments.count == 1)
        let seg = segments[0]
        #expect(seg.speaker == "Alice")
        #expect(abs(seg.startFrame - 20) <= 1)
        #expect(abs(seg.endFrame - 60) <= 1)
        #expect(seg.confidence > 0.5 && seg.confidence <= 1.0)
    }

    @Test func shortGapsAreBridged() {
        var options = SpeakerActivity.Options()
        options.bridgeGapFrames = 15
        let mics = [mic("Alice", samples: envelope(length: 200, loud: [20..<50, 60..<90]))]
        let segments = SpeakerActivity.segments(mics: mics, fps: fps, options: options)

        #expect(segments.count == 1)
        #expect(abs(segments[0].startFrame - 20) <= 1)
        #expect(abs(segments[0].endFrame - 90) <= 1)
    }

    @Test func longGapsSplitTurns() {
        var options = SpeakerActivity.Options()
        options.bridgeGapFrames = 15
        let mics = [mic("Alice", samples: envelope(length: 200, loud: [20..<50, 120..<150]))]
        let segments = SpeakerActivity.segments(mics: mics, fps: fps, options: options)
        #expect(segments.count == 2)
    }

    @Test func microInterjectionsAreDropped() {
        var options = SpeakerActivity.Options()
        options.minTurnFrames = 10
        options.bridgeGapFrames = 5
        let mics = [mic("Alice", samples: envelope(length: 200, loud: [20..<24]))]
        let segments = SpeakerActivity.segments(mics: mics, fps: fps, options: options)
        #expect(segments.isEmpty)
    }

    @Test func bleedFromLouderMicIsSuppressed() {
        // Alice speaks at 20..60. Bob's mic picks her up quietly (bleed) while
        // Bob really speaks at 100..140.
        var bobSamples = envelope(length: 200, loud: [100..<140])
        for i in 20..<60 { bobSamples[i] = 0.3 }
        let mics = [
            mic("Alice", samples: envelope(length: 200, loud: [20..<60])),
            mic("Bob", samples: bobSamples),
        ]
        let segments = SpeakerActivity.segments(mics: mics, fps: fps)

        let bobSegments = segments.filter { $0.speaker == "Bob" }
        #expect(bobSegments.count == 1)
        #expect(abs(bobSegments[0].startFrame - 100) <= 1)
        let aliceSegments = segments.filter { $0.speaker == "Alice" }
        #expect(aliceSegments.count == 1)
    }

    @Test func genuineCrosstalkIsKeptForBothSpeakers() {
        // Both speak loudly over 40..80 — neither is bleed.
        let mics = [
            mic("Alice", samples: envelope(length: 200, loud: [20..<80])),
            mic("Bob", samples: envelope(length: 200, loud: [40..<100])),
        ]
        let segments = SpeakerActivity.segments(mics: mics, fps: fps)
        #expect(segments.contains { $0.speaker == "Alice" })
        #expect(segments.contains { $0.speaker == "Bob" })
    }

    @Test func startFrameOffsetsMapIntoProjectFrames() {
        let mics = [mic("Alice", samples: envelope(length: 100, loud: [10..<40]), startFrame: 500)]
        let segments = SpeakerActivity.segments(mics: mics, fps: fps)
        #expect(segments.count == 1)
        #expect(abs(segments[0].startFrame - 510) <= 1)
        #expect(abs(segments[0].endFrame - 540) <= 1)
    }

    @Test func silentEnvelopeYieldsNoSegments() {
        let mics = [mic("Alice", samples: [Float](repeating: 0.01, count: 200))]
        #expect(SpeakerActivity.segments(mics: mics, fps: fps).isEmpty)
    }

    @Test func normalizedLevelsSpanZeroToOne() {
        let levels = SpeakerActivity.normalizedLevels(envelope(length: 100, loud: [50..<70]))
        #expect(levels.allSatisfy { $0 >= 0 && $0 <= 1 })
        #expect(levels[55] > 0.9)
        #expect(levels[10] < 0.1)
    }
}
