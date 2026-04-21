# iOS Offline AI 模組設置步驟

這個資料夾內的 Swift 檔案提供 iOS 上的離線語音辨識（Whisper-small）與離線翻譯（Qwen-2.5-1.5B-Instruct Q4_K_M）。
以下步驟必須在 **Mac + Xcode** 上做，Windows 的 Flutter 端不會自動幫你加。

> 前提：已在 Mac clone 專案並執行過 `flutter pub get`，確認 `ios/Runner.xcworkspace` 可以正常開啟。

---

## 1) 加入 Swift Package 依賴（到 Runner target）

在 Xcode 打開 `ios/Runner.xcworkspace`（**不是** `.xcodeproj`），選 `Runner` project → `Runner` target → `Package Dependencies` → 點 `+`：

| Package                                                   | URL                                                        | Product       | 加到 target |
| --------------------------------------------------------- | ---------------------------------------------------------- | ------------- | ----------- |
| WhisperKit                                                | `https://github.com/argmaxinc/WhisperKit.git`              | `WhisperKit`  | Runner      |
| LLM.swift                                                 | `https://github.com/eastriverlee/LLM.swift.git`            | `LLM`         | Runner      |

建議版本策略：`Up to Next Major`，選當下最新 tag。

> 若 CI / Archive 時報 Metal / `_xpc_target_...` 連結錯誤，通常是 WhisperKit / llama.cpp 需要較新的 iOS 部署目標。請把 Runner 的 **iOS Deployment Target 設為 16.0**（WhisperKit 要求 iOS 16+）。

## 2) 放置 Whisper-small Core ML 模型

從 HuggingFace 下載 Argmax 打包好的 `openai_whisper-small`：

```
https://huggingface.co/argmaxinc/whisperkit-coreml/tree/main/openai_whisper-small
```

把 **整個 `openai_whisper-small` 資料夾**（含 `AudioEncoder.mlmodelc`、`TextDecoder.mlmodelc`、`MelSpectrogram.mlmodelc`、`config.json`、`tokenizer.json` 等）拖進 Xcode：

```
Runner/
  Models/
    openai_whisper-small/        <-- 整個資料夾（以 "Create folder references" 方式加入）
      AudioEncoder.mlmodelc/
      TextDecoder.mlmodelc/
      MelSpectrogram.mlmodelc/
      ... (tokenizer/, config.json, etc.)
```

加入時務必勾選：
- [x] **Copy items if needed**
- [x] **Create folder references**（藍色資料夾，而非黃色 group）
- [x] **Add to targets → Runner**

> 若用 group 加入，`Bundle.main.url(forResource: ..., subdirectory: "Models")` 會找不到。

## 3) Qwen-2.5-1.5B GGUF 模型下載設定

`ModelDownloader.swift` 裡的 `Config`：

```swift
struct Config {
    static let downloadURL: String = ""  // ← 填這個
    static let sha256Hex: String  = ""   // ← 強烈建議填
    static let expectedBytes: Int64 = 0
}
```

推薦來源：

```
https://huggingface.co/unsloth/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/Qwen2.5-1.5B-Instruct-Q4_K_M.gguf
```

建議做法：
1. 在你控制的 CDN（Cloudflare R2 / AWS S3 / 自家 nginx）放一份，避免 HF 限流或網址變動。
2. 下載後 `shasum -a 256 Qwen2.5-1.5B-Instruct-Q4_K_M.gguf`，把 64 字元的 hex 填進 `sha256Hex`。
3. `expectedBytes` 填實際 size（純粹用來在 Content-Length 缺失時估進度，可不填）。

## 4) Info.plist

現有已含 `NSMicrophoneUsageDescription` 與 `NSSpeechRecognitionUsageDescription`，**無需再改**。
（WhisperKit 自己不需要 `Permission.speech`，但保留可讓 online 模式 fall back 到 Apple Speech Framework。）

## 5) 建置與測試

```bash
cd ios && pod install
cd .. && flutter run -d <iPhone id>
```

- 第一次啟動：進「更多 → 離線 AI 模型」→ 點「下載 Qwen」。下載完成後會自動載入。
- 把網路關掉 / 飛航模式：`線上/離線 辨識` 設定 = 「關」或「自動」即觸發 Whisper + Qwen 路徑。

## 常見問題

| 症狀 | 可能原因 |
| ---- | -------- |
| 「Bundle 找不到 Models/openai_whisper-small」 | Whisper 模型沒拖進去 / 用成 group（黃色）而非 folder reference（藍色） |
| 「離線翻譯尚未就緒」 | Qwen GGUF 還沒下載，進設定頁點下載 |
| 「未設定 ModelDownloader.Config.downloadURL」 | 忘了填 `Config.downloadURL` |
| SHA256 不一致 | CDN 上的檔案被換過；更新 `sha256Hex` 或重上傳 |
| WhisperKit 編譯錯誤 | iOS deployment target 未升到 16.0 |
| LLM.swift 連結錯誤 | 確認 `LLM` product 有加到 Runner 而不是被 unchecked |

## 架構摘要

```
┌──────────────────────── Flutter / Dart ─────────────────────────┐
│ lib/main.dart                                                   │
│   _listenNow()      ─────(iOS + offline)──▶ _offlineAi.start… │
│   _translateOffline()────(iOS)────────────▶ _offlineAi.trans… │
│ lib/offline_ai_service.dart (MethodChannel/EventChannel)       │
└───────────────────────────┬─────────────────────────────────────┘
                            │  com.translate_app/offline_ai
┌───────────────────────────▼─────────────────────────────────────┐
│ ios/Runner/OfflineAI/OfflineAIPlugin.swift  (dispatcher)        │
│ ├─ WhisperService.swift     →  WhisperKit (SPM) + AVAudioEngine │
│ ├─ LlamaService.swift       →  LLM.swift (SPM, llama.cpp)       │
│ └─ ModelDownloader.swift    →  URLSession + CryptoKit SHA256    │
└─────────────────────────────────────────────────────────────────┘
```
