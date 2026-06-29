import Testing
@testable import PalmierPro

@Suite("TextTimingSync")
struct TextTimingSyncTests {
    private func w(_ t: String, _ s: Int, _ e: Int) -> (text: String, start: Int, end: Int) { (t, s, e) }

    @Test func alignsMatchingWordsToTranscript() {
        let region = [w("Hello", 100, 110), w("world", 112, 120)]
        let timings = TextTimingSync.wordTimings(
            content: "Hello world", clipStart: 100, clipEnd: 130, transcriptWords: region)
        let t = try! #require(timings)
        #expect(t.count == 2)
        #expect(t[0].text == "Hello" && t[0].startFrame == 0 && t[0].endFrame == 10)
        #expect(t[1].text == "world" && t[1].startFrame == 12 && t[1].endFrame == 20)
    }

    @Test func clampsToClipSpan() {
        // A word whose end runs past the clip end clamps to the duration.
        let region = [w("Hi", 95, 145)]
        let t = try! #require(TextTimingSync.wordTimings(
            content: "Hi", clipStart: 100, clipEnd: 130, transcriptWords: region))
        #expect(t[0].startFrame == 0)        // start before clip → clamped to 0
        #expect(t[0].endFrame == 30)         // end past clip → clamped to duration
    }

    @Test func bailsWhenTextIsSmallSubsetOfSpeech() {
        // Text "peace" against a window of many spoken words → no clean match → nil (even spacing).
        let region = [w("I", 0, 5), w("really", 6, 12), w("want", 13, 18),
                      w("world", 19, 25), w("peace", 26, 32), w("right", 33, 38), w("now", 39, 44)]
        let t = TextTimingSync.wordTimings(content: "peace", clipStart: 0, clipEnd: 50, transcriptWords: region)
        #expect(t == nil)
    }

    @Test func nilWhenNoTranscriptInWindow() {
        let region = [w("later", 500, 510)]
        #expect(TextTimingSync.wordTimings(content: "Hello world", clipStart: 0, clipEnd: 100, transcriptWords: region) == nil)
    }

    @Test func mergesWordRunsByCharacterCount() {
        // Transcript split a contraction; token count differs from run count but chars line up.
        let region = [w("don", 10, 14), w("t", 14, 16), w("stop", 18, 26)]
        let t = try! #require(TextTimingSync.wordTimings(
            content: "don't stop", clipStart: 0, clipEnd: 40, transcriptWords: region))
        #expect(t.count == 2)
        #expect(t[0].text == "don't" && t[0].startFrame == 10)
        #expect(t[1].text == "stop" && t[1].startFrame == 18)
    }
}
