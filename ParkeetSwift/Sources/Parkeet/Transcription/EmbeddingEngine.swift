import Foundation
import NaturalLanguage
import os

/// Computes sentence embeddings for semantic search using Apple's NLEmbedding.
///
/// Falls back to keyword-only search if sentence embeddings are unavailable
/// for the detected language.
final class EmbeddingEngine {

    private let logger = Logger(subsystem: "com.praten.app", category: "EmbeddingEngine")
    private var cachedEmbeddings: [NLLanguage: NLEmbedding] = [:]

    var isAvailable: Bool {
        embedding(for: .english) != nil
    }

    init() {
        if embedding(for: .english) != nil {
            logger.info("EmbeddingEngine initialized (NLEmbedding, semantic mode)")
        } else {
            logger.warning("EmbeddingEngine: NLEmbedding unavailable, semantic search disabled")
        }
    }

    /// Compute a dense embedding vector for the given text.
    /// Returns nil if embeddings are unavailable for the detected language.
    func embed(_ text: String) -> [Double]? {
        let language = detectLanguage(text)
        guard let nlEmbedding = embedding(for: language) else {
            return nil
        }

        // NLEmbedding works best with sentence-level text
        let trimmed = String(text.prefix(512))
        return nlEmbedding.vector(for: trimmed)
    }

    /// Cosine similarity between two dense vectors.
    func cosineSimilarity(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }

        var dot: Double = 0
        var magA: Double = 0
        var magB: Double = 0

        for i in 0..<a.count {
            dot += a[i] * b[i]
            magA += a[i] * a[i]
            magB += b[i] * b[i]
        }

        let denom = sqrt(magA) * sqrt(magB)
        return denom > 0 ? dot / denom : 0
    }

    // MARK: - Private

    private func detectLanguage(_ text: String) -> NLLanguage {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.dominantLanguage ?? .english
    }

    private func embedding(for language: NLLanguage) -> NLEmbedding? {
        if let cached = cachedEmbeddings[language] {
            return cached
        }

        if let emb = NLEmbedding.sentenceEmbedding(for: language) {
            cachedEmbeddings[language] = emb
            logger.info("Loaded NLEmbedding for \(language.rawValue)")
            return emb
        }

        // Fall back to English if available
        if language != .english, let emb = cachedEmbeddings[.english] ?? NLEmbedding.sentenceEmbedding(for: .english) {
            cachedEmbeddings[.english] = emb
            return emb
        }

        return nil
    }
}
