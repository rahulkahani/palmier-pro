import Foundation

/// "Who talks when" derived from per-mic energy envelopes — no STT required.
/// Pure math so it's unit-testable with synthetic envelopes.
enum SpeakerActivity {

    struct MicTrack: Sendable {
        let speaker: String
        /// RMS envelope samples (see `AudioEnvelopeExtractor`).
        let samples: [Float]
        let hopSeconds: Double
        /// Project frame corresponding to sample 0.
        let startFrame: Int
        /// Playback speed of the clip the envelope was read through (1.0 = realtime).
        let speed: Double

        init(speaker: String, samples: [Float], hopSeconds: Double, startFrame: Int, speed: Double = 1.0) {
            self.speaker = speaker
            self.samples = samples
            self.hopSeconds = hopSeconds
            self.startFrame = startFrame
            self.speed = speed
        }
    }

    struct Segment: Sendable, Equatable {
        let speaker: String
        let startFrame: Int
        let endFrame: Int
        /// Mean normalized level over the segment, 0…1.
        let confidence: Double
    }

    struct Options: Sendable {
        /// Segments shorter than this are dropped (micro-interjections, coughs).
        var minTurnFrames: Int = 8
        /// Silences up to this long inside one speaker's turn are bridged.
        var bridgeGapFrames: Int = 30
        /// Gate opens above this normalized level…
        var onLevel: Double = 0.25
        /// …and closes below this one (hysteresis).
        var offLevel: Double = 0.15
        /// A mic active at the same instant as a louder mic is treated as bleed
        /// when its normalized level is below this fraction of the loudest.
        var bleedRatio: Double = 0.5

        init() {}
    }

    /// Derives merged speaker segments (project frames) from per-mic envelopes.
    static func segments(mics: [MicTrack], fps: Int, options: Options = Options()) -> [Segment] {
        guard fps > 0, !mics.isEmpty else { return [] }

        // Per-mic normalized levels on each mic's own hop grid.
        let normalized: [[Double]] = mics.map { normalizedLevels($0.samples) }

        // Hysteresis-gate each mic into active hop spans.
        var activeHops: [[Bool]] = []
        for levels in normalized {
            var active = [Bool](repeating: false, count: levels.count)
            var open = false
            for (i, level) in levels.enumerated() {
                if open {
                    if level < options.offLevel { open = false }
                } else {
                    if level >= options.onLevel { open = true }
                }
                active[i] = open
            }
            activeHops.append(active)
        }

        // Bleed suppression: compare mics on a shared project-frame grid.
        // For each mic hop, find the loudest concurrently-active mic; drop the
        // hop when this mic is far quieter (its signal is another voice's bleed).
        func frame(ofHop hop: Int, mic: MicTrack) -> Int {
            mic.startFrame + Int((Double(hop) * mic.hopSeconds * Double(fps) / max(mic.speed, 0.0001)).rounded())
        }
        func hop(ofFrame frame: Int, mic: MicTrack) -> Int {
            let seconds = Double(frame - mic.startFrame) * max(mic.speed, 0.0001) / Double(fps)
            return Int((seconds / mic.hopSeconds).rounded())
        }

        for m in mics.indices {
            for h in activeHops[m].indices where activeHops[m][h] {
                let f = frame(ofHop: h, mic: mics[m])
                let own = normalized[m][h]
                var loudest = own
                for other in mics.indices where other != m {
                    let oh = hop(ofFrame: f, mic: mics[other])
                    guard activeHops[other].indices.contains(oh), activeHops[other][oh] else { continue }
                    loudest = max(loudest, normalized[other][oh])
                }
                if loudest > 0, own < loudest * options.bleedRatio {
                    activeHops[m][h] = false
                }
            }
        }

        // Collapse hops to frame spans, bridge short gaps, drop short turns.
        var out: [Segment] = []
        for m in mics.indices {
            let mic = mics[m]
            var spans: [(start: Int, end: Int, levelSum: Double, count: Int)] = []
            var h = 0
            while h < activeHops[m].count {
                guard activeHops[m][h] else { h += 1; continue }
                var j = h
                var levelSum = 0.0
                while j < activeHops[m].count, activeHops[m][j] {
                    levelSum += normalized[m][j]
                    j += 1
                }
                spans.append((frame(ofHop: h, mic: mic), frame(ofHop: j, mic: mic), levelSum, j - h))
                h = j
            }

            var merged: [(start: Int, end: Int, levelSum: Double, count: Int)] = []
            for span in spans {
                if var last = merged.last, span.start - last.end <= options.bridgeGapFrames {
                    last.end = max(last.end, span.end)
                    last.levelSum += span.levelSum
                    last.count += span.count
                    merged[merged.count - 1] = last
                } else {
                    merged.append(span)
                }
            }

            for span in merged where span.end - span.start >= options.minTurnFrames {
                let confidence = span.count > 0 ? min(1.0, span.levelSum / Double(span.count)) : 0
                out.append(Segment(
                    speaker: mic.speaker,
                    startFrame: span.start,
                    endFrame: span.end,
                    confidence: (confidence * 1000).rounded() / 1000
                ))
            }
        }
        return out.sorted { ($0.startFrame, $0.speaker) < ($1.startFrame, $1.speaker) }
    }

    /// Maps raw RMS samples onto 0…1 between the mic's noise floor and speech peak.
    static func normalizedLevels(_ samples: [Float]) -> [Double] {
        guard !samples.isEmpty else { return [] }
        let sorted = samples.sorted()
        let floor = Double(sorted[min(sorted.count - 1, sorted.count / 5)])          // 20th percentile
        let peak = Double(sorted[min(sorted.count - 1, sorted.count * 95 / 100)])    // 95th percentile
        let range = peak - floor
        guard range > 1e-9 else { return [Double](repeating: 0, count: samples.count) }
        return samples.map { max(0, min(1, (Double($0) - floor) / range)) }
    }
}
