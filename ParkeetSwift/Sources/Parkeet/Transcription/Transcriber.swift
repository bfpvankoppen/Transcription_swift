import Foundation
import os

/// Wraps the sherpa-onnx offline recognizer for Parakeet TDT 0.6B v3 (INT8).
///
/// Model files: encoder.int8.onnx, decoder.int8.onnx, joiner.int8.onnx, tokens.txt
/// Must use model_type = "nemo_transducer" (not default "transducer").
final class Transcriber: @unchecked Sendable {

    private var recognizer: SherpaOnnxOfflineRecognizer?
    private let log = Logger(subsystem: "com.parkeet.app", category: "Transcriber")

    private static let modelDirName = "sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8"

    var isLoaded: Bool { recognizer != nil }

    // MARK: - Model Loading

    /// Load the Parakeet model. Call once at startup.
    func loadModel(onStatus: @escaping @Sendable (String) -> Void) async throws {
        let modelDir = try Self.findModelDirectory()

        let encoder = modelDir.appendingPathComponent("encoder.int8.onnx").path
        let decoder = modelDir.appendingPathComponent("decoder.int8.onnx").path
        let joiner = modelDir.appendingPathComponent("joiner.int8.onnx").path
        let tokens = modelDir.appendingPathComponent("tokens.txt").path

        onStatus("Loading Parakeet model…")
        log.info("Loading model from \(modelDir.path)")

        let transducer = sherpaOnnxOfflineTransducerModelConfig(
            encoder: encoder,
            decoder: decoder,
            joiner: joiner
        )

        let modelConfig = sherpaOnnxOfflineModelConfig(
            tokens: tokens,
            transducer: transducer,
            numThreads: 4,
            debug: 0,
            provider: "cpu",
            modelType: "nemo_transducer"  // Critical: not "transducer"
        )

        var config = sherpaOnnxOfflineRecognizerConfig(
            modelConfig: modelConfig,
            decodingMethod: "greedy_search"
        )

        guard let rec = SherpaOnnxOfflineRecognizer(config: &config) else {
            throw TranscriberError.modelLoadFailed
        }

        recognizer = rec
        onStatus("Model loaded")
        log.info("Parakeet model loaded successfully")
    }

    // MARK: - Transcription

    /// Transcribe audio samples (float32 at 16kHz). Runs synchronously (call from background).
    func transcribe(audio: [Float]) async -> String {
        guard let recognizer else {
            log.error("Cannot transcribe: model not loaded")
            return ""
        }

        let audioDuration = Double(audio.count) / 16000.0
        log.notice("Transcribing \(String(format: "%.1f", audioDuration))s audio (\(audio.count) samples)")

        let startTime = CFAbsoluteTimeGetCurrent()
        let result = recognizer.decode(samples: audio, sampleRate: 16000)
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime

        let rtf = elapsed / max(audioDuration, 0.001)
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)

        log.notice("Result: \(text.isEmpty ? "(empty)" : "'\(text)'") in \(String(format: "%.1f", elapsed))s (RTF: \(String(format: "%.2f", rtf)))")

        return text
    }

    // MARK: - Model Path

    /// Find the model directory in the app bundle or project resources.
    private static func findModelDirectory() throws -> URL {
        // 1. Check app bundle Resources
        if let bundlePath = Bundle.main.resourceURL?.appendingPathComponent("models/\(modelDirName)"),
           FileManager.default.fileExists(atPath: bundlePath.path) {
            return bundlePath
        }

        // 2. Check project Resources directory (development)
        let devPath = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()  // Transcription/
            .deletingLastPathComponent()  // Parkeet/
            .deletingLastPathComponent()  // Sources/
            .deletingLastPathComponent()  // ParkeetSwift/
            .appendingPathComponent("Resources/models/\(modelDirName)")
        if FileManager.default.fileExists(atPath: devPath.path) {
            return devPath
        }

        // 3. Check ~/.config/parkeet/models/
        let configPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/parkeet/models/\(modelDirName)")
        if FileManager.default.fileExists(atPath: configPath.path) {
            return configPath
        }

        throw TranscriberError.modelNotFound
    }
}

enum TranscriberError: LocalizedError {
    case modelNotFound
    case modelLoadFailed

    var errorDescription: String? {
        switch self {
        case .modelNotFound:
            "Parakeet model not found. Run Scripts/download-model.sh to download it."
        case .modelLoadFailed:
            "Failed to initialize the speech recognition model."
        }
    }
}
