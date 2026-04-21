import AVFoundation
import CoreML
import Foundation
import WhisperKit

/// Whisper-small（Core ML）包裝：mic → VAD → streaming transcription → partial/final 回呼。
///
/// 依賴 SPM：`WhisperKit`（https://github.com/argmaxinc/WhisperKit）。
///
/// 模型檔：打包於 App Bundle `Models/openai_whisper-small/`，目錄結構遵循 WhisperKit 的
/// Core ML 佈局（含 `AudioEncoder.mlmodelc`、`TextDecoder.mlmodelc`、`MelSpectrogram.mlmodelc`、
/// `tokenizer/` 等；可從 HuggingFace `argmaxinc/whisperkit-coreml` 取得 openai_whisper-small）。
///
/// 需要 iOS 16+（由 Runner 的 deployment target 保證；WhisperKit 本身要求 iOS 16）。
final class WhisperService {

    /// 目前 bundle 內預期的模型資料夾名稱。
    static let bundledModelFolderName = "openai_whisper-small"

    private(set) var isReady: Bool = false
    var modelName: String? { bundledModelURL?.lastPathComponent }

    private var pipeline: WhisperKit?
    private var streamTranscriber: AudioStreamTranscriber?

    private var eventSink: ((OfflineAIEvent) -> Void)?

    private var lastCommittedText: String = ""

    // MARK: - Bundled model discovery

    private var bundledModelURL: URL? {
        if let url = Bundle.main.url(forResource: Self.bundledModelFolderName, withExtension: nil, subdirectory: "Models") {
            return url
        }
        // 若直接拖到 Runner 資源根目錄（以資料夾引用方式）也能找到。
        if let url = Bundle.main.url(forResource: Self.bundledModelFolderName, withExtension: nil) {
            return url
        }
        return nil
    }

    // MARK: - Lifecycle

    /// 預熱：載入 Core ML，往後首句就不需等編譯。
    func prewarm() async throws {
        if pipeline != nil { return }
        guard let url = bundledModelURL else {
            throw OfflineAIError.modelNotBundled("Bundle 找不到 Models/\(Self.bundledModelFolderName)，請先依 README 放入 Core ML 模型。")
        }
        let config = WhisperKitConfig(
            modelFolder: url.path,
            computeOptions: ModelComputeOptions(
                audioEncoderCompute: .cpuAndNeuralEngine,
                textDecoderCompute: .cpuAndNeuralEngine
            ),
            verbose: false,
            logLevel: .error,
            prewarm: true,
            load: true
        )
        let whisper = try await WhisperKit(config)
        self.pipeline = whisper
        self.isReady = true
    }

    // MARK: - Streaming STT

    func startListening(language: String, onEvent: @escaping (OfflineAIEvent) -> Void) async throws {
        self.eventSink = onEvent
        if pipeline == nil {
            try await prewarm()
        }
        guard let whisper = pipeline else {
            throw OfflineAIError.modelNotReady("Whisper pipeline 尚未載入")
        }

        try configureAudioSession()
        lastCommittedText = ""

        let decodingOptions = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: normalizeLanguage(language),
            temperature: 0.0,
            temperatureIncrementOnFallback: 0.2,
            temperatureFallbackCount: 3,
            sampleLength: 224,
            usePrefillPrompt: true,
            skipSpecialTokens: true,
            withoutTimestamps: true
        )

        guard let tokenizer = whisper.tokenizer else {
            throw OfflineAIError.modelNotReady("WhisperKit tokenizer 未載入")
        }

        let transcriber = AudioStreamTranscriber(
            audioEncoder: whisper.audioEncoder,
            featureExtractor: whisper.featureExtractor,
            segmentSeeker: whisper.segmentSeeker,
            textDecoder: whisper.textDecoder,
            tokenizer: tokenizer,
            audioProcessor: whisper.audioProcessor,
            decodingOptions: decodingOptions,
            requiredSegmentsForConfirmation: 2,
            silenceThreshold: 0.3,
            compressionCheckWindow: 60,
            useVAD: true,
            stateChangeCallback: { [weak self] oldState, newState in
                self?.handleStateChange(old: oldState, new: newState)
            }
        )

        self.streamTranscriber = transcriber
        try await transcriber.startStreamTranscription()
        onEvent(.sttStatus(status: "listening"))
    }

    func stopListening() async {
        if let transcriber = streamTranscriber {
            await transcriber.stopStreamTranscription()
        }
        streamTranscriber = nil
        try? deactivateAudioSession()

        let finalText = lastCommittedText
        lastCommittedText = ""
        if !finalText.isEmpty {
            eventSink?(.sttFinal(text: finalText))
        }
        eventSink?(.sttStatus(status: "stopped"))
        eventSink = nil
    }

    // MARK: - Internal

    private func handleStateChange(old: AudioStreamTranscriber.State, new: AudioStreamTranscriber.State) {
        // WhisperKit 會把「已確認」片段合成一段，其餘為暫定；`currentText` 已組好「已確認 + 暫定」。
        // 我們一律當 partial 推回 Dart；使用者停止收音時才推 final。
        let confirmedJoined = new.confirmedSegments.map { $0.text }.joined(separator: " ")
        let merged = [confirmedJoined, new.currentText]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if merged.isEmpty { return }
        if merged != lastCommittedText {
            lastCommittedText = merged
            eventSink?(.sttPartial(text: merged))
        }
    }

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            throw OfflineAIError.audioSessionFailed("\(error.localizedDescription)")
        }
    }

    private func deactivateAudioSession() throws {
        try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// 把 Flutter 傳來的 `ja-JP` / `en-US` / `zh-TW` 正規化成 Whisper 的語言代碼。
    private func normalizeLanguage(_ tag: String) -> String {
        let lower = tag.lowercased()
        if lower.hasPrefix("ja") { return "ja" }
        if lower.hasPrefix("zh") { return "zh" }
        if lower.hasPrefix("en") { return "en" }
        if lower.hasPrefix("ko") { return "ko" }
        if lower.hasPrefix("es") { return "es" }
        if lower.hasPrefix("fr") { return "fr" }
        return String(lower.prefix(2))
    }
}
