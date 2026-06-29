import Foundation

/// Aligns a text clip's words to transcript words overlapping its span
enum TextTimingSync {
    static func wordTimings(
        content: String,
        clipStart: Int,
        clipEnd: Int,
        transcriptWords: [(text: String, start: Int, end: Int)]
    ) -> [WordTiming]? {
        let tokens = content.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !tokens.isEmpty else { return nil }

        let region = transcriptWords
            .filter { $0.end > clipStart && $0.start < clipEnd }
            .sorted { $0.start < $1.start }
        guard !region.isEmpty else { return nil }

        // Matching is positional from the start, so it only holds when the text ≈ the words spoken here
        let tokensAlnum = tokens.reduce(0) { $0 + max(1, alnumCount($1)) }
        let regionAlnum = region.reduce(0) { $0 + max(1, alnumCount($1.text)) }
        guard Double(tokensAlnum) >= Double(regionAlnum) * 0.6 else { return nil }  // text ≥60% of spoken chars

        let dur = max(1, clipEnd - clipStart)
        var result: [WordTiming] = []
        var idx = 0
        // Consume transcript words per token by char count (not 1:1), so a split run like
        // "don"+"t" still lines up with the token "don't".
        for token in tokens {
            let want = max(1, alnumCount(token))
            var got = 0
            var first: Int?
            var last: Int?
            while idx < region.count, got < want {
                let w = region[idx]
                if first == nil { first = w.start }
                last = w.end
                got += max(1, alnumCount(w.text))
                idx += 1
            }
            guard let s = first, let e = last else { break }
            let rs = min(max(0, s - clipStart), dur - 1)
            let re = min(max(rs + 1, e - clipStart), dur)
            result.append(WordTiming(text: token, startFrame: rs, endFrame: re))
        }

        // Require a full alignment — the renderer ignores wordTimings unless the count matches.
        return result.count == tokens.count ? result : nil
    }

    private static func alnumCount(_ s: String) -> Int {
        s.reduce(0) { $0 + ($1.isLetter || $1.isNumber ? 1 : 0) }
    }
}
