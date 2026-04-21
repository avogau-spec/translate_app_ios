import Foundation

enum OfflineAIError: LocalizedError {
    case modelNotBundled(String)
    case modelNotReady(String)
    case downloadFailed(String)
    case hashMismatch(expected: String, actual: String)
    case inferenceFailed(String)
    case audioSessionFailed(String)
    case unsupportedLanguage(String)

    var errorDescription: String? {
        switch self {
        case .modelNotBundled(let msg):    return "模型未打包：\(msg)"
        case .modelNotReady(let msg):      return "模型尚未就緒：\(msg)"
        case .downloadFailed(let msg):     return "下載失敗：\(msg)"
        case .hashMismatch(let e, let a):  return "模型 SHA256 不一致（期望 \(e)，實際 \(a)）"
        case .inferenceFailed(let msg):    return "推理失敗：\(msg)"
        case .audioSessionFailed(let msg): return "音訊工作階段失敗：\(msg)"
        case .unsupportedLanguage(let l):  return "不支援的語言：\(l)"
        }
    }
}
