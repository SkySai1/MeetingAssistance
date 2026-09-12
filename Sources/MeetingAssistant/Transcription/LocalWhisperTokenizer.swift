import ArgmaxCore
import Foundation
import WhisperKit

// Compatibility with argmax-oss-swift e687e26: WhisperTokenizerWrapper's initializer
// is internal, and ModelUtilities.loadTokenizer can download after a local failure.
// Adapt the PUBLIC local tokenizer factory to the PUBLIC WhisperTokenizer protocol
// so a missing/corrupt tokenizer can only throw, never initiate a Hub fallback.
// Word grouping is deliberately scoped to Russian and embedded English terms.
struct LocalWhisperTokenizer: WhisperTokenizer, Sendable {
    private let base: TokenizerWrapper
    let specialTokens: SpecialTokens
    let allLanguageTokens: Set<Int>

    init(folder: URL) async throws {
        let tokenizer = try await AutoTokenizerWrapper.from(modelFolder: folder)
        func token(_ spelling: String) throws -> Int {
            guard let id = tokenizer.convertTokenToId(spelling) else { throw MeetingError("Local Whisper tokenizer is missing \(spelling)") }
            return id
        }
        let whitespace = tokenizer.encode(text: " ", addSpecialTokens: false)
        guard whitespace.count == 1, let whitespaceID = whitespace.first else { throw MeetingError("Invalid Whisper whitespace token") }
        specialTokens = try SpecialTokens(endToken: token("<|endoftext|>"), englishToken: token("<|en|>"),
            noSpeechToken: token("<|nospeech|>"), noTimestampsToken: token("<|notimestamps|>"),
            specialTokenBegin: token("<|endoftext|>"), startOfPreviousToken: token("<|startofprev|>"),
            startOfTranscriptToken: token("<|startoftranscript|>"), timeTokenBegin: token("<|0.00|>"),
            transcribeToken: token("<|transcribe|>"), translateToken: token("<|translate|>"), whitespaceToken: whitespaceID)
        _ = try token("<|ru|>")
        allLanguageTokens = Set(Constants.languages.values.compactMap { tokenizer.convertTokenToId("<|\($0)|>") })
        base = tokenizer
    }

    func encode(text: String) -> [Int] { base.encode(text: text) }
    func decode(tokens: [Int]) -> String { base.decode(tokens: tokens) }
    func convertTokenToId(_ token: String) -> Int? { base.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { base.convertIdToToken(id) }

    func splitToWordTokens(tokenIds: [Int]) -> (words: [String], wordTokens: [[Int]]) {
        var groups: [[Int]] = []
        var fragments: [Int] = []
        var current: [Int] = []
        for id in tokenIds {
            if id >= specialTokens.specialTokenBegin {
                current += fragments; fragments.removeAll(keepingCapacity: true)
                if !current.isEmpty { groups.append(current); current.removeAll(keepingCapacity: true) }
                groups.append([id])
                continue
            }
            fragments.append(id)
            let text = base.decode(tokens: fragments)
            // Byte-pair tokens may end inside a Cyrillic Unicode scalar.
            if text.contains("\u{fffd}") { continue }
            let startsWord = text.first?.isWhitespace == true
            let punctuation = !text.isEmpty && text.unicodeScalars.allSatisfy { CharacterSet.punctuationCharacters.contains($0) }
            if (startsWord || punctuation) && !current.isEmpty {
                groups.append(current); current.removeAll(keepingCapacity: true)
            }
            current += fragments
            fragments.removeAll(keepingCapacity: true)
        }
        current += fragments
        if !current.isEmpty { groups.append(current) }
        return (groups.map { base.decode(tokens: $0) }, groups)
    }
}
