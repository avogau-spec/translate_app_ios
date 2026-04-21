# iOS Offline AI 模組設置步驟

這個資料夾內的 Swift 檔案提供 iOS 上的離線語音辨識（Whisper-small）與離線翻譯（Qwen-2.5-1.5B-Instruct Q4_K_M）。

兩個模型都以 **直接打包進 Runner app bundle** 的方式提供，App 啟動時從 bundle 讀取，毋須下載或網路。以下步驟必須在 **Mac + Xcode** 上做，Windows 的 Flutter 端不會自動幫你加。

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

## 3) 放置 Qwen-2.5-1.5B-Instruct Q4_K_M GGUF（直接內建）

從 HuggingFace 下載：

```
https://huggingface.co/unsloth/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/Qwen2.5-1.5B-Instruct-Q4_K_M.gguf
```

檔名建議維持大小寫 `Qwen2.5-1.5B-Instruct-Q4_K_M.gguf`（`LlamaService` 也相容 lower-case `qwen2.5-1.5b-instruct-q4_k_m.gguf`）。

拖進 Xcode Runner target 的 `Models/` 資料夾（或 Runner 根目錄）：

```
Runner/
  Models/
    Qwen2.5-1.5B-Instruct-Q4_K_M.gguf   <-- ~1GB，以一般檔案（非 folder reference）方式加入
```

加入時務必勾選：
- [x] **Copy items if needed**
- [x] **Add to targets → Runner**
- [x] Target Membership 為 `Runner`

> GGUF 是單一檔案，加入方式是「Create groups」或單純 add file 即可，**不要** 用 folder reference。`LlamaService.bundledModelURL()` 會在 bundle 根目錄與 `Models/` 子目錄同時搜尋。

> 加上 ~1GB 檔案會讓 `.ipa` / `.xcarchive` 顯著變大；首次 Archive 需要多花一點時間。上架 App Store 時注意 IPA 大小限制（目前 4GB）。若走企業內部分發或 TestFlight，1GB 屬於可接受範圍。

> 若你已有先前版本透過 `ModelDownloader` 下載到 `Application Support/OfflineAI/qwen2.5-1.5b-instruct-q4_k_m.gguf` 的檔案，`prewarmIfReady()` 在 bundle 找不到模型時會自動 fallback 去讀這個路徑，可平滑升級。

## 4) Info.plist

現有已含 `NSMicrophoneUsageDescription` 與 `NSSpeechRecognitionUsageDescription`，**無需再改**。
（WhisperKit 自己不需要 `Permission.speech`，但保留可讓 online 模式 fall back 到 Apple Speech Framework。）

## 5) 建置與測試

```bash
cd ios && pod install
cd .. && flutter run -d <iPhone id>
```

- 首次啟動會自動從 bundle 載入 Whisper 與 Qwen（略有數秒預熱），之後進入 `更多 → 離線 AI 模型` 可看到兩顆模型皆顯示「已就緒」。
- 直接打開飛航模式即可測試離線翻譯與辨識。

## 常見問題

| 症狀 | 可能原因 |
| ---- | -------- |
| 「Bundle 找不到 Models/openai_whisper-small」 | Whisper 模型沒拖進去 / 用成 group（黃色）而非 folder reference（藍色） |
| 「Qwen GGUF 未打包於 app bundle」 | Qwen .gguf 未加入 Runner target，或 Target Membership 未勾 |
| IPA 體積過大 | 確認 Qwen 只存在一份（別同時放 bundle 與 Application Support），上架需符合平台大小限制 |
| WhisperKit 編譯錯誤 | iOS deployment target 未升到 16.0 |
| LLM.swift 連結錯誤 | 確認 `LLM` product 有加到 Runner 而不是被 unchecked |

## 架構摘要

```
┌──────────────────────── Flutter / Dart ─────────────────────────┐
│ lib/main.dart                                                   │
│   _listenNow()      ─────(iOS)───────────▶ _offlineAi.start…  │
│   _translateOffline()────(iOS)────────────▶ _offlineAi.trans… │
│ lib/offline_ai_service.dart (MethodChannel/EventChannel)       │
└───────────────────────────┬─────────────────────────────────────┘
                            │  com.translate_app/offline_ai
┌───────────────────────────▼─────────────────────────────────────┐
│ ios/Runner/OfflineAI/OfflineAIPlugin.swift  (dispatcher)        │
│ ├─ WhisperService.swift     →  WhisperKit (SPM) + AVAudioEngine │
│ ├─ LlamaService.swift       →  LLM.swift (SPM, llama.cpp)       │
│ │      └─ 讀取 Runner bundle 內 Qwen GGUF（毋須下載）             │
│ └─ ModelDownloader.swift    →  [已停用] 保留檔案以便 Xcode 參照    │
└─────────────────────────────────────────────────────────────────┘
```
