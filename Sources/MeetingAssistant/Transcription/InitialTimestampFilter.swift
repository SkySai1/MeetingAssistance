import CoreML
import WhisperKit

// In e687e26 TimestampRulesFilter accepts maxInitialTimestampIndex but the code
// applying it is commented out. TextDecoder can replace the prefilled 0.00 token
// with an arbitrary predicted timestamp, skipping the beginning of a live window.
// Compose the public filter API to constrain the initial timestamp to one second.
final class InitialTimestampFilter: LogitsFiltering {
    private let filter: SuppressTokensFilter

    init(timeTokenBegin: Int, vocabularySize: Int) {
        let firstForbidden = timeTokenBegin + Int(1 / WhisperKit.secondsPerTimeToken) + 1
        filter = SuppressTokensFilter(suppressTokens: Array(firstForbidden..<vocabularySize))
    }

    func filterLogits(_ logits: MLMultiArray, withTokens tokens: [Int]) -> MLMultiArray {
        // Our fixed Russian transcription prompt is SOT, ru, transcribe, timestamp.
        // No previous-text prompt is inserted. Only the first prediction is limited.
        tokens.count <= 4 ? filter.filterLogits(logits, withTokens: tokens) : logits
    }
}
