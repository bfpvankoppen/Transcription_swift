import Foundation
import os

/// Computes text embeddings for semantic search.
///
/// Uses TF-IDF vectorization with cosine similarity for lightweight
/// semantic search. No external model required.
final class EmbeddingEngine {

    private var idfScores: [String: Float] = [:]
    private var documentCount: Int = 0
    private let logger = Logger(subsystem: "com.praten.app", category: "EmbeddingEngine")

    init() {
        logger.info("EmbeddingEngine initialized (TF-IDF mode)")
    }

    /// Compute a sparse TF-IDF vector for the given text.
    func embed(_ text: String) -> [String: Float] {
        let tokens = tokenize(text)
        guard !tokens.isEmpty else { return [:] }

        // Term frequency
        var tf: [String: Float] = [:]
        for token in tokens {
            tf[token, default: 0] += 1
        }
        let count = Float(tokens.count)
        for key in tf.keys {
            tf[key]! /= count
        }

        // TF-IDF
        var tfidf: [String: Float] = [:]
        for (term, freq) in tf {
            let idf = idfScores[term] ?? Darwin.log2(Float(max(documentCount, 1)) + 1)
            tfidf[term] = freq * idf
        }

        return normalize(tfidf)
    }

    /// Update IDF scores with a new document corpus.
    func updateIDF(documents: [String]) {
        documentCount = documents.count
        var docFreq: [String: Int] = [:]

        for doc in documents {
            let uniqueTokens = Set(tokenize(doc))
            for token in uniqueTokens {
                docFreq[token, default: 0] += 1
            }
        }

        idfScores = [:]
        let n = Float(documentCount)
        for (term, df) in docFreq {
            idfScores[term] = Darwin.log2((n + 1) / (Float(df) + 1)) + 1
        }

        logger.info("IDF updated: \(docFreq.count) terms from \(self.documentCount) documents")
    }

    /// Cosine similarity between two sparse vectors.
    func cosineSimilarity(_ a: [String: Float], _ b: [String: Float]) -> Float {
        var dot: Float = 0
        for (key, val) in a {
            if let bVal = b[key] {
                dot += val * bVal
            }
        }
        return dot  // vectors are pre-normalized
    }

    // MARK: - Private

    private func tokenize(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 1 }  // skip single chars
    }

    private func normalize(_ vector: [String: Float]) -> [String: Float] {
        let magnitude = sqrt(vector.values.reduce(0) { $0 + $1 * $1 })
        guard magnitude > 0 else { return vector }
        return vector.mapValues { $0 / magnitude }
    }
}
