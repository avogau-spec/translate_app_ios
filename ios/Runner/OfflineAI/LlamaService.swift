import Foundation
import LLM

/// Qwen-2.5-1.5B-Instruct（INT4，GGUF）包裝。
///
/// 依賴 SPM：[`LLM.swift`](https://github.com/eastriverlee/LLM.swift)（內含 llama.cpp XCFramework）。
///
/// 我們只做「翻譯」單輪任務，因此用 zero-temperature、short-output、stop-on-EOS 的設定，
/// 並固定 system prompt 讓模型只輸出譯文（避免解釋、避免加引號）。
final class LlamaService {

    /// Qwen GGUF 下載後存放位置（Documents/qwen2.5-1.5b-instruct-q4_k_m.gguf）。
    static let expectedFilename = "qwen2.5-1.5b-instruct-q4_k_m.gguf"

    private(set) var isReady: Bool = false
    var modelName: String? { Self.expectedFilename }

    private var llm: LLM?

    // MARK: - Lifecycle

    /// 若檔案已存在就自動載入。供 App 啟動時呼叫。
    func prewarmIfReady() async throws {
        if isReady { return }
        let url = Self.defaultModelURL()
        if FileManager.default.fileExists(atPath: url.path) {
            try await load(modelURL: url)
        }
    }

    func load(modelURL: URL) async throws {
        // Qwen2.5 的 chat template 與 Qwen1.5 基本一致（ChatML），template: .chatML(system) 即可。
        let system = Self.systemPrompt
        guard let bot = LLM(
            from: modelURL,
            template: .chatML(system),
            history: [],
            seed: 0,
            topK: 40,
            topP: 0.9,
            temp: 0.0,
            historyLimit: 0,         // 單輪
            maxTokenCount: 256       // 翻譯輸出上限
        ) else {
            throw OfflineAIError.modelNotReady("LLM.swift 無法以給定 GGUF 建立實例：\(modelURL.lastPathComponent)")
        }
        self.llm = bot
        self.isReady = true
    }

    // MARK: - Translate

    func translate(text: String, source: String, target: String, locationHint: String?) async throws -> String {
        guard let bot = llm else {
            throw OfflineAIError.modelNotReady("Qwen 尚未載入")
        }
        // 單輪重置歷史，避免跨句 leak（history 是 @Published，於 MainActor 設定較安全）。
        await MainActor.run { bot.history = [] }

        let prompt = Self.buildUserPrompt(
            text: text,
            source: source,
            target: target,
            locationHint: locationHint
        )

        await bot.respond(to: prompt)
        let raw = bot.output
        if raw.isEmpty {
            throw OfflineAIError.inferenceFailed("Qwen 無輸出")
        }
        return Self.sanitize(raw)
    }

    // MARK: - Prompt

    private static let systemPrompt: String = """
    You are a professional interpreter for tourists in Japan. Translate the user's text into the target language faithfully and naturally. \
    Rules:
    1. Output ONLY the translation text. No quotes, no explanation, no language labels.
    2. Preserve proper nouns (place names, station names, shop names) in their most recognizable form for tourists reading Traditional Chinese / Japanese / English.
    3. If the source text is already in the target language or is meaningless, return it unchanged.
    4. Keep the register casual-polite, suitable for signage and live narration.
    """

    private static func buildUserPrompt(text: String, source: String, target: String, locationHint: String?) -> String {
        let srcLabel = readableLanguageName(tag: source)
        let tgtLabel = readableLanguageName(tag: target)
        var body = "Translate from \(srcLabel) to \(tgtLabel).\n"
        if let h = locationHint, !h.isEmpty {
            body += "Context (user's approximate location): \(h)\n"
        }
        body += "Text:\n\(text)\n\nTranslation:"
        return body
    }

    private static func readableLanguageName(tag: String) -> String {
        let lower = tag.lowercased()
        if lower.hasPrefix("zh") { return "Traditional Chinese (zh-TW)" }
        if lower.hasPrefix("ja") { return "Japanese" }
        if lower.hasPrefix("en") { return "English" }
        if lower.hasPrefix("ko") { return "Korean" }
        if lower.hasPrefix("es") { return "Spanish" }
        if lower.hasPrefix("fr") { return "French" }
        return tag
    }

    private static func sanitize(_ raw: String) -> String {
        var out = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // Qwen 有時會加引號或標籤前綴，統一清掉。
        let prefixesToStrip: [String] = [
            "Translation:", "译文：", "譯文：", "翻譯：", "翻译：", "Translated:",
        ]
        for p in prefixesToStrip {
            if out.hasPrefix(p) {
                out = String(out.dropFirst(p.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        // 去掉最外層單/雙引號。
        if out.count >= 2 {
            let first = out.first!
            let last = out.last!
            let pairs: [(Character, Character)] = [("\"", "\""), ("'", "'"), ("「", "」"), ("『", "』")]
            for (a, b) in pairs where first == a && last == b {
                out = String(out.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }
        return out
    }

    // MARK: - Paths

    static func defaultModelURL() -> URL {
        let dir = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let base = dir ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let folder = base.appendingPathComponent("OfflineAI", isDirectory: true)
        if !FileManager.default.fileExists(atPath: folder.path) {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        return folder.appendingPathComponent(Self.expectedFilename)
    }
}
