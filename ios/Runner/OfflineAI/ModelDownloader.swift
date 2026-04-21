import CryptoKit
import Foundation

/// 負責把 Qwen GGUF 從 CDN 下載到 Application Support/OfflineAI/。
///
/// - 支援 HTTP Range 續傳
/// - 下載完成後以 SHA256 驗證
/// - 進度以 `onProgress(downloaded, total)` 回呼（主執行緒）
///
/// 下載 URL / SHA256 在 `Config.swift` 調整；第一次設置請至少填 `downloadURL`。
final class ModelDownloader: NSObject {

    struct Config {
        /// Qwen-2.5-1.5B-Instruct Q4_K_M GGUF 的下載位址（請用你能穩定存取的 CDN / 自家 S3）。
        /// 例：`https://huggingface.co/unsloth/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/Qwen2.5-1.5B-Instruct-Q4_K_M.gguf`
        static let downloadURL: String = ""

        /// 可選：若填了 64 hex SHA256，會在下載完成後驗證，mismatch 直接刪除檔案並報錯。
        /// 留空則不驗證（build 初期開發方便，正式版強烈建議填）。
        static let sha256Hex: String = ""

        /// 預期大小（byte），用來在 Content-Length 還沒回來前估進度；可留 0。
        static let expectedBytes: Int64 = 0
    }

    private(set) var isDownloading: Bool = false
    private(set) var lastBytes: Int64?
    private(set) var lastTotal: Int64?

    private var session: URLSession!
    private var currentTask: URLSessionDataTask?
    private var progressHandler: ((Int64, Int64) -> Void)?
    private var continuation: CheckedContinuation<URL, Error>?

    private var outputHandle: FileHandle?
    private var outputURL: URL!
    private var partialURL: URL!
    private var totalBytesExpected: Int64 = 0
    private var bytesWritten: Int64 = 0

    override init() {
        super.init()
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 60 * 60
        cfg.waitsForConnectivity = true
        cfg.allowsCellularAccess = true
        self.session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }

    // MARK: - Public

    func ensureQwenModel(onProgress: @escaping (Int64, Int64) -> Void) async throws -> URL {
        let finalURL = LlamaService.defaultModelURL()
        if FileManager.default.fileExists(atPath: finalURL.path) {
            if Config.sha256Hex.isEmpty {
                onProgress(fileSize(at: finalURL), fileSize(at: finalURL))
                return finalURL
            }
            let ok = try verifyHash(at: finalURL, expected: Config.sha256Hex)
            if ok {
                onProgress(fileSize(at: finalURL), fileSize(at: finalURL))
                return finalURL
            } else {
                try? FileManager.default.removeItem(at: finalURL)
            }
        }

        guard let urlString = URL(string: Config.downloadURL), !Config.downloadURL.isEmpty else {
            throw OfflineAIError.downloadFailed("未設定 ModelDownloader.Config.downloadURL。請至 ios/Runner/OfflineAI/ModelDownloader.swift 填入 Qwen GGUF URL。")
        }

        return try await withCheckedThrowingContinuation { cont in
            self.continuation = cont
            self.progressHandler = onProgress
            self.outputURL = finalURL
            self.partialURL = finalURL.appendingPathExtension("part")
            self.isDownloading = true

            var req = URLRequest(url: urlString)
            req.httpMethod = "GET"

            // 若有部分檔，嘗試 Range 續傳。
            if FileManager.default.fileExists(atPath: self.partialURL.path) {
                let resumeFrom = fileSize(at: self.partialURL)
                if resumeFrom > 0 {
                    req.setValue("bytes=\(resumeFrom)-", forHTTPHeaderField: "Range")
                    self.bytesWritten = resumeFrom
                }
            } else {
                FileManager.default.createFile(atPath: self.partialURL.path, contents: nil)
                self.bytesWritten = 0
            }

            self.currentTask = self.session.dataTask(with: req)
            self.currentTask?.resume()
        }
    }

    // MARK: - Helpers

    private func fileSize(at url: URL) -> Int64 {
        let attr = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attr?[.size] as? NSNumber)?.int64Value ?? 0
    }

    private func finishSuccess() {
        isDownloading = false
        do {
            try? FileManager.default.removeItem(at: outputURL)
            try FileManager.default.moveItem(at: partialURL, to: outputURL)

            if !Config.sha256Hex.isEmpty {
                let ok = try verifyHash(at: outputURL, expected: Config.sha256Hex)
                if !ok {
                    let actual = try computeHash(at: outputURL)
                    try? FileManager.default.removeItem(at: outputURL)
                    throw OfflineAIError.hashMismatch(expected: Config.sha256Hex, actual: actual)
                }
            }
            continuation?.resume(returning: outputURL)
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
        progressHandler = nil
        currentTask = nil
        outputHandle = nil
    }

    private func finishFailure(_ error: Error) {
        isDownloading = false
        continuation?.resume(throwing: OfflineAIError.downloadFailed("\(error.localizedDescription)"))
        continuation = nil
        progressHandler = nil
        currentTask = nil
        outputHandle = nil
    }

    private func computeHash(at url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let chunk = handle.readData(ofLength: 1024 * 1024)
            if chunk.isEmpty { return false }
            hasher.update(data: chunk)
            return true
        }) {}
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func verifyHash(at url: URL, expected: String) throws -> Bool {
        let actual = try computeHash(at: url)
        return actual.lowercased() == expected.lowercased()
    }
}

extension ModelDownloader: URLSessionDataDelegate {

    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 200 {
                // 全新下載：partial 檔先截斷。
                try? FileManager.default.removeItem(at: partialURL)
                FileManager.default.createFile(atPath: partialURL.path, contents: nil)
                bytesWritten = 0
                totalBytesExpected = http.expectedContentLength > 0 ? http.expectedContentLength : Config.expectedBytes
            } else if http.statusCode == 206 {
                // 續傳：Content-Range: bytes start-end/total
                if let cr = http.value(forHTTPHeaderField: "Content-Range"),
                   let total = cr.components(separatedBy: "/").last,
                   let t = Int64(total) {
                    totalBytesExpected = t
                } else {
                    totalBytesExpected = http.expectedContentLength + bytesWritten
                }
            } else {
                completionHandler(.cancel)
                finishFailure(OfflineAIError.downloadFailed("HTTP \(http.statusCode)"))
                return
            }
        }
        do {
            outputHandle = try FileHandle(forWritingTo: partialURL)
            try outputHandle?.seekToEnd()
        } catch {
            completionHandler(.cancel)
            finishFailure(error)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            try outputHandle?.write(contentsOf: data)
            bytesWritten += Int64(data.count)
            lastBytes = bytesWritten
            lastTotal = totalBytesExpected
            let handler = progressHandler
            let bw = bytesWritten
            let tot = totalBytesExpected
            DispatchQueue.main.async { handler?(bw, tot) }
        } catch {
            dataTask.cancel()
            finishFailure(error)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? outputHandle?.close()
        outputHandle = nil
        if let error = error {
            finishFailure(error)
            return
        }
        finishSuccess()
    }
}
