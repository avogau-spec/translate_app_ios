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

    /// 歷史上這個方法會觸發下載；目前 Qwen 直接打包在 app bundle 內，
    /// 此方法改為「嘗試從 bundle 載入」並保留原介面給 Dart 端相容使用。
    private func handleEnsureLlmDownloaded(result: @escaping FlutterResult) async {
        if llama.isReady {
            emit(.llmReady)
            await MainActor.run { result(nil) }
            return
        }
        do {
            try await llama.prewarmIfReady()
            if llama.isReady {
                emit(.llmReady)
                await MainActor.run { result(nil) }
                return
            }
            let msg = "Qwen GGUF 未打包於 app bundle。請將 Qwen2.5-1.5B-Instruct-Q4_K_M.gguf 加入 Runner target（詳見 ios/Runner/OfflineAI/README.md）。"
            emit(.llmError(message: msg))
            await MainActor.run {
                result(FlutterError(code: "model_missing", message: msg, details: nil))
            }
        } catch {
            emit(.llmError(message: "\(error)"))
            await MainActor.run {
                result(FlutterError(code: "load_failed", message: "\(error)", details: nil))
            }
        }
    }

    private func currentStatus() -> [String: Any] {
        var map: [String: Any] = [
            "whisperReady": whisper.isReady,
            "llmReady": llama.isReady,
            "llmDownloading": false,
            "llmBundled": LlamaService.bundledModelURL() != nil,
        ]
        if let name = whisper.modelName { map["whisperModelName"] = name }
        if let name = llama.modelName { map["llmModelName"] = name }
        if let bundled = LlamaService.bundledModelURL() {
            let attr = try? FileManager.default.attributesOfItem(atPath: bundled.path)
            if let size = (attr?[.size] as? NSNumber)?.int64Value {
                map["llmBytes"] = size
                map["llmBytesTotal"] = size
            }
        }
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
