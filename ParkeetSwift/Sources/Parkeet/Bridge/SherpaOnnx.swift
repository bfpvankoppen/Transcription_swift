import Foundation

// MARK: - Offline Transducer Model Config

func sherpaOnnxOfflineTransducerModelConfig(
    encoder: String = "",
    decoder: String = "",
    joiner: String = ""
) -> SherpaOnnxOfflineTransducerModelConfig {
    return SherpaOnnxOfflineTransducerModelConfig(
        encoder: toCPointer(encoder),
        decoder: toCPointer(decoder),
        joiner: toCPointer(joiner)
    )
}

// MARK: - Offline Model Config

func sherpaOnnxOfflineModelConfig(
    tokens: String,
    transducer: SherpaOnnxOfflineTransducerModelConfig = sherpaOnnxOfflineTransducerModelConfig(),
    numThreads: Int32 = 4,
    debug: Int32 = 0,
    provider: String = "cpu",
    modelType: String = ""
) -> SherpaOnnxOfflineModelConfig {
    // Zero-initialize, then set only the fields we need.
    // This avoids breaking when the C API adds new model types.
    var config = SherpaOnnxOfflineModelConfig()
    config.transducer = transducer
    config.tokens = toCPointer(tokens)
    config.num_threads = numThreads
    config.debug = debug
    config.provider = toCPointer(provider)
    config.model_type = toCPointer(modelType)
    return config
}

// MARK: - Offline Recognizer Config

func sherpaOnnxOfflineRecognizerConfig(
    modelConfig: SherpaOnnxOfflineModelConfig,
    decodingMethod: String = "greedy_search",
    maxActivePaths: Int32 = 4
) -> SherpaOnnxOfflineRecognizerConfig {
    return SherpaOnnxOfflineRecognizerConfig(
        feat_config: SherpaOnnxFeatureConfig(sample_rate: 16000, feature_dim: 80),
        model_config: modelConfig,
        lm_config: SherpaOnnxOfflineLMConfig(
            model: toCPointer(""),
            scale: 1.0
        ),
        decoding_method: toCPointer(decodingMethod),
        max_active_paths: maxActivePaths,
        hotwords_file: toCPointer(""),
        hotwords_score: 1.5,
        rule_fsts: toCPointer(""),
        rule_fars: toCPointer(""),
        blank_penalty: 0.0,
        hr: SherpaOnnxHomophoneReplacerConfig(
            dict_dir: toCPointer(""),
            lexicon: toCPointer(""),
            rule_fsts: toCPointer("")
        )
    )
}

// MARK: - Offline Recognizer Wrapper

class SherpaOnnxOfflineRecognizer {
    private let pointer: OpaquePointer

    init?(config: inout SherpaOnnxOfflineRecognizerConfig) {
        guard let p = SherpaOnnxCreateOfflineRecognizer(&config) else {
            return nil
        }
        self.pointer = p
    }

    deinit {
        SherpaOnnxDestroyOfflineRecognizer(pointer)
    }

    /// Decode audio samples (float32, normalized [-1, 1]) at the given sample rate.
    func decode(samples: [Float], sampleRate: Int32 = 16000) -> SherpaOnnxOfflineRecognitionResult {
        let stream = SherpaOnnxCreateOfflineStream(pointer)!
        defer { SherpaOnnxDestroyOfflineStream(stream) }

        samples.withUnsafeBufferPointer { bufferPointer in
            SherpaOnnxAcceptWaveformOffline(
                stream,
                sampleRate,
                bufferPointer.baseAddress,
                Int32(samples.count)
            )
        }

        SherpaOnnxDecodeOfflineStream(pointer, stream)

        let resultPtr = SherpaOnnxGetOfflineStreamResult(stream)!
        defer { SherpaOnnxDestroyOfflineRecognizerResult(resultPtr) }

        let text = String(cString: resultPtr.pointee.text)

        return SherpaOnnxOfflineRecognitionResult(text: text)
    }
}

// MARK: - Result

struct SherpaOnnxOfflineRecognitionResult {
    let text: String
}

// MARK: - Helpers

/// Convert a Swift String to a C string pointer that persists for the process lifetime.
/// Used for config structs that hold `const char*` pointers.
private func toCPointer(_ s: String) -> UnsafePointer<CChar> {
    let cs = (s as NSString).utf8String!
    let mutable = UnsafeMutablePointer<CChar>(mutating: cs)
    // Copy to heap so it outlives the NSString temporary
    let len = strlen(cs) + 1
    let copy = UnsafeMutablePointer<CChar>.allocate(capacity: len)
    copy.initialize(from: mutable, count: len)
    return UnsafePointer(copy)
}
