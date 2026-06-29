import Foundation

struct WordTiming: Codable, Sendable, Equatable {
    var text: String
    var startFrame: Int
    var endFrame: Int
}

struct TextAnimation: Codable, Sendable, Equatable {
    var preset: Preset = .none
    var perWordFrames: Int = 6
    var highlight: TextStyle.RGBA?

    enum Preset: String, Codable, CaseIterable, Sendable {
        case none
        // Whole-clip entrance.
        case fadeIn, popIn, slideUp
        // Karaoke (per word).
        case wordPop, wordReveal, highlightPop, karaokeFill

        var isPerWord: Bool {
            switch self {
            case .wordPop, .wordReveal, .highlightPop, .karaokeFill: true
            default: false
            }
        }

        var usesHighlight: Bool {
            switch self {
            case .highlightPop, .karaokeFill: true
            default: false
            }
        }

        var displayName: String {
            switch self {
            case .none: "Off"
            case .fadeIn: "Fade In"
            case .popIn: "Pop In"
            case .slideUp: "Slide Up"
            case .wordPop: "Word Pop"
            case .wordReveal: "Word Reveal"
            case .highlightPop: "Highlight"
            case .karaokeFill: "Karaoke Fill"
            }
        }

        static let entrance: [Preset] = [.fadeIn, .popIn, .slideUp]
        static let karaoke: [Preset] = [.wordPop, .wordReveal, .highlightPop, .karaokeFill]
    }

    var isActive: Bool { preset != .none }

    static let defaultHighlight = TextStyle.RGBA(r: 1, g: 0.85, b: 0, a: 1)

    private enum CodingKeys: String, CodingKey { case preset, perWordFrames, highlight }

    init(preset: Preset = .none, perWordFrames: Int = 6, highlight: TextStyle.RGBA? = nil) {
        self.preset = preset
        self.perWordFrames = perWordFrames
        self.highlight = highlight
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            preset: (try? c.decode(Preset.self, forKey: .preset)) ?? .none,
            perWordFrames: (try? c.decode(Int.self, forKey: .perWordFrames)) ?? 6,
            highlight: try? c.decode(TextStyle.RGBA.self, forKey: .highlight)
        )
    }
}
