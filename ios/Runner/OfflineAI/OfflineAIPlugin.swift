import Flutter
import Foundation

/// Flutter `com.translate_app/offline_ai` 的入口點。
///
/// 職責：
/// - 註冊 MethodChannel + EventChannel
/// - 把 `startListening` / `translate` / `ensureLlmDownloaded` 等呼叫路由到對應服務
/// - 把 Whisper partial/final、LLM 下載進度等事件透過單一 EventChannel 推回 Dart
final class OfflineAIPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {

    private let methodChannel: FlutterMethodChannel
    private let eventChannel: FlutterEventChannel

    /// 僅在主執行緒存取（FlutterEventChannel 的 onListen/onCancel 本就在主執行緒呼叫）。
    private var eventSink: FlutterEventSink?

    private let whisper: WhisperService
    private let llama: LlamaService
    private let downloader: ModelDownloader

    static func register(with registrar: FlutterPluginRegistrar) {
        let method = FlutterMethodChannel(
            name: "com.translate_app/offline_ai",
            binaryMessenger: registrar.messenger()
        )
        let events = FlutterEventChannel(
            name: "com.translate_app/offline_ai/events",
            binaryMessenger: registrar.messenger()
        )
        let plugin = OfflineAIPlugin(method: method, events: events)
        registrar.addMethodCallDelegate(plugin, channel: method)
        events.setStreamHandler(plugin)
    }

    init(method: FlutterMethodChannel, events: FlutterEventChannel) {
        self.methodChannel = method
        self.eventChannel = events
        self.downloader = ModelDownloader()
        self.whisper = WhisperService()
        self.llama = LlamaService()
        super.init()
    }

    // MARK: - FlutterPlugin

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "status":
            result(currentStatus())

        case "prewarm":
            Task {
                do {
                    try await whisper.prewarm()
                    try await llama.prewarmIfReady()
                    await MainActor.run { result(nil) }
                } catch {
                    await MainActor.run {
                        result(FlutterError(
                            code: "prewarm_failed",
                            message: "\(error)",
                            details: nil
                        ))
                    }
                }
            }

        case "ensureLlmDownloaded":
            Task { await handleEnsureLlmDownloaded(result: result) }

        case "startListening":
            guard let args = call.arguments as? [String: Any],
                  let lang = args["language"] as? String else {
                result(FlutterError(code: "bad_args", message: "language required", details: nil))
                return
            }
            Task { await handleStartListening(language: lang, result: result) }

        case "stopListening":
            Task {
                await whisper.stopListening()
                await MainActor.run { result(nil) }
            }

        case "translate":
            guard let args = call.arguments as? [String: Any],
                  let text = args["text"] as? String,
                  let source = args["source"] as? String,
                  let target = args["target"] as? String else {
                result(FlutterError(code: "bad_args", message: "text/source/target required", details: nil))
                return
            }
            let hint = args["locationHint"] as? String
            Task { await handleTranslate(text: text, source: source, target: target, hint: hint, result: result) }

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - FlutterStreamHandler

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        self.eventSink = events
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        self.eventSink = nil
        return nil
    }

    // MARK: - Handlers

    private func handleStartListening(language: String, result: @escaping FlutterResult) async {
        do {
            try await whisper.startListening(language: language) { [weak self] event in
                self?.emit(event)
            }
            await MainActor.run { result(nil) }
        } catch {
            await MainActor.run {
                result(FlutterError(code: "start_failed", message: "\(error)", details: nil))
            }
        }
    }

    private func handleTranslate(text: String, source: String, target: String, hint: String?, result: @escaping FlutterResult) async {
        do {
            if !llama.isReady {
                // 自動觸發下載，但不阻塞：若沒下載完就直接失敗，交給 Dart 決定要 fallback 或顯示提示。
                throw OfflineAIError.modelNotReady("Qwen 模型尚未下載完畢")
            }
            let translated = try await llama.translate(
                text: text,
                source: source,
                target: target,
                locationHint: hint
            )
            await MainActor.run { result(translated) }
        } catch {
            await MainActor.run {
                result(FlutterError(code: "translate_failed", message: "\(error)", details: nil))
            }
        }
    }

    private func handleEnsureLlmDownloaded(result: @escaping FlutterResult) async {
        if llama.isReady {
            emit(.llmReady)
            await MainActor.run { result(nil) }
            return
        }
        do {
            let localURL = try await downloader.ensureQwenModel { [weak self] downloaded, total in
                self?.emit(.llmProgress(downloaded: downloaded, total: total))
            }
            try await llama.load(modelURL: localURL)
            emit(.llmReady)
            await MainActor.run { result(nil) }
        } catch {
            emit(.llmError(message: "\(error)"))
            await MainActor.run {
                result(FlutterError(code: "download_failed", message: "\(error)", details: nil))
            }
        }
    }

    private func currentStatus() -> [String: Any] {
        var map: [String: Any] = [
            "whisperReady": whisper.isReady,
            "llmReady": llama.isReady,
            "llmDownloading": downloader.isDownloading,
        ]
        if let name = whisper.modelName { map["whisperModelName"] = name }
        if let name = llama.modelName { map["llmModelName"] = name }
        if let bytes = downloader.lastBytes { map["llmBytes"] = bytes }
        if let total = downloader.lastTotal { map["llmBytesTotal"] = total }
        return map
    }

    private func emit(_ event: OfflineAIEvent) {
        let payload = event.asMap
        DispatchQueue.main.async { [weak self] in
            self?.eventSink?(payload)
        }
    }
}

enum OfflineAIEvent {
    case sttPartial(text: String)
    case sttFinal(text: String)
    case sttStatus(status: String)
    case sttError(message: String)
    case llmProgress(downloaded: Int64, total: Int64)
    case llmReady
    case llmError(message: String)

    var asMap: [String: Any] {
        switch self {
        case .sttPartial(let text):
            return ["type": "stt.partial", "text": text]
        case .sttFinal(let text):
            return ["type": "stt.final", "text": text]
        case .sttStatus(let status):
            return ["type": "stt.status", "status": status]
        case .sttError(let message):
            return ["type": "stt.error", "message": message]
        case .llmProgress(let downloaded, let total):
            return ["type": "llm.progress", "downloaded": downloaded, "total": total]
        case .llmReady:
            return ["type": "llm.ready"]
        case .llmError(let message):
            return ["type": "llm.error", "message": message]
        }
    }
}
