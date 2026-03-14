import Foundation
import os

/// WordPiece tokenizer for MiniLM embedding model.
///
/// Tokenizes text into subword token IDs using a vocab.txt file.
/// Follows the BERT tokenization pipeline: lowercase → split on whitespace/punctuation → subword tokenize.
final class WordPieceTokenizer {

    private let vocab: [String: Int32]
    private let unkTokenID: Int32
    private let clsTokenID: Int32
    private let sepTokenID: Int32
    private let padTokenID: Int32
    private let maxLength: Int
    private let log = Logger(subsystem: "com.parkeet.app", category: "WordPieceTokenizer")

    init(vocabURL: URL, maxLength: Int = 128) throws {
        let content = try String(contentsOf: vocabURL, encoding: .utf8)
        let lines = content.components(separatedBy: .newlines).filter { !$0.isEmpty }

        var vocab: [String: Int32] = [:]
        for (i, line) in lines.enumerated() {
            vocab[line] = Int32(i)
        }
        self.vocab = vocab

        guard let unk = vocab["[UNK]"],
              let cls = vocab["[CLS]"],
              let sep = vocab["[SEP]"],
              let pad = vocab["[PAD]"] else {
            throw TokenizerError.missingSpecialTokens
        }
        self.unkTokenID = unk
        self.clsTokenID = cls
        self.sepTokenID = sep
        self.padTokenID = pad
        self.maxLength = maxLength

        log.info("WordPiece tokenizer loaded: \(vocab.count) tokens, maxLength=\(maxLength)")
    }

    /// Tokenize text into token IDs and attention mask.
    ///
    /// Returns (tokenIDs, attentionMask) both of length `maxLength`.
    func tokenize(_ text: String) -> (tokenIDs: [Int32], attentionMask: [Int32]) {
        let lowered = text.lowercased()
        let words = splitOnPunctuation(lowered)

        var tokens: [Int32] = [clsTokenID]

        for word in words {
            let subTokens = wordPieceTokenize(word)
            tokens.append(contentsOf: subTokens)
            if tokens.count >= maxLength - 1 { break }
        }

        // Truncate to maxLength - 1 (leave room for [SEP])
        if tokens.count > maxLength - 1 {
            tokens = Array(tokens.prefix(maxLength - 1))
        }
        tokens.append(sepTokenID)

        // Attention mask: 1 for real tokens, 0 for padding
        let realCount = tokens.count
        let attentionMask = Array(repeating: Int32(1), count: realCount)
            + Array(repeating: Int32(0), count: maxLength - realCount)

        // Pad token IDs
        tokens += Array(repeating: padTokenID, count: maxLength - realCount)

        return (tokens, attentionMask)
    }

    // MARK: - Private

    private func wordPieceTokenize(_ word: String) -> [Int32] {
        if word.isEmpty { return [] }

        var tokens: [Int32] = []
        var start = word.startIndex

        while start < word.endIndex {
            var end = word.endIndex
            var found = false

            while start < end {
                let substr = (start == word.startIndex)
                    ? String(word[start..<end])
                    : "##" + String(word[start..<end])

                if let id = vocab[substr] {
                    tokens.append(id)
                    start = end
                    found = true
                    break
                }
                end = word.index(before: end)
            }

            if !found {
                tokens.append(unkTokenID)
                start = word.index(after: start)
            }
        }

        return tokens
    }

    /// Split text on whitespace and punctuation, keeping punctuation as separate tokens.
    private func splitOnPunctuation(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""

        for char in text {
            if char.isWhitespace {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            } else if char.isPunctuation || char.isSymbol {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                tokens.append(String(char))
            } else {
                current.append(char)
            }
        }
        if !current.isEmpty {
            tokens.append(current)
        }

        return tokens
    }

    enum TokenizerError: Error, LocalizedError {
        case missingSpecialTokens

        var errorDescription: String? {
            switch self {
            case .missingSpecialTokens:
                return "vocab.txt missing required special tokens ([UNK], [CLS], [SEP], [PAD])"
            }
        }
    }
}
