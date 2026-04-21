import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// iOS 端 on-device AI（Whisper-small + Qwen-2.5-1.5B-Instruct INT4）橋接。
///
/// 所有重運算（mic I/O、Whisper Core ML、llama.cpp GGUF 推理）都在 Swift 端完成，
/// Flutter 端只負責 UI 狀態、觸發與事件接收。
///
/// Android 目前未實作，[isSupported] 會回 `false`，呼叫端請走原本 ML Kit / `speech_to_text` 路徑。
class OfflineAIService {
  OfflineAIService._();
  static final OfflineAIService instance = OfflineAIService._();

  static const MethodChannel _method = MethodChannel('com.translate_app/offline_ai');
  static const EventChannel _events = EventChannel('com.translate_app/offline_ai/events');

  StreamSubscription<dynamic>? _eventsSub;
  final StreamController<OfflineSttEvent> _sttController = StreamController<OfflineSttEvent>.broadcast();
  final StreamController<OfflineLlmProgress> _llmProgressController = StreamController<OfflineLlmProgress>.broadcast();

  bool _initialized = false;

  /// 原生側是否支援（目前僅 iOS 走新路徑）。
  bool get isSupported => !kIsWeb && Platform.isIOS;

  Stream<OfflineSttEvent> get sttEvents => _sttController.stream;
  Stream<OfflineLlmProgress> get llmProgress => _llmProgressController.stream;

  /// App 啟動階段呼叫一次。
  ///
  /// - 檢查 bundle 內 Whisper 模型是否就緒
  /// - 檢查 Documents 下 Qwen GGUF 是否已下載（不會自動觸發下載）
  Future<OfflineAIStatus> initialize() async {
    if (!isSupported) {
      return const OfflineAIStatus(whisperReady: false, llmReady: false, llmDownloading: false);
    }
    if (!_initialized) {
      _eventsSub = _events.receiveBroadcastStream().listen(_handleEvent, onError: _handleError);
      _initialized = true;
    }
    final Map<dynamic, dynamic>? raw = await _method.invokeMethod<Map<dynamic, dynamic>>('status');
    return OfflineAIStatus.fromMap(raw ?? const <dynamic, dynamic>{});
  }

  /// 讓原生端把兩個模型都讀進記憶體（首句延遲會小一點）。只做預熱；不會下載。
  Future<void> prewarm() async {
    if (!isSupported) return;
    await _method.invokeMethod<void>('prewarm');
  }

  /// 觸發 Qwen GGUF 下載（若缺）；進度透過 [llmProgress] 推送。
  Future<void> ensureLlmDownloaded() async {
    if (!isSupported) return;
    await _method.invokeMethod<void>('ensureLlmDownloaded');
  }

  /// 開始離線 STT：Swift 端啟用麥克風 + WhisperKit streaming。
  ///
  /// [languageTag] 例如 `ja-JP`、`en-US`、`zh-TW`；Whisper 以此強制語言。
  Future<void> startListening(String languageTag) async {
    if (!isSupported) {
      throw const OfflineAINotSupportedException();
    }
    await _method.invokeMethod<void>('startListening', <String, dynamic>{
      'language': languageTag,
    });
  }

  Future<void> stopListening() async {
    if (!isSupported) return;
    await _method.invokeMethod<void>('stopListening');
  }

  /// 用 Qwen 翻譯。[sourceTag] / [targetTag] 例如 `ja` / `zh-TW`。
  Future<String> translate({
    required String text,
    required String sourceTag,
    required String targetTag,
    String? locationHint,
  }) async {
    if (!isSupported) {
      throw const OfflineAINotSupportedException();
    }
    final String? result = await _method.invokeMethod<String>('translate', <String, dynamic>{
      'text': text,
      'source': sourceTag,
      'target': targetTag,
      if (locationHint != null && locationHint.isNotEmpty) 'locationHint': locationHint,
    });
    return (result ?? '').trim();
  }

  Future<void> dispose() async {
    await _eventsSub?.cancel();
    await _sttController.close();
    await _llmProgressController.close();
  }

  void _handleEvent(dynamic data) {
    if (data is! Map) return;
    final Map<dynamic, dynamic> map = data;
    final String? type = map['type'] as String?;
    if (type == null) return;
    switch (type) {
      case 'stt.partial':
        _sttController.add(OfflineSttEvent.partial(map['text'] as String? ?? ''));
        break;
      case 'stt.final':
        _sttController.add(OfflineSttEvent.finalResult(map['text'] as String? ?? ''));
        break;
      case 'stt.status':
        _sttController.add(OfflineSttEvent.status(map['status'] as String? ?? ''));
        break;
      case 'stt.error':
        _sttController.add(OfflineSttEvent.error(map['message'] as String? ?? 'unknown'));
        break;
      case 'llm.progress':
        _llmProgressController.add(OfflineLlmProgress(
          downloaded: (map['downloaded'] as num?)?.toInt() ?? 0,
          total: (map['total'] as num?)?.toInt() ?? 0,
          state: OfflineLlmState.downloading,
          message: map['message'] as String?,
        ));
        break;
      case 'llm.ready':
        _llmProgressController.add(const OfflineLlmProgress(
          downloaded: 0,
          total: 0,
          state: OfflineLlmState.ready,
        ));
        break;
      case 'llm.error':
        _llmProgressController.add(OfflineLlmProgress(
          downloaded: 0,
          total: 0,
          state: OfflineLlmState.error,
          message: map['message'] as String?,
        ));
        break;
    }
  }

  void _handleError(Object error) {
    _sttController.add(OfflineSttEvent.error(error.toString()));
  }
}

class OfflineAIStatus {
  const OfflineAIStatus({
    required this.whisperReady,
    required this.llmReady,
    required this.llmDownloading,
    this.whisperModelName,
    this.llmModelName,
    this.llmBytes,
    this.llmBytesTotal,
  });

  final bool whisperReady;
  final bool llmReady;
  final bool llmDownloading;
  final String? whisperModelName;
  final String? llmModelName;
  final int? llmBytes;
  final int? llmBytesTotal;

  factory OfflineAIStatus.fromMap(Map<dynamic, dynamic> map) {
    return OfflineAIStatus(
      whisperReady: map['whisperReady'] == true,
      llmReady: map['llmReady'] == true,
      llmDownloading: map['llmDownloading'] == true,
      whisperModelName: map['whisperModelName'] as String?,
      llmModelName: map['llmModelName'] as String?,
      llmBytes: (map['llmBytes'] as num?)?.toInt(),
      llmBytesTotal: (map['llmBytesTotal'] as num?)?.toInt(),
    );
  }
}

enum OfflineSttEventType { partial, finalResult, status, error }

class OfflineSttEvent {
  const OfflineSttEvent._(this.type, this.text);
  const OfflineSttEvent.partial(String text) : this._(OfflineSttEventType.partial, text);
  const OfflineSttEvent.finalResult(String text) : this._(OfflineSttEventType.finalResult, text);
  const OfflineSttEvent.status(String s) : this._(OfflineSttEventType.status, s);
  const OfflineSttEvent.error(String msg) : this._(OfflineSttEventType.error, msg);

  final OfflineSttEventType type;
  final String text;
}

enum OfflineLlmState { idle, downloading, ready, error }

class OfflineLlmProgress {
  const OfflineLlmProgress({
    required this.downloaded,
    required this.total,
    required this.state,
    this.message,
  });

  final int downloaded;
  final int total;
  final OfflineLlmState state;
  final String? message;

  double? get ratio => total > 0 ? (downloaded / total).clamp(0.0, 1.0) : null;
}

class OfflineAINotSupportedException implements Exception {
  const OfflineAINotSupportedException();
  @override
  String toString() => 'OfflineAIService is only available on iOS in this build.';
}
