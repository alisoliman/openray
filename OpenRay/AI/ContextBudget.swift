import Foundation

// Fitting conversations and attachments into the model's context window. The window is
// read at runtime (`SystemLanguageModel.contextSize`) and every piece is measured with
// `tokenCount(for:)`; nothing here assumes a size. Tests drive it with a fake counter.

/// Measures text in the active model's tokens.
@MainActor
protocol AITokenCounting {
    func tokenCount(_ text: String) async -> Int
    func contextSize() async -> Int
}

/// Writes a faithful summary on its own session.
@MainActor
protocol AISummarizing {
    func summarize(_ text: String, focus: String) async throws -> String
}

/// The arithmetic of one request's context: what has to fit, and what to fold away.
struct ContextBudget: Equatable, Sendable {
    /// The whole window, in tokens.
    var contextSize: Int
    /// Kept free for the reply.
    var responseReserve: Int
    /// Condense once a request would fill this share of what's left after the reply.
    var condenseAt = 0.85
    /// Room kept for the rolling summary when condensing.
    var summaryReserve: Int

    init(contextSize: Int, responseReserve: Int, condenseAt: Double = 0.85) {
        self.contextSize = max(1, contextSize)
        self.responseReserve = min(max(0, responseReserve), self.contextSize / 3)
        self.condenseAt = condenseAt
        summaryReserve = max(64, self.contextSize / 8)
    }

    /// Tokens a prompt, its instructions, tools and history may use.
    var available: Int { contextSize - responseReserve }
    /// The point at which older turns are folded into the summary.
    var threshold: Int { Int(Double(available) * condenseAt) }
    /// The most a single attachment may take before it's summarized in parts.
    var attachmentBudget: Int { max(64, available / 2) }
    /// The size of each part a long attachment is split into for map-reduce.
    var chunkBudget: Int { max(48, available / 3) }

    enum Decision: Equatable, Sendable {
        /// Everything fits as it is.
        case fits
        /// Fold all but the last `keepingLast` turns into the summary.
        case condense(keepingLast: Int)
        /// The new prompt alone, with instructions and tools, doesn't fit.
        case tooLarge
    }

    /// `fixed` is what every request carries (instructions, summary, tools and the new prompt);
    /// `turns` are earlier exchanges, oldest first.
    func decide(fixed: Int, turns: [Int]) -> Decision {
        let total = fixed + turns.reduce(0, +)
        if total <= threshold { return .fits }
        guard fixed + summaryReserve <= available else { return fixed <= available && turns.isEmpty ? .fits : .tooLarge }
        var used = fixed + summaryReserve
        var kept = 0
        for turn in turns.reversed() {
            guard used + turn <= threshold else { break }
            used += turn
            kept += 1
        }
        // Folding nothing would change nothing; fold at least the oldest turn.
        return .condense(keepingLast: min(kept, max(0, turns.count - 1)))
    }
}

enum ContextBudgetError: LocalizedError, Equatable {
    case attachmentTooLong
    var errorDescription: String? {
        "The attachment is too long to summarize on this Mac. Attach a shorter part of it."
    }
}

/// Map-reduce for text that doesn't fit: split it into parts that do, summarize each on
/// its own session, then join the summaries, repeating until the result fits.
@MainActor
struct AttachmentCondenser {
    let counter: any AITokenCounting
    let summarizer: any AISummarizing
    /// Rounds of reduce before giving up.
    var maximumRounds = 3

    struct Result: Equatable {
        var text: String
        var wasCondensed: Bool
        /// Summaries written, for tests and progress.
        var summaries: Int
    }

    func fit(_ text: String, within budget: Int, chunkBudget: Int, focus: String) async throws -> Result {
        var current = text
        var summaries = 0
        for _ in 0...maximumRounds {
            if await counter.tokenCount(current) <= budget {
                return Result(text: current, wasCondensed: summaries > 0, summaries: summaries)
            }
            try Task.checkCancellation()
            let chunks = await split(current, maximumTokens: chunkBudget)
            var parts: [String] = []
            for (index, chunk) in chunks.enumerated() {
                try Task.checkCancellation()
                let label = chunks.count > 1 ? " (part \(index + 1) of \(chunks.count))" : ""
                parts.append(try await summarizer.summarize(chunk, focus: focus + label))
                summaries += 1
            }
            let joined = parts.joined(separator: "\n\n")
            // A reduce that doesn't shrink the text would loop forever.
            let before = await counter.tokenCount(current)
            let after = await counter.tokenCount(joined)
            guard after < before else {
                throw ContextBudgetError.attachmentTooLong
            }
            current = joined
        }
        throw ContextBudgetError.attachmentTooLong
    }

    /// Paragraphs packed into parts under `maximumTokens`; a paragraph too long on its own
    /// is split at sentence ends, then at words.
    func split(_ text: String, maximumTokens: Int) async -> [String] {
        var pieces: [String] = []
        for paragraph in text.components(separatedBy: "\n\n") where !paragraph.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if await counter.tokenCount(paragraph) <= maximumTokens {
                pieces.append(paragraph)
            } else {
                pieces += await splitLong(paragraph, maximumTokens: maximumTokens)
            }
        }
        var chunks: [String] = []
        var current = ""
        for piece in pieces {
            let candidate = current.isEmpty ? piece : current + "\n\n" + piece
            let fits = current.isEmpty ? true : await counter.tokenCount(candidate) <= maximumTokens
            if fits {
                current = candidate
            } else {
                chunks.append(current)
                current = piece
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    private func splitLong(_ text: String, maximumTokens: Int) async -> [String] {
        var sentences: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { sentence, _, _, _ in
            if let sentence { sentences.append(sentence) }
        }
        if sentences.count <= 1 { sentences = text.split(separator: " ").map(String.init) }
        var parts: [String] = []
        var current = ""
        for sentence in sentences {
            let candidate = current.isEmpty ? sentence : current + " " + sentence
            let fits = current.isEmpty ? true : await counter.tokenCount(candidate) <= maximumTokens
            if fits {
                current = candidate
            } else {
                parts.append(current)
                current = sentence
            }
        }
        if !current.isEmpty { parts.append(current) }
        // A "word" with no breaks (a URL, minified code) can still be too long: halve it.
        var bounded: [String] = []
        for part in parts { bounded += await fitting(part, maximumTokens: maximumTokens) }
        return bounded
    }

    /// `text` in pieces that each fit, split at character midpoints. Bounded depth, so a
    /// counter that never says yes can't recurse forever.
    private func fitting(_ text: String, maximumTokens: Int, depth: Int = 0) async -> [String] {
        guard text.count > 1, depth < 24, await counter.tokenCount(text) > maximumTokens else { return [text] }
        let middle = text.index(text.startIndex, offsetBy: text.count / 2)
        let first = await fitting(String(text[..<middle]), maximumTokens: maximumTokens, depth: depth + 1)
        let second = await fitting(String(text[middle...]), maximumTokens: maximumTokens, depth: depth + 1)
        return first + second
    }
}

/// Keeps a chat inside the window: before each turn it measures instructions, summary,
/// tools, the new prompt and earlier turns, and when they'd overflow it folds the oldest
/// turns into a rolling summary and has the engine rebuild its session from that.
@MainActor
struct ChatCondenser {
    let counter: any AITokenCounting
    let summarizer: any AISummarizing

    struct Outcome: Equatable {
        /// The summary after this turn, which may be unchanged.
        var summary: String?
        /// How many earlier turns were folded into it now.
        var foldedTurns: Int
        /// The context the engine must rebuild from, when something was folded.
        var rebuilt: AIConversationContext?
    }

    func prepare(
        profile: AIRequestProfile, summary: String?, turns: [AIConversationContext.Turn], prompt: String,
        toolTokens: Int
    ) async throws -> Outcome {
        let budget = ContextBudget(
            contextSize: await counter.contextSize(), responseReserve: profile.maximumResponseTokens ?? 900)
        let context = AIConversationContext(profile: profile, summary: summary, turns: [])
        let fixed = await counter.tokenCount(context.instructions) + (await counter.tokenCount(prompt)) + toolTokens
        var turnTokens: [Int] = []
        for turn in turns { turnTokens.append(await counter.tokenCount(turn.prompt + "\n" + turn.response)) }
        switch budget.decide(fixed: fixed, turns: turnTokens) {
        case .fits:
            return Outcome(summary: summary, foldedTurns: 0, rebuilt: nil)
        case .tooLarge:
            throw AIServiceError.contextFull
        case .condense(let keep):
            let folded = turns.dropLast(keep)
            var source = summary.map { "Summary so far:\n\($0)\n\n" } ?? ""
            source += folded.map { "Person: \($0.prompt)\nAssistant: \($0.response)" }.joined(separator: "\n\n")
            let focus = "Keep names, decisions, facts and open questions from this conversation."
            let newSummary: String
            // One summary request must fit the window with its instructions; a longer history is
            // summarized in bounded parts first.
            if await counter.tokenCount(source) + 64 > budget.available {
                let reduced = try await AttachmentCondenser(counter: counter, summarizer: summarizer)
                    .fit(source, within: budget.summaryReserve, chunkBudget: budget.chunkBudget, focus: focus)
                newSummary = reduced.text
            } else {
                newSummary = try await summarizer.summarize(source, focus: focus)
            }
            let rebuilt = AIConversationContext(profile: profile, summary: newSummary, turns: Array(turns.suffix(keep)))
            return Outcome(summary: newSummary, foldedTurns: folded.count, rebuilt: rebuilt)
        }
    }
}
