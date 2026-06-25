import Accelerate
import AVFoundation
import Foundation

/// Extracts a peak amplitude envelope for timeline waveform display.
///
/// Unlike an averaged envelope, each bucket stores the loudest sample it spans, so
/// transients (drum hits, consonants) keep their height instead of being smoothed
/// toward the noise floor. Output matches the draw convention: 0 = full scale, 1 =
/// at/below the noise floor.
enum WaveformExtractor {
    static let samplesPerSecond: Double = 200
    static let noiseFloorDb: Float = -50
    /// Resolution ceiling. Below ~20 min this never binds; longer assets taper so a
    /// 2-hour file stays ~240k samples instead of growing without bound.
    static let maxSamples = 240_000

    static func peakEnvelope(from url: URL, range: ClosedRange<Double>? = nil) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        let span = range.map { $0.upperBound - $0.lowerBound } ?? duration
        let rate = span > 0 ? min(samplesPerSecond, Double(maxSamples) / span) : samplesPerSecond

        var out: [Float] = []
        var carryPeak: Float = 0
        var carryCount = 0
        var hopSize = 0

        try await AudioTrackReader.read(from: url, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ], range: range) { pcm in
            if hopSize == 0 {
                hopSize = max(1, Int((pcm.format.sampleRate / rate).rounded()))
            }
            guard let channel = pcm.floatChannelData else { return }
            let ptr = channel[0]
            let count = Int(pcm.frameLength)
            var i = 0
            while i < count {
                let take = min(hopSize - carryCount, count - i)
                var localMax: Float = 0
                vDSP_maxmgv(ptr + i, 1, &localMax, vDSP_Length(take))
                if localMax > carryPeak { carryPeak = localMax }
                carryCount += take
                i += take
                if carryCount == hopSize {
                    out.append(normalized(peak: carryPeak))
                    carryPeak = 0
                    carryCount = 0
                }
            }
        }
        if carryCount > 0 { out.append(normalized(peak: carryPeak)) }
        return out
    }

    /// Linear peak → normalized dB position. 0 dBFS → 0, ≤ noise floor → 1.
    private static func normalized(peak: Float) -> Float {
        guard peak > 0 else { return 1 }
        let db = 20 * log10(peak)
        let clamped = min(0, max(noiseFloorDb, db))
        return clamped / noiseFloorDb
    }
}
