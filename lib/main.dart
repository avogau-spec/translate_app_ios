import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_generative_ai/google_generative_ai.dart';
import 'package:google_mlkit_translation/google_mlkit_translation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:share_plus/share_plus.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:wakelock_plus/wakelock_plus.dart';

import 'offline_ai_service.dart';

const String kPrimaryKeyPref = 'primary_api_key';
const String kSecondaryKeyPref = 'secondary_api_key';
const String kSelectedModelPref = 'selected_model';
const String kDailyCountPref = 'daily_count';
const String kLastResetMarkerPref = 'last_reset_marker_utc_ms';
const String kHistoryPref = 'translation_history_v1';
const String kOfflinePromptShownPref = 'offline_prompt_shown_v1';
const String kAutoReturnPrimaryPref = 'auto_return_primary_v1';
const String kInputLangIdPref = 'input_lang_id_v1';
const String kOutputLangIdPref = 'output_lang_id_v1';
const String kSpeechModePref = 'speech_mode_v1';
const String kLocationOptimizePref = 'location_optimize_v1';
const String kTranslationFontSizePref = 'translation_font_size_v1';
const String kMainDisplayModePref = 'main_display_mode_v1';
const int kDailyQuotaLimit = 250;
/// 無可用清單時送 API 的備援 model id。
const String kDefaultModel = 'gemini-3.1-flash-lite';
/// 選單預設項（存 SharedPreferences）。
const String kDefaultModelSlot = 'gemini_3_1_flash_lite';
/// 歷史紀錄保留上限；0 代表無上限。
const int kHistoryMaxItems = 0;

/// 固定選項：顯示名稱 + 與 API 清單比對時用的錨點 id（可再經 [_resolveGeminiModelId] 對上 `-preview` 等）。
class ModelMenuSlot {
  const ModelMenuSlot({
    required this.key,
    required this.label,
    required this.anchor,
  });

  final String key;
  final String label;
  final String anchor;
}

const List<ModelMenuSlot> kModelMenuSlots = <ModelMenuSlot>[
  ModelMenuSlot(
    key: 'gemini_3_1_flash_lite',
    label: 'Gemini 3.1 Flash Lite',
    anchor: 'gemini-3.1-flash-lite',
  ),
  ModelMenuSlot(
    key: 'gemini_3_flash',
    label: 'Gemini 3 Flash',
    anchor: 'gemini-3-flash',
  ),
  ModelMenuSlot(
    key: 'gemma_3_27b',
    label: 'Gemma 3 27B',
    anchor: 'gemma-3-27b',
  ),
  ModelMenuSlot(
    key: 'gemini_2_5_flash',
    label: 'Gemini 2.5 Flash',
    anchor: 'gemini-2.5-flash',
  ),
  ModelMenuSlot(
    key: 'gemini_2_5_flash_lite',
    label: 'Gemini 2.5 Flash Lite',
    anchor: 'gemini-2.5-flash-lite',
  ),
];

/// API 失敗時的備援（不顯示 RPD；實際清單以啟動／開設定時向 Gemini 拉取為主）。
const List<String> kFallbackGeminiModelIds = <String>[
  'gemini-3.1-flash-lite',
  'gemini-3.1-flash',
  'gemini-2.0-flash-lite',
  'gemma-3-27b-it',
];

bool _isKnownModelSlot(String? s) =>
    s != null && kModelMenuSlots.any((ModelMenuSlot e) => e.key == s);

String _labelForModelSlot(String slotKey) {
  for (final ModelMenuSlot s in kModelMenuSlots) {
    if (s.key == slotKey) {
      return s.label;
    }
  }
  return kModelMenuSlots.first.label;
}

String _anchorForModelSlot(String slotKey) {
  for (final ModelMenuSlot s in kModelMenuSlots) {
    if (s.key == slotKey) {
      return s.anchor;
    }
  }
  return kModelMenuSlots.first.anchor;
}

/// 依選項鍵篩出 API 清單中屬於該系列的 id。
List<String> _candidatesForModelSlot(String slotKey, List<String> available) {
  bool test(String id) {
    switch (slotKey) {
      case 'gemini_3_1_flash_lite':
        return id.contains('gemini-3.1-flash-lite');
      case 'gemini_3_flash':
        return (id.contains('gemini-3-flash') || id.contains('gemini-3.0-flash')) &&
            !id.contains('gemini-3.1');
      case 'gemma_3_27b':
        return id.contains('gemma-3-27b');
      case 'gemini_2_5_flash':
        return id.contains('gemini-2.5-flash') && !id.contains('flash-lite');
      case 'gemini_2_5_flash_lite':
        return id.contains('gemini-2.5-flash-lite');
      default:
        return false;
    }
  }

  final List<String> out = available.where(test).toList()..sort();
  return out;
}

/// 將舊版儲存的 API model id 轉成選單鍵；無法辨識則 [kDefaultModelSlot]。
String _migrateStoredModelToSlot(String stored) {
  if (_isKnownModelSlot(stored)) {
    return stored;
  }
  for (final ModelMenuSlot s in kModelMenuSlots) {
    if (_candidatesForModelSlot(s.key, <String>[stored]).isNotEmpty) {
      return s.key;
    }
  }
  return kDefaultModelSlot;
}

/// 清單中該系列無任何候選時回傳 `null`（不改用清單第一筆）。
String? _apiIdForModelSlot(String slotKey, List<String> available) {
  if (available.isEmpty) {
    return null;
  }
  final List<String> narrowed = _candidatesForModelSlot(slotKey, available);
  if (narrowed.isEmpty) {
    return null;
  }
  return _resolveGeminiModelId(_anchorForModelSlot(slotKey), narrowed);
}

/// 依 [kModelMenuSlots] 順序，回傳第一個在 [available] 中有候選的選單鍵。
String? _firstModelSlotWithCandidates(List<String> available) {
  if (available.isEmpty) {
    return null;
  }
  for (final ModelMenuSlot s in kModelMenuSlots) {
    if (_candidatesForModelSlot(s.key, available).isNotEmpty) {
      return s.key;
    }
  }
  return null;
}

/// 將使用者偏好或舊版儲存的 id 對應到 [available] 裡實際存在的 id。
/// Google 常把同一模型加上 `-preview`、`-001` 等後綴；API 只接受清單內精確字串。
String _resolveGeminiModelId(String preferred, List<String> available) {
  if (available.isEmpty) {
    return preferred;
  }
  if (available.contains(preferred)) {
    return preferred;
  }
  final List<String> asSuffix = available.where((String id) => id.startsWith('$preferred-')).toList()..sort();
  if (asSuffix.isNotEmpty) {
    return asSuffix.first;
  }
  String? best;
  for (final String id in available) {
    if (preferred.startsWith('$id-')) {
      if (best == null || id.length > best.length) {
        best = id;
      }
    }
  }
  if (best != null) {
    return best;
  }
  return available.first;
}

/// 依螢幕寬度（參考 iPhone 14 Pro ~390dp、小屏 ~320–360dp）調整字級與間距，避免重疊與譯文區被壓扁。
class _MainUiTokens {
  _MainUiTokens({
    required this.edgePadding,
    required this.cardPadding,
    required this.metaFont,
    required this.sourceLabelFont,
    required this.sourceBodyFont,
    required this.targetLabelFont,
    required this.translationFont,
    required this.bigButtonHeight,
    required this.bigButtonFont,
    required this.bigIconSize,
    required this.footerFont,
    required this.compact,
  });

  final double edgePadding;
  final double cardPadding;
  final double metaFont;
  final double sourceLabelFont;
  final double sourceBodyFont;
  final double targetLabelFont;
  final double translationFont;
  final double bigButtonHeight;
  final double bigButtonFont;
  final double bigIconSize;
  final double footerFont;
  final bool compact;

  static _MainUiTokens from(
    BuildContext context, {
    AppTranslationFontSize translationFontSize = AppTranslationFontSize.medium,
  }) {
    final double w = MediaQuery.sizeOf(context).width;
    final double h = MediaQuery.sizeOf(context).height;
    final double shortSide = math.min(w, h);
    // 以 390 為基準；極窄機（如部分 Samsung 系列）再略縮
    final double base = (w / 390.0).clamp(0.72, 1.05);
    final double shortBoost = shortSide < 700 ? 1.0 : 1.02;
    final double s = (base * shortBoost).clamp(0.72, 1.08);
    final bool compact = w < 376;
    final bool narrow = w < 360;
    final double baseTranslation = (30.0 * s).clamp(20.0, 32.0);
    final double translationScale = switch (translationFontSize) {
      AppTranslationFontSize.large => 1.0,
      AppTranslationFontSize.medium => 0.82,
      AppTranslationFontSize.small => 0.66,
    };
    return _MainUiTokens(
      edgePadding: (narrow ? 10.0 : 12.0) * s,
      cardPadding: (narrow ? 10.0 : 14.0) * s,
      metaFont: (12.0 * s).clamp(10.5, 13.0),
      sourceLabelFont: (11.5 * s).clamp(10.0, 12.5),
      sourceBodyFont: (15.0 * s).clamp(12.5, 16.5),
      targetLabelFont: (12.5 * s).clamp(11.0, 13.5),
      translationFont: (baseTranslation * translationScale).clamp(14.0, 36.0),
      bigButtonHeight: (72.0 * s).clamp(56.0, 84.0),
      bigButtonFont: (26.0 * s).clamp(20.0, 30.0),
      bigIconSize: (30.0 * s).clamp(24.0, 34.0),
      footerFont: (11.0 * s).clamp(9.5, 12.0),
      compact: compact,
    );
  }
}

enum SpeechMode {
  online,
  offline,
  auto,
}

/// 譯文字級：大＝改版前預設；中為新預設。
enum AppTranslationFontSize {
  small,
  medium,
  large,
}

AppTranslationFontSize _translationFontSizeFromStorage(String? s) {
  switch (s) {
    case 'small':
      return AppTranslationFontSize.small;
    case 'large':
      return AppTranslationFontSize.large;
    default:
      return AppTranslationFontSize.medium;
  }
}

String _translationFontSizeToStorage(AppTranslationFontSize size) {
  switch (size) {
    case AppTranslationFontSize.small:
      return 'small';
    case AppTranslationFontSize.medium:
      return 'medium';
    case AppTranslationFontSize.large:
      return 'large';
  }
}

/// 主畫面：只顯示目前一句，或累積本場對話（仍寫入歷史紀錄）。
enum MainDisplayMode {
  currentPhrase,
  conversation,
}

MainDisplayMode _mainDisplayModeFromStorage(String? s) {
  switch (s) {
    case 'current':
      return MainDisplayMode.currentPhrase;
    case 'conversation':
      return MainDisplayMode.conversation;
    default:
      return MainDisplayMode.conversation;
  }
}

String _mainDisplayModeToStorage(MainDisplayMode mode) {
  switch (mode) {
    case MainDisplayMode.currentPhrase:
      return 'current';
    case MainDisplayMode.conversation:
      return 'conversation';
  }
}

class TranscriptTurn {
  TranscriptTurn({required this.source, required this.translation});

  final String source;
  final String translation;
}

/// 順序：中文、日文、英文、韓文、西班牙文、法文（選單顯示用）
class AppLanguage {
  const AppLanguage({
    required this.id,
    required this.label,
    required this.localeId,
    required this.mlkit,
  });

  final String id;
  final String label;
  final String localeId;
  final TranslateLanguage mlkit;
}

const List<AppLanguage> kAppLanguages = <AppLanguage>[
  AppLanguage(id: 'zh', label: '中文', localeId: 'zh-TW', mlkit: TranslateLanguage.chinese),
  AppLanguage(id: 'ja', label: '日文', localeId: 'ja-JP', mlkit: TranslateLanguage.japanese),
  AppLanguage(id: 'en', label: '英文', localeId: 'en-US', mlkit: TranslateLanguage.english),
  AppLanguage(id: 'ko', label: '韓文', localeId: 'ko-KR', mlkit: TranslateLanguage.korean),
  AppLanguage(id: 'es', label: '西班牙文', localeId: 'es-ES', mlkit: TranslateLanguage.spanish),
  AppLanguage(id: 'fr', label: '法文', localeId: 'fr-FR', mlkit: TranslateLanguage.french),
];

AppLanguage _langById(String id) {
  return kAppLanguages.firstWhere(
    (AppLanguage e) => e.id == id,
    orElse: () => kAppLanguages[1],
  );
}

SpeechMode _speechModeFromStorage(String? s) {
  switch (s) {
    case 'online':
      return SpeechMode.online;
    case 'offline':
      return SpeechMode.offline;
    default:
      return SpeechMode.auto;
  }
}

String _speechModeToStorage(SpeechMode m) {
  switch (m) {
    case SpeechMode.online:
      return 'online';
    case SpeechMode.offline:
      return 'offline';
    case SpeechMode.auto:
      return 'auto';
  }
}

class TranslationEntry {
  TranslationEntry({
    required this.timestampIso,
    required this.locale,
    required this.source,
    required this.translation,
  });

  final String timestampIso;
  final String locale;
  final String source;
  final String translation;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'timestampIso': timestampIso,
        'locale': locale,
        'source': source,
        'translation': translation,
      };

  static TranslationEntry fromJson(Map<String, dynamic> json) => TranslationEntry(
        timestampIso: json['timestampIso'] as String? ?? '',
        locale: json['locale'] as String? ?? '',
        source: json['source'] as String? ?? '',
        translation: json['translation'] as String? ?? '',
      );
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const TranslateGuideApp());
}

class TranslateGuideApp extends StatelessWidget {
  const TranslateGuideApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      home: const LiveTranslatePage(),
    );
  }
}

class LiveTranslatePage extends StatefulWidget {
  const LiveTranslatePage({super.key});

  @override
  State<LiveTranslatePage> createState() => _LiveTranslatePageState();
}

class _LiveTranslatePageState extends State<LiveTranslatePage> {
  final stt.SpeechToText _speech = stt.SpeechToText();
  final TextEditingController _primaryKeyController = TextEditingController();
  final TextEditingController _secondaryKeyController = TextEditingController();

  SharedPreferences? _prefs;
  ChatSession? _chatSession;
  Timer? _pauseTimer;
  Timer? _networkTimer;
  late final OnDeviceTranslatorModelManager _modelManager;
  OnDeviceTranslator? _offlineTranslator;
  final Connectivity _connectivity = Connectivity();

  // === iOS 離線 AI（Whisper-small + Qwen-2.5-1.5B INT4） ===
  final OfflineAIService _offlineAi = OfflineAIService.instance;
  OfflineAIStatus _offlineAiStatus = const OfflineAIStatus(
    whisperReady: false,
    llmReady: false,
    llmDownloading: false,
  );
  StreamSubscription<OfflineSttEvent>? _offlineSttSub;
  StreamSubscription<OfflineLlmProgress>? _offlineLlmSub;
  /// 本次 listen 是否透過 OfflineAIService 開啟（決定 stop 時要不要呼叫原生 stop）。
  bool _offlineAiListening = false;

  bool _isInitialized = false;
  bool _isListening = false;
  bool _isSettingsOpen = false;
  bool _usingSecondary = false;
  bool _offlinePromptShown = false;
  /// 同一次啟動內已提示過離線翻譯模型未備齊（避免每次進前景都刷 SnackBar）。
  bool _offlineTranslationModelHintShown = false;
  /// 離線語音辨識：同一次輸入語言設定下是否已顯示過說明（換輸入語言會重設）。
  bool _offlineSttUxShown = false;
  bool _hasInternet = true;
  /// 避免 on-device 語音發生無法恢復錯誤後，[onStatus] 仍觸發 [_restartListeningIfNeeded] 造成無限重試。
  bool _suppressListenRestart = false;
  bool _lastOnDeviceApplied = false;
  bool _autoReturnPrimary = true;
  bool _locationOptimize = true;
  String _approximateLocationLabel = '';
  DateTime? _lastLocationFetchedAt;

  String _selectedModel = kDefaultModelSlot;
  /// 預設：輸入日文、輸出中文（見 [kAppLanguages] id）
  String _inputLangId = 'ja';
  String _outputLangId = 'zh';
  SpeechMode _speechMode = SpeechMode.auto;
  AppTranslationFontSize _translationFontSize = AppTranslationFontSize.medium;
  MainDisplayMode _displayMode = MainDisplayMode.conversation;
  final List<TranscriptTurn> _transcript = <TranscriptTurn>[];
  final ScrollController _transcriptScrollController = ScrollController();

  String get _sourceLocale => _langById(_inputLangId).localeId;
  String _sourceText = '等待語音輸入...';
  String _translatedText = '';
  String _liveRecognized = '';
  String _lastSubmitted = '';
  // 「目前一段」模式下，用來判斷 abc -> abcd -> abcdef 是否要更新同一筆歷史
  String _lastCurrentPhraseSourceForHistory = '';
  String _lastCurrentPhraseTranslationForHistory = '';
  DateTime? _lastSpeechUpdatedAt;
  DateTime? _lastPrimaryRecoveryAttemptAt;

  int _dailyCount = 0;
  bool _isExporting = false;
  List<TranslationEntry> _history = <TranslationEntry>[];

  /// 由 Gemini `v1beta/models` 拉取；失敗時為 [kFallbackGeminiModelIds]。
  List<String> _availableModelIds = List<String>.from(kFallbackGeminiModelIds);
  // ignore: unused_field
  bool _modelsLoading = false;

  @override
  void initState() {
    super.initState();
    _modelManager = OnDeviceTranslatorModelManager();
    _bootstrap();
    _initOfflineAi();
  }

  @override
  void dispose() {
    _pauseTimer?.cancel();
    _networkTimer?.cancel();
    _speech.stop();
    _offlineTranslator?.close();
    _offlineSttSub?.cancel();
    _offlineLlmSub?.cancel();
    if (_offlineAiListening) {
      unawaited(_offlineAi.stopListening());
    }
    _primaryKeyController.dispose();
    _secondaryKeyController.dispose();
    _transcriptScrollController.dispose();
    // 防止離開頁面後 wakelock 沒被關掉。
    unawaited(WakelockPlus.disable());
    super.dispose();
  }

  void _clearMainDisplay() {
    setState(() {
      _transcript.clear();
      _sourceText = '等待語音輸入...';
      _translatedText = '';
      _lastSubmitted = '';
      _liveRecognized = '';
      _lastCurrentPhraseSourceForHistory = '';
      _lastCurrentPhraseTranslationForHistory = '';
    });
  }

  void _scrollTranscriptToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_transcriptScrollController.hasClients) {
        return;
      }
      _transcriptScrollController.animateTo(
        _transcriptScrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOut,
      );
    });
  }

  bool get _showLiveTranscriptStrip {
    if (!_isListening) {
      return false;
    }
    final String s = _sourceText;
    return s.isNotEmpty && s != '等待語音輸入...';
  }

  Widget _buildCurrentPhraseCardContent(
    _MainUiTokens ui,
    String sourceLabel,
    String targetLabel,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          sourceLabel,
          style: TextStyle(fontSize: ui.sourceLabelFont, color: Colors.grey),
        ),
        SizedBox(height: ui.compact ? 2 : 4),
        Expanded(
          flex: 1,
          child: SingleChildScrollView(
            child: Text(
              _sourceText,
              style: TextStyle(
                fontSize: ui.sourceBodyFont,
                color: Colors.grey,
                height: 1.35,
              ),
            ),
          ),
        ),
        SizedBox(height: ui.compact ? 4 : 6),
        Text(
          targetLabel,
          style: TextStyle(fontSize: ui.targetLabelFont, color: Colors.white70),
        ),
        SizedBox(height: ui.compact ? 2 : 3),
        Expanded(
          flex: 4,
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              return Align(
                alignment: Alignment.bottomLeft,
                child: FittedBox(
                  alignment: Alignment.bottomLeft,
                  fit: BoxFit.scaleDown,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: constraints.maxWidth),
                    child: Text(
                      _translatedText.isEmpty ? '\u00A0' : _translatedText,
                      style: TextStyle(
                        fontSize: ui.translationFont,
                        fontWeight: FontWeight.w800,
                        color: Colors.white,
                        height: 1.22,
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildConversationCardContent(
    _MainUiTokens ui,
    String sourceLabel,
    String targetLabel,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          '本場對話',
          style: TextStyle(fontSize: ui.sourceLabelFont, color: Colors.grey),
        ),
        SizedBox(height: ui.compact ? 6 : 8),
        Expanded(
          child: _transcript.isEmpty
              ? Center(
                  child: Text(
                    _showLiveTranscriptStrip
                        ? '完成一句後會列在上方。\n即時辨識見下方。'
                        : '尚無對話，按下「開始」語音翻譯',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: ui.metaFont, color: Colors.grey),
                  ),
                )
              : ListView.builder(
                  controller: _transcriptScrollController,
                  padding: const EdgeInsets.only(bottom: 8),
                  itemCount: _transcript.length,
                  itemBuilder: (BuildContext context, int index) {
                    final TranscriptTurn t = _transcript[index];
                    return Padding(
                      padding: EdgeInsets.only(bottom: ui.compact ? 10 : 14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            sourceLabel,
                            style: TextStyle(fontSize: ui.sourceLabelFont, color: Colors.grey),
                          ),
                          SizedBox(height: ui.compact ? 2 : 4),
                          Text(
                            t.source,
                            style: TextStyle(
                              fontSize: ui.sourceBodyFont,
                              color: Colors.grey,
                              height: 1.35,
                            ),
                          ),
                          SizedBox(height: ui.compact ? 6 : 8),
                          Text(
                            targetLabel,
                            style: TextStyle(fontSize: ui.targetLabelFont, color: Colors.white70),
                          ),
                          SizedBox(height: ui.compact ? 2 : 4),
                          Text(
                            t.translation,
                            style: TextStyle(
                              fontSize: ui.translationFont,
                              fontWeight: FontWeight.w800,
                              color: Colors.white,
                              height: 1.22,
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
        if (_showLiveTranscriptStrip) ...<Widget>[
          const Divider(height: 1, color: Colors.white24),
          SizedBox(height: ui.compact ? 4 : 6),
          Text(
            '即時辨識',
            style: TextStyle(fontSize: ui.sourceLabelFont, color: Colors.amber.shade200),
          ),
          SizedBox(height: ui.compact ? 2 : 4),
          Text(
            _sourceText,
            style: TextStyle(
              fontSize: ui.sourceBodyFont,
              color: Colors.grey,
              height: 1.35,
            ),
          ),
        ],
      ],
    );
  }

  Future<void> _bootstrap() async {
    _prefs = await SharedPreferences.getInstance();
    _selectedModel = _migrateStoredModelToSlot(_prefs!.getString(kSelectedModelPref) ?? kDefaultModelSlot);
    if (!_isKnownModelSlot(_selectedModel)) {
      _selectedModel = kDefaultModelSlot;
    }
    _coerceSelectedModelToAvailableSlot();
    _primaryKeyController.text = _prefs!.getString(kPrimaryKeyPref) ?? '';
    _secondaryKeyController.text = _prefs!.getString(kSecondaryKeyPref) ?? '';
    _offlinePromptShown = _prefs!.getBool(kOfflinePromptShownPref) ?? false;
    _autoReturnPrimary = _prefs!.getBool(kAutoReturnPrimaryPref) ?? true;
    _inputLangId = _prefs!.getString(kInputLangIdPref) ?? 'ja';
    _outputLangId = _prefs!.getString(kOutputLangIdPref) ?? 'zh';
    _speechMode = _speechModeFromStorage(_prefs!.getString(kSpeechModePref));
    _translationFontSize = _translationFontSizeFromStorage(_prefs!.getString(kTranslationFontSizePref));
    _displayMode = _mainDisplayModeFromStorage(_prefs!.getString(kMainDisplayModePref));
    _locationOptimize = _prefs!.getBool(kLocationOptimizePref) ?? true;
    await _maybeResetDailyCounter();
    _loadHistoryFromLocal();
    _startNetworkWatcher();
    setState(() {
      _dailyCount = _prefs!.getInt(kDailyCountPref) ?? 0;
      _isInitialized = true;
    });
    if (!_offlinePromptShown && mounted) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _promptOfflineModelDownload();
      });
    }
    if (_locationOptimize && mounted) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(_refreshApproximateLocation(force: false));
      });
    }
    if (_primaryKeyController.text.trim().isNotEmpty && mounted) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(_refreshModelList());
      });
    }
    if (_offlinePromptShown && mounted) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(_checkOfflineTranslationModelsAfterBootstrap());
      });
    }
  }

  /// 依目前選單鍵 [_selectedModel] 與 API 清單解析出的實際 model id；該系列無候選時為 `null`。
  String? get _effectiveSelectedModel {
    final String slot = _isKnownModelSlot(_selectedModel) ? _selectedModel : kDefaultModelSlot;
    return _apiIdForModelSlot(slot, _availableModelIds);
  }

  void _coerceSelectedModelToAvailableSlot() {
    if (_availableModelIds.isEmpty) {
      return;
    }
    if (_candidatesForModelSlot(_selectedModel, _availableModelIds).isNotEmpty) {
      return;
    }
    final String? slot = _firstModelSlotWithCandidates(_availableModelIds);
    if (slot != null) {
      _selectedModel = slot;
    }
  }

  /// 呼叫 Gemini `v1beta/models`；失敗時使用 [kFallbackGeminiModelIds]。
  Future<void> _refreshModelList() async {
    final String key = _primaryKeyController.text.trim();
    if (key.isEmpty) {
      if (mounted) {
        setState(() {
          _availableModelIds = List<String>.from(kFallbackGeminiModelIds);
          _coerceSelectedModelToAvailableSlot();
        });
      }
      return;
    }
    if (mounted) {
      setState(() {
        _modelsLoading = true;
      });
    }
    HttpClient? client;
    try {
      final Uri uri = Uri.https(
        'generativelanguage.googleapis.com',
        '/v1beta/models',
        <String, String>{'key': key},
      );
      client = HttpClient();
      final HttpClientRequest req = await client.getUrl(uri);
      final HttpClientResponse res = await req.close();
      final String body = await res.transform(utf8.decoder).join();
      if (res.statusCode != 200) {
        throw Exception('HTTP ${res.statusCode}');
      }
      final Map<String, dynamic> json = jsonDecode(body) as Map<String, dynamic>;
      final List<dynamic>? raw = json['models'] as List<dynamic>?;
      if (raw == null) {
        throw Exception('no models');
      }
      final List<String> ids = <String>[];
      for (final dynamic item in raw) {
        final Map<String, dynamic> m = item as Map<String, dynamic>;
        final List<dynamic>? methods = m['supportedGenerationMethods'] as List<dynamic>?;
        if (methods == null || !methods.contains('generateContent')) {
          continue;
        }
        final String name = m['name'] as String? ?? '';
        if (name.startsWith('models/')) {
          ids.add(name.substring(7));
        }
      }
      ids.sort();
      if (!mounted) {
        return;
      }
      setState(() {
        _availableModelIds = ids.isNotEmpty ? ids : List<String>.from(kFallbackGeminiModelIds);
        _coerceSelectedModelToAvailableSlot();
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _availableModelIds = List<String>.from(kFallbackGeminiModelIds);
        _coerceSelectedModelToAvailableSlot();
      });
    } finally {
      client?.close();
      if (mounted) {
        setState(() {
          _modelsLoading = false;
        });
      }
    }
  }

  static const Duration _locationMinInterval = Duration(minutes: 8);

  String _formatPlacemark(Placemark p) {
    final List<String> parts = <String>[];
    for (final String? s in <String?>[p.country, p.administrativeArea, p.locality, p.subLocality]) {
      if (s != null && s.trim().isNotEmpty) {
        parts.add(s.trim());
      }
    }
    return parts.join(' ');
  }

  Future<void> _refreshApproximateLocation({required bool force}) async {
    if (!_locationOptimize || kIsWeb) {
      return;
    }
    final DateTime now = DateTime.now();
    if (!force &&
        _lastLocationFetchedAt != null &&
        now.difference(_lastLocationFetchedAt!) < _locationMinInterval &&
        _approximateLocationLabel.isNotEmpty) {
      return;
    }
    try {
      LocationPermission perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
        if (mounted) {
          setState(() {
            _approximateLocationLabel = '';
          });
        }
        return;
      }
      final Position? lastKnown = await Geolocator.getLastKnownPosition();
      final Position pos;
      if (lastKnown != null && now.difference(lastKnown.timestamp) < const Duration(minutes: 45)) {
        pos = lastKnown;
      } else {
        pos = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.low,
            timeLimit: Duration(seconds: 20),
          ),
        );
      }
      final List<Placemark> marks = await placemarkFromCoordinates(pos.latitude, pos.longitude);
      if (marks.isEmpty) {
        return;
      }
      final String label = _formatPlacemark(marks.first);
      if (mounted) {
        setState(() {
          _approximateLocationLabel = label;
          _lastLocationFetchedAt = now;
        });
        _buildChatSession(forceRecreate: true);
      }
    } catch (_) {
      if (mounted) {
        setState(() {});
      }
    }
  }

  Future<void> _startListening() async {
    if (!_isInitialized) return;
    _suppressListenRestart = false;
    final PermissionStatus micStatus = await Permission.microphone.request();
    final PermissionStatus speechStatus = await Permission.speech.request();
    if (!micStatus.isGranted || !speechStatus.isGranted) {
      _showSnackBar('需要麥克風與語音辨識權限才能進行即時翻譯');
      return;
    }

    final bool available = await _speech.initialize(
      onStatus: (String status) {
        if (status == 'notListening' && _isListening && !_suppressListenRestart) {
          _restartListeningIfNeeded();
        }
      },
      onError: (dynamic error) {
        final String msg = error.errorMsg?.toString() ?? error.toString();
        if (_isBenignSpeechRecognitionError(msg)) {
          if (_isListening) {
            unawaited(_restartListeningIfNeeded());
          }
          return;
        }
        if (_isOnDeviceSpeechFatalError(msg) && _useOnDeviceForSpeech()) {
          _suppressListenRestart = true;
          _showSnackBar(
            '離線語音辨識不支援目前輸入語言（$_sourceLocale）。'
            'ML Kit「翻譯」語言包與系統「語音辨識」無關，請到系統設定安裝語音／下載離線語音資料，或改為「開」並連網辨識。',
          );
          unawaited(_stopListening().then((_) {
            _suppressListenRestart = false;
          }));
          return;
        }
        _showSnackBar('語音辨識錯誤: $msg');
      },
    );

    if (!available) {
      _showSnackBar('裝置不支援語音辨識');
      return;
    }

    await WakelockPlus.enable();
    await _refreshApproximateLocation(force: true);
    setState(() {
      _isListening = true;
      _usingSecondary = false;
      _lastSubmitted = '';
      _sourceText = '開始收音中...';
      _translatedText = '';
    });
    _buildChatSession(forceRecreate: true);
    _startPauseWatcher();
    await _listenNow();
  }

  Future<void> _listenNow() async {
    if (!_isListening) return;
    // 避免手機在辨識重新開始時又進入螢幕休眠。
    await WakelockPlus.enable();
    final bool useOnDevice = _useOnDeviceForSpeech();
    _lastOnDeviceApplied = useOnDevice;

    // iOS 離線模式改走 Whisper-small（on-device）；其餘情況仍用 speech_to_text。
    if (useOnDevice && _offlineAi.isSupported) {
      if (!_offlineAiStatus.whisperReady) {
        _showSnackBar('離線語音模型尚未就緒（Whisper-small 未打包？請先於 Xcode 放入模型）。改用連網辨識中。');
      } else {
        await _startOfflineAiListening();
        return;
      }
    }

    if (useOnDevice) {
      await _maybeShowOfflineSpeechHint();
    }
    await _speech.listen(
      localeId: _sourceLocale,
      listenOptions: stt.SpeechListenOptions(
        partialResults: true,
        listenMode: stt.ListenMode.dictation,
        cancelOnError: false,
        onDevice: useOnDevice,
      ),
      onResult: (dynamic result) {
        final String words = result.recognizedWords.trim();
        if (words.isEmpty) return;
        _lastSpeechUpdatedAt = DateTime.now();
        _liveRecognized = words;
        setState(() {
          _sourceText = words;
        });
        if (result.finalResult) {
          _submitForTranslation(words);
        }
      },
    );
  }

  Future<void> _startOfflineAiListening() async {
    try {
      await _offlineAi.startListening(_sourceLocale);
      _offlineAiListening = true;
    } catch (e) {
      _offlineAiListening = false;
      _showSnackBar('離線語音啟動失敗：$e');
    }
  }

  Future<void> _restartListeningIfNeeded() async {
    if (!_isListening || _suppressListenRestart) return;
    await Future<void>.delayed(const Duration(milliseconds: 250));
    if (_isListening && !_speech.isListening) {
      await WakelockPlus.enable();
      await _listenNow();
    }
  }

  Future<void> _stopListening() async {
    _pauseTimer?.cancel();
    if (_offlineAiListening) {
      await _offlineAi.stopListening();
      _offlineAiListening = false;
    }
    await _speech.stop();
    await WakelockPlus.disable();
    setState(() {
      _isListening = false;
    });
  }

  void _startPauseWatcher() {
    _pauseTimer?.cancel();
    _pauseTimer = Timer.periodic(const Duration(milliseconds: 300), (_) {
      if (!_isListening || _liveRecognized.isEmpty || _lastSpeechUpdatedAt == null) {
        return;
      }
      final int diff = DateTime.now().difference(_lastSpeechUpdatedAt!).inMilliseconds;
      if (diff >= 1500 && _liveRecognized != _lastSubmitted) {
        _submitForTranslation(_liveRecognized);
      }
    });
  }

  Future<void> _submitForTranslation(String text) async {
    final String clean = text.trim();
    if (clean.isEmpty || clean == _lastSubmitted) return;
    _lastSubmitted = clean;
    try {
      final String translated = await _translateWithFallback(clean);
      if (!mounted) return;
      final DateTime ts = DateTime.now().toUtc();

      // 語音辨識在「同一句話」的過程可能會逐步補長（abc -> abcd -> abcdef）。
      // 若新句子是上一段的前綴延伸，就更新同一筆（主畫面/歷史都只顯示一次）。
      final bool isConversationMode = _displayMode == MainDisplayMode.conversation;
      TranscriptTurn? lastTurnBefore = isConversationMode && _transcript.isNotEmpty ? _transcript.last : null;
      bool shouldReplaceLast = false;
      String prevSource = '';
      String prevTranslation = '';

      if (isConversationMode) {
        if (lastTurnBefore != null &&
            lastTurnBefore.source.isNotEmpty &&
            (clean.startsWith(lastTurnBefore.source) || lastTurnBefore.source.startsWith(clean))) {
          shouldReplaceLast = true;
          prevSource = lastTurnBefore.source;
          prevTranslation = lastTurnBefore.translation;
        }
      } else {
        shouldReplaceLast = _lastCurrentPhraseSourceForHistory.isNotEmpty &&
            (_lastCurrentPhraseSourceForHistory != '' &&
                (clean.startsWith(_lastCurrentPhraseSourceForHistory) ||
                    _lastCurrentPhraseSourceForHistory.startsWith(clean)));
        prevSource = shouldReplaceLast ? _lastCurrentPhraseSourceForHistory : '';
        prevTranslation = shouldReplaceLast ? _lastCurrentPhraseTranslationForHistory : '';
      }

      setState(() {
        if (_displayMode == MainDisplayMode.conversation) {
          if (shouldReplaceLast) {
            _transcript[_transcript.length - 1] = TranscriptTurn(source: clean, translation: translated);
          } else {
            _transcript.add(TranscriptTurn(source: clean, translation: translated));
          }
          _sourceText = '等待語音輸入...';
          _translatedText = '';
        } else {
          _sourceText = clean;
          _translatedText = translated;
        }
      });

      if (_displayMode == MainDisplayMode.conversation) {
        _scrollTranscriptToEnd();
        final TranslationEntry updated = TranslationEntry(
          timestampIso: ts.toIso8601String(),
          locale: _sourceLocale,
          source: clean,
          translation: translated,
        );
        if (shouldReplaceLast) {
          await _upsertHistoryEntryForConversation(
            locale: _sourceLocale,
            prevSource: prevSource,
            prevTranslation: prevTranslation,
            updatedEntry: updated,
          );
        } else {
          await _appendHistory(updated);
        }
        // 避免切換回「目前一段」後誤判前綴延伸
        _lastCurrentPhraseSourceForHistory = '';
        _lastCurrentPhraseTranslationForHistory = '';
      } else {
        final TranslationEntry updated = TranslationEntry(
          timestampIso: ts.toIso8601String(),
          locale: _sourceLocale,
          source: clean,
          translation: translated,
        );
        if (shouldReplaceLast) {
          await _upsertHistoryEntryForConversation(
            locale: _sourceLocale,
            prevSource: prevSource,
            prevTranslation: prevTranslation,
            updatedEntry: updated,
          );
        } else {
          await _appendHistory(updated);
        }
        _lastCurrentPhraseSourceForHistory = clean;
        _lastCurrentPhraseTranslationForHistory = translated;
      }
      await _increaseDailyCount();
    } catch (e) {
      _showSnackBar('翻譯失敗: $e');
    }
  }

  Future<String> _translateWithFallback(String text) async {
    const List<int> retryDelayMs = <int>[600, 1200, 2400];
    bool attemptedPrimaryRecovery = false;
    if (_usingSecondary && _autoReturnPrimary && _canTryPrimaryRecovery()) {
      _usingSecondary = false;
      attemptedPrimaryRecovery = true;
      _buildChatSession(forceRecreate: true);
      _lastPrimaryRecoveryAttemptAt = DateTime.now();
    }
    for (int attempt = 0; attempt < retryDelayMs.length; attempt++) {
      try {
        _buildChatSession(forceRecreate: false);
        final String result = await _sendChat(text);
        if (attemptedPrimaryRecovery && mounted) {
          _showSnackBar('Primary 已恢復，已自動切回');
        }
        return result;
      } catch (e) {
        final bool isLastAttempt = attempt == retryDelayMs.length - 1;
        if (_is429Error(e) && !_usingSecondary && _secondaryKeyController.text.trim().isNotEmpty) {
          _usingSecondary = true;
          _buildChatSession(forceRecreate: true);
          if (mounted) {
            _showSnackBar('主要 Key 額度不足，已自動切換 Secondary Key');
          }
          continue;
        }
        if (isLastAttempt) {
          if (_isLikelyNetworkError(e)) {
            return _translateOffline(text);
          }
          rethrow;
        }
        await Future<void>.delayed(Duration(milliseconds: retryDelayMs[attempt]));
        _buildChatSession(forceRecreate: true);
      }
    }
    throw Exception('翻譯重試失敗');
  }

  bool _canTryPrimaryRecovery() {
    final DateTime? last = _lastPrimaryRecoveryAttemptAt;
    if (last == null) return true;
    return DateTime.now().difference(last).inSeconds >= 45;
  }

  Future<String> _translateOffline(String text) async {
    final AppLanguage src = _langById(_inputLangId);
    final AppLanguage tgt = _langById(_outputLangId);

    // iOS：走 Qwen-2.5-1.5B INT4（llama.cpp），Android 仍用 ML Kit。
    if (_offlineAi.isSupported) {
      if (!_offlineAiStatus.llmReady) {
        throw Exception(
          '離線翻譯尚未就緒：Qwen 模型未內建於 app bundle，請聯絡開發者重新打包（ios/Runner/OfflineAI/README.md）。',
        );
      }
      try {
        final String translated = await _offlineAi.translate(
          text: text,
          sourceTag: src.id,
          targetTag: tgt.id,
          locationHint: _approximateLocationLabel.isEmpty ? null : _approximateLocationLabel,
        );
        if (mounted) {
          _showSnackBar('網路異常，已切換離線翻譯（Qwen-1.5B）');
        }
        return translated.isEmpty ? '（離線翻譯無結果）' : translated;
      } catch (e) {
        throw Exception('Qwen 離線翻譯失敗：$e');
      }
    }

    try {
      await _ensureModelDownloaded(src.mlkit);
      await _ensureModelDownloaded(tgt.mlkit);
    } catch (e) {
      throw Exception(
        '離線翻譯需要 ${src.label}、${tgt.label} 的 ML Kit 模型（更多→離線語言包或設定內預下載）。$e',
      );
    }

    _offlineTranslator?.close();
    _offlineTranslator = OnDeviceTranslator(
      sourceLanguage: src.mlkit,
      targetLanguage: tgt.mlkit,
    );
    final String translated = await _offlineTranslator!.translateText(text);
    if (mounted) {
      _showSnackBar('網路異常，已切換離線翻譯模式');
    }
    return translated.trim().isEmpty ? '（離線翻譯無結果）' : translated.trim();
  }

  // === iOS Offline AI integration =========================================

  Future<void> _initOfflineAi() async {
    if (!_offlineAi.isSupported) return;
    try {
      final OfflineAIStatus s = await _offlineAi.initialize();
      if (!mounted) return;
      setState(() => _offlineAiStatus = s);
    } catch (_) {}

    // Whisper / Qwen 首次載入（Core ML 編譯、llama.cpp mmap）需數秒；於啟動階段就預熱,
    // 避免首次收音或翻譯延遲。原生端 prewarm 對已載入狀態是 no-op，可安全重複呼叫。
    unawaited(() async {
      try {
        await _offlineAi.prewarm();
        final OfflineAIStatus fresh = await _offlineAi.initialize();
        if (!mounted) return;
        setState(() => _offlineAiStatus = fresh);
      } catch (_) {
        // 模型未 bundle 或載入失敗：維持原狀態，UI 會顯示未就緒；
        // 進 offline 時會自動 fallback 到 speech_to_text onDevice 路徑並出現提示。
      }
    }());

    _offlineSttSub = _offlineAi.sttEvents.listen((OfflineSttEvent ev) {
      if (!mounted) return;
      switch (ev.type) {
        case OfflineSttEventType.partial:
          final String words = ev.text.trim();
          if (words.isEmpty) return;
          _lastSpeechUpdatedAt = DateTime.now();
          _liveRecognized = words;
          setState(() {
            _sourceText = words;
          });
          break;
        case OfflineSttEventType.finalResult:
          final String words = ev.text.trim();
          if (words.isNotEmpty) {
            _submitForTranslation(words);
          }
          break;
        case OfflineSttEventType.status:
          break;
        case OfflineSttEventType.error:
          _showSnackBar('離線語音辨識錯誤：${ev.text}');
          if (_isListening) {
            _offlineAiListening = false;
            unawaited(_listenNow());
          }
          break;
      }
    });

    _offlineLlmSub = _offlineAi.llmProgress.listen((OfflineLlmProgress p) {
      if (!mounted) return;
      setState(() {
        _offlineAiStatus = OfflineAIStatus(
          whisperReady: _offlineAiStatus.whisperReady,
          llmReady: p.state == OfflineLlmState.ready ? true : (p.state == OfflineLlmState.error ? false : _offlineAiStatus.llmReady),
          llmDownloading: p.state == OfflineLlmState.downloading,
          whisperModelName: _offlineAiStatus.whisperModelName,
          llmModelName: _offlineAiStatus.llmModelName,
          llmBytes: p.downloaded,
          llmBytesTotal: p.total,
        );
      });
      if (p.state == OfflineLlmState.error && p.message != null) {
        _showSnackBar('Qwen 下載/載入失敗：${p.message}');
      }
    });
  }

  Future<void> _openOfflineAiModelPage() async {
    if (!_offlineAi.isSupported) {
      _showSnackBar('此版本僅 iOS 支援離線 AI 模型（Whisper + Qwen）');
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => OfflineAiModelPage(
          service: _offlineAi,
          initialStatus: _offlineAiStatus,
        ),
      ),
    );
    if (!mounted) return;
    try {
      final OfflineAIStatus s = await _offlineAi.initialize();
      setState(() => _offlineAiStatus = s);
    } catch (_) {}
  }

  Future<void> _ensureModelDownloaded(TranslateLanguage language) async {
    final String code = language.bcpCode;
    final bool downloaded = await _modelManager.isModelDownloaded(code);
    if (!downloaded) {
      final bool success = await _modelManager.downloadModel(
        code,
        isWifiRequired: false,
      );
      if (!success) {
        throw Exception('無法下載離線翻譯模型（$code）。請確認網路與儲存空間，或稍後在離線語言包重試。');
      }
    }
  }

  Future<void> _checkOfflineTranslationModelsAfterBootstrap() async {
    if (!mounted) return;
    if (_offlineTranslationModelHintShown) return;
    final AppLanguage src = _langById(_inputLangId);
    final AppLanguage tgt = _langById(_outputLangId);
    final bool a = await _modelManager.isModelDownloaded(src.mlkit.bcpCode);
    final bool b = await _modelManager.isModelDownloaded(tgt.mlkit.bcpCode);
    if (!mounted) return;
    if (!a || !b) {
      _offlineTranslationModelHintShown = true;
      _showSnackBar(
        '離線翻譯尚未備齊：請下載「${src.label}」與「${tgt.label}」模型（更多→離線語言包，或點「預下載目前語言組合」）。',
      );
    }
  }

  Future<void> _checkOfflineTranslationModelsAfterPairChange() async {
    final AppLanguage src = _langById(_inputLangId);
    final AppLanguage tgt = _langById(_outputLangId);
    final bool a = await _modelManager.isModelDownloaded(src.mlkit.bcpCode);
    final bool b = await _modelManager.isModelDownloaded(tgt.mlkit.bcpCode);
    if (!mounted) return;
    if (!a || !b) {
      _showSnackBar(
        '離線翻譯尚未備齊：請下載「${src.label}」與「${tgt.label}」模型（更多→離線語言包或預下載）。',
      );
    }
  }

  Future<void> _preloadTranslationModelsForCurrentPair() async {
    final AppLanguage src = _langById(_inputLangId);
    final AppLanguage tgt = _langById(_outputLangId);
    if (!mounted) return;
    _showSnackBar('正在下載離線翻譯模型：${src.label}、${tgt.label}…');
    try {
      await _ensureModelDownloaded(src.mlkit);
      await _ensureModelDownloaded(tgt.mlkit);
      if (!mounted) return;
      _showSnackBar('離線翻譯模型已就緒（${src.label} ↔ ${tgt.label}）');
    } catch (e) {
      if (!mounted) return;
      _showSnackBar('離線翻譯模型下載失敗：$e');
    }
  }

  bool _speechHasLocale(String localeId, List<stt.LocaleName> locales) {
    final String want = localeId.toLowerCase().replaceAll('_', '-');
    for (final stt.LocaleName l in locales) {
      final String id = l.localeId.toLowerCase().replaceAll('_', '-');
      if (id == want) {
        return true;
      }
    }
    return false;
  }

  Future<void> _maybeShowOfflineSpeechHint() async {
    if (_offlineSttUxShown) {
      return;
    }
    try {
      final List<stt.LocaleName> locales = await _speech.locales();
      if (!mounted) {
        return;
      }
      _offlineSttUxShown = true;
      if (!_speechHasLocale(_sourceLocale, locales)) {
        _showSnackBar(
          '目前輸入語言（$_sourceLocale）可能不在系統語音辨識清單中，離線辨識可能無法使用。請到系統設定新增語言或語音，或將「線上/離線辨識」改為「開」以連網辨識。',
        );
      } else {
        _showSnackBar(
          '離線語音辨識依賴系統語音包：部分裝置僅特定語言可用。若無法辨識，請到系統設定下載語音資料或改用連網辨識。',
        );
      }
    } catch (_) {
      if (!mounted) {
        return;
      }
      _offlineSttUxShown = true;
      _showSnackBar(
        '離線語音辨識依賴系統語音包；若無法辨識請到系統設定下載語音或使用連網辨識。',
      );
    }
  }

  bool _isLikelyNetworkError(Object error) {
    final String msg = error.toString().toLowerCase();
    return msg.contains('socketexception') ||
        msg.contains('failed host lookup') ||
        msg.contains('network is unreachable') ||
        msg.contains('timed out') ||
        msg.contains('connection reset') ||
        msg.contains('clientexception') ||
        msg.contains('no address associated');
  }

  /// 強制 on-device 語音時無法靠重試恢復的錯誤（含 Android [error_language_not_supported]：字串為底線而非空白）。
  bool _isOnDeviceSpeechFatalError(String message) {
    final String msg = message.toLowerCase();
    if (msg.contains('error_language_not_supported') ||
        msg.contains('error_language_unavailable') ||
        msg.contains('error_language_not_support') ||
        msg.contains('language_not_supported') ||
        msg.contains('language_unavailable')) {
      return true;
    }
    return msg.contains('on-device') ||
        msg.contains('on device') ||
        msg.contains('requiresondevicerecognition') ||
        msg.contains('not available') ||
        msg.contains('not supported') ||
        msg.contains('not_supported') ||
        msg.contains('local recognition');
  }

  /// 靜音、環境雜音或辨識逾時時常見；不應打斷使用者。
  bool _isBenignSpeechRecognitionError(String message) {
    final String msg = message.toLowerCase();
    if (msg.contains('error_speech_timeout') ||
        msg.contains('error_no_match') ||
        msg.contains('speech_timeout') ||
        msg.contains('msg_no_match') ||
        msg.contains('no_match') ||
        msg.contains('no match') ||
        msg.contains('no speech') ||
        msg.contains('no-speech') ||
        msg.contains('nospeech') ||
        msg.contains('speech timeout') ||
        msg.contains('did not catch') ||
        msg.contains('didn\'t catch') ||
        msg.contains('nothing recognized') ||
        msg.contains('recognition_fail') ||
        msg.contains('recognition fail') ||
        msg.contains('audio timeout')) {
      return true;
    }
    // Android SpeechRecognizer：6 = speech timeout, 7 = no match（常出現在錯誤字串）
    if (msg.contains('error 6') ||
        msg.contains('error 7') ||
        msg.contains('error: 6') ||
        msg.contains('error: 7')) {
      return true;
    }
    return false;
  }

  bool _useOnDeviceForSpeech() {
    // iOS 為全離線作業，固定走 Whisper on-device 辨識。
    if (_offlineAi.isSupported) {
      return true;
    }
    switch (_speechMode) {
      case SpeechMode.online:
        return false;
      case SpeechMode.offline:
        return true;
      case SpeechMode.auto:
        return !_hasInternet;
    }
  }

  void _startNetworkWatcher() {
    _networkTimer?.cancel();
    _networkTimer = Timer.periodic(const Duration(seconds: 6), (_) {
      _refreshNetworkStatus();
    });
    _refreshNetworkStatus();
  }

  Future<void> _refreshNetworkStatus() async {
    final bool previous = _hasInternet;
    _hasInternet = await _detectInternetReachable();
    if (!mounted) return;
    if (previous != _hasInternet) {
      setState(() {});
    }
    if (_speechMode == SpeechMode.auto && _isListening) {
      final bool desired = _useOnDeviceForSpeech();
      if (desired != _lastOnDeviceApplied) {
        await _speech.stop();
        await _listenNow();
        _showSnackBar(
          desired ? '目前處於離線辨識模式，精準度可能下降' : '網路恢復，已切回連網辨識模式',
        );
      }
    }
  }

  Future<bool> _detectInternetReachable() async {
    if (kIsWeb) return true;
    try {
      final List<ConnectivityResult> results = await _connectivity.checkConnectivity();
      if (results.contains(ConnectivityResult.none)) {
        return false;
      }
      final List<InternetAddress> lookup =
          await InternetAddress.lookup('google.com').timeout(const Duration(seconds: 2));
      return lookup.isNotEmpty && lookup.first.rawAddress.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  Future<void> _promptOfflineModelDownload() async {
    final bool? shouldDownload = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('下載離線語言包'),
          content: const Text(
            '建議先下載日文與中文離線語言包。\n'
            '沒網路時仍可進行日文<->中文翻譯。',
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('稍後'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('立即下載'),
            ),
          ],
        );
      },
    );
    if (!mounted) return;
    await _prefs?.setBool(kOfflinePromptShownPref, true);
    _offlinePromptShown = true;
    if (shouldDownload != true) return;
    try {
      _showSnackBar('開始下載離線語言包...');
      await _ensureModelDownloaded(TranslateLanguage.japanese);
      await _ensureModelDownloaded(TranslateLanguage.chinese);
      _showSnackBar('離線語言包下載完成');
    } catch (e) {
      _showSnackBar('下載失敗: $e');
    }
    if (mounted) {
      unawaited(_checkOfflineTranslationModelsAfterBootstrap());
    }
  }

  Future<void> _openOfflinePackManager() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => OfflinePackManagerPage(
          modelManager: _modelManager,
          currentPairSummary:
              '${_langById(_inputLangId).label} → ${_langById(_outputLangId).label}',
          onPreloadCurrentPair: _preloadTranslationModelsForCurrentPair,
        ),
      ),
    );
  }

  Future<String> _sendChat(String text) async {
    ChatSession? session = _chatSession;
    if (session == null) {
      final String apiKey = _usingSecondary
          ? _secondaryKeyController.text.trim()
          : _primaryKeyController.text.trim();
      if (apiKey.isEmpty) {
        throw Exception('請先設定 API Key');
      }
      if (_effectiveSelectedModel == null) {
        throw Exception('目前所選模型在 API 清單中不可用，請到設定改選其他模型');
      }
      _buildChatSession(forceRecreate: true);
      session = _chatSession;
      if (session == null) {
        throw Exception('無法建立翻譯連線，請稍後再試');
      }
    }
    final GenerateContentResponse response = await session.sendMessage(Content.text(text));
    return response.text?.trim().isNotEmpty == true ? response.text!.trim() : '（無可用翻譯結果）';
  }

  void _buildChatSession({required bool forceRecreate}) {
    if (!forceRecreate && _chatSession != null) return;
    final String apiKey = _usingSecondary
        ? _secondaryKeyController.text.trim()
        : _primaryKeyController.text.trim();
    if (apiKey.isEmpty) {
      _chatSession = null;
      return;
    }
    final String? model = _effectiveSelectedModel;
    if (model == null) {
      _chatSession = null;
      return;
    }
    final GenerativeModel genModel = GenerativeModel(
      model: model,
      apiKey: apiKey,
      systemInstruction: Content.system(_currentSystemPrompt()),
    );
    _chatSession = genModel.startChat();
  }

  String _currentSystemPrompt() {
    final AppLanguage src = _langById(_inputLangId);
    final AppLanguage tgt = _langById(_outputLangId);
    final StringBuffer buf = StringBuffer()
      ..writeln('你是一位專業旅遊口譯。請將使用者內容從「${src.label}」翻譯成「${tgt.label}」。')
      ..writeln('若目標為繁體中文，請使用台灣慣用語。')
      ..writeln('針對地名、景點與人名（如石垣島、西表島、川平灣、八重山）要精準翻譯。');
    if (_locationOptimize && _approximateLocationLabel.isNotEmpty) {
      buf.writeln(
        '使用者目前約略位置：$_approximateLocationLabel。'
        '請優先採用此區域常見的行政區、地名、景點、交通與設施的慣用譯法與台灣遊客常用稱呼；'
        '若內容與該區無關，仍依一般旅遊口譯品質處理。',
      );
    }
    buf.writeln('輸出只要翻譯結果，避免多餘說明。');
    return buf.toString().trim();
  }

  bool _is429Error(Object error) {
    final String msg = error.toString().toLowerCase();
    return msg.contains('429') || msg.contains('resource_exhausted');
  }

  Future<void> _increaseDailyCount() async {
    await _maybeResetDailyCounter();
    final int current = _prefs?.getInt(kDailyCountPref) ?? 0;
    final int next = current + 1;
    await _prefs?.setInt(kDailyCountPref, next);
    if (mounted) {
      setState(() {
        _dailyCount = next;
      });
    }
  }

  Future<void> _maybeResetDailyCounter() async {
    final SharedPreferences? prefs = _prefs;
    if (prefs == null) return;
    final DateTime nowUtc = DateTime.now().toUtc();
    final DateTime marker = _latestResetMarker(nowUtc);
    final int currentMarker = prefs.getInt(kLastResetMarkerPref) ?? 0;
    if (currentMarker != marker.millisecondsSinceEpoch) {
      await prefs.setInt(kDailyCountPref, 0);
      await prefs.setInt(kLastResetMarkerPref, marker.millisecondsSinceEpoch);
    }
  }

  DateTime _latestResetMarker(DateTime nowUtc) {
    final DateTime today0700Utc = DateTime.utc(nowUtc.year, nowUtc.month, nowUtc.day, 7);
    if (nowUtc.isBefore(today0700Utc)) {
      return today0700Utc.subtract(const Duration(days: 1));
    }
    return today0700Utc;
  }

  Future<void> _saveSettings() async {
    final String primary = _primaryKeyController.text.trim();
    final String secondary = _secondaryKeyController.text.trim();
    if (primary.isEmpty) {
      _showSnackBar('Primary Key 不能為空');
      return;
    }
    await _prefs?.setString(kPrimaryKeyPref, primary);
    await _prefs?.setString(kSecondaryKeyPref, secondary);
    await _prefs?.setString(kSelectedModelPref, _selectedModel);
    await _prefs?.setBool(kAutoReturnPrimaryPref, _autoReturnPrimary);
    await _prefs?.setString(kSpeechModePref, _speechModeToStorage(_speechMode));
    await _prefs?.setString(kInputLangIdPref, _inputLangId);
    await _prefs?.setString(kOutputLangIdPref, _outputLangId);
    await _prefs?.setBool(kLocationOptimizePref, _locationOptimize);
    await _prefs?.setString(kTranslationFontSizePref, _translationFontSizeToStorage(_translationFontSize));
    await _prefs?.setString(kMainDisplayModePref, _mainDisplayModeToStorage(_displayMode));
    unawaited(_refreshModelList());
    _usingSecondary = false;
    _buildChatSession(forceRecreate: true);
    if (!mounted) return;
    Navigator.of(context).pop();
    setState(() {
      _isSettingsOpen = false;
    });
    _showSnackBar('設定已儲存');
  }

  void _loadHistoryFromLocal() {
    final String raw = _prefs?.getString(kHistoryPref) ?? '';
    if (raw.isEmpty) {
      _history = <TranslationEntry>[];
      return;
    }
    try {
      final List<dynamic> decoded = jsonDecode(raw) as List<dynamic>;
      _history = decoded
          .whereType<Map<String, dynamic>>()
          .map(TranslationEntry.fromJson)
          .where((TranslationEntry e) => e.source.isNotEmpty || e.translation.isNotEmpty)
          .toList();
    } catch (_) {
      _history = <TranslationEntry>[];
    }
  }

  Future<void> _appendHistory(TranslationEntry entry) async {
    _history.insert(0, entry);
    if (kHistoryMaxItems > 0 && _history.length > kHistoryMaxItems) {
      _history = _history.take(kHistoryMaxItems).toList();
    }
    final String encoded = jsonEncode(_history.map((TranslationEntry e) => e.toJson()).toList());
    await _prefs?.setString(kHistoryPref, encoded);
  }

  /// 累積對話模式下，避免同一句話被逐步補長時產生重複的歷史紀錄。
  /// 若找到上一版本（prevSource/prevTranslation）的紀錄，就移除後把 updatedEntry 插回最前面。
  Future<void> _upsertHistoryEntryForConversation({
    required String locale,
    required String prevSource,
    required String prevTranslation,
    required TranslationEntry updatedEntry,
  }) async {
    if (prevSource.isEmpty) {
      await _appendHistory(updatedEntry);
      return;
    }
    final int idx = _history.indexWhere(
      (TranslationEntry e) => e.locale == locale && e.source == prevSource && e.translation == prevTranslation,
    );
    if (idx != -1) {
      _history.removeAt(idx);
    }
    _history.insert(0, updatedEntry);
    final String encoded = jsonEncode(_history.map((TranslationEntry e) => e.toJson()).toList());
    await _prefs?.setString(kHistoryPref, encoded);
  }

  Future<void> _exportHistoryAsTxt() async {
    if (_isExporting) return;
    if (_history.isEmpty) {
      _showSnackBar('目前沒有可匯出的翻譯紀錄');
      return;
    }
    setState(() {
      _isExporting = true;
    });
    try {
      await _exportEntriesAsTxt(_history);
    } catch (e) {
      _showSnackBar('匯出失敗: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isExporting = false;
        });
      }
    }
  }

  Future<void> _exportEntriesAsTxt(List<TranslationEntry> entries) async {
    if (entries.isEmpty) {
      _showSnackBar('目前沒有可匯出的翻譯紀錄');
      return;
    }
    try {
      final Directory dir = await getTemporaryDirectory();
      final String now = DateTime.now().toIso8601String().replaceAll(':', '-');
      final String filePath = '${dir.path}/travel_translation_$now.txt';
      final StringBuffer sb = StringBuffer()
        ..writeln('旅程翻譯紀錄')
        ..writeln('匯出時間: ${DateTime.now()}')
        ..writeln('共 ${entries.length} 筆')
        ..writeln('----------------------------------------');
      for (final TranslationEntry e in entries) {
        sb.writeln('[${e.timestampIso}] (${e.locale})');
        sb.writeln('原文: ${e.source}');
        sb.writeln('翻譯: ${e.translation}');
        sb.writeln('');
      }
      final File file = File(filePath);
      await file.writeAsString(sb.toString(), flush: true);
      await SharePlus.instance.share(
        ShareParams(
          text: '日本旅遊導覽翻譯紀錄',
          files: <XFile>[XFile(file.path)],
        ),
      );
    } catch (e) {
      rethrow;
    }
  }

  Future<void> _removeHistoryAt(int index) async {
    if (index < 0 || index >= _history.length) return;
    setState(() {
      _history.removeAt(index);
    });
    final String encoded = jsonEncode(_history.map((TranslationEntry e) => e.toJson()).toList());
    await _prefs?.setString(kHistoryPref, encoded);
  }

  Future<void> _clearAllHistory() async {
    setState(() {
      _history = <TranslationEntry>[];
    });
    await _prefs?.setString(kHistoryPref, '[]');
    _showSnackBar('已清空所有翻譯紀錄');
  }

  Future<void> _clearTodayHistory() async {
    final DateTime now = DateTime.now();
    bool removedAny = false;
    final List<TranslationEntry> next = _history.where((TranslationEntry e) {
      final DateTime? d = DateTime.tryParse(e.timestampIso)?.toLocal();
      if (d == null) {
        return true;
      }
      final bool isToday = d.year == now.year && d.month == now.month && d.day == now.day;
      if (isToday) {
        removedAny = true;
      }
      return !isToday;
    }).toList();
    if (!removedAny) {
      _showSnackBar('今天沒有可清除的翻譯紀錄');
      return;
    }
    setState(() {
      _history = next;
    });
    final String encoded = jsonEncode(_history.map((TranslationEntry e) => e.toJson()).toList());
    await _prefs?.setString(kHistoryPref, encoded);
    _showSnackBar('已清空今天翻譯紀錄');
  }

  Future<void> _persistLanguagePrefs() async {
    await _prefs?.setString(kInputLangIdPref, _inputLangId);
    await _prefs?.setString(kOutputLangIdPref, _outputLangId);
  }

  void _swapLanguages() {
    setState(() {
      final String t = _inputLangId;
      _inputLangId = _outputLangId;
      _outputLangId = t;
      _offlineSttUxShown = false;
    });
    _persistLanguagePrefs();
    _usingSecondary = false;
    _buildChatSession(forceRecreate: true);
    unawaited(_checkOfflineTranslationModelsAfterPairChange());
    if (_isListening) {
      unawaited(_restartListenAfterLangChange());
    }
  }

  Future<void> _restartListenAfterLangChange() async {
    await _speech.stop();
    await _listenNow();
  }

  Future<void> _openLanguagePicker({required bool isInput}) async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (BuildContext context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Padding(
                padding: EdgeInsets.all(12),
                child: Text(
                  '選擇語言',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
              ),
              ...kAppLanguages.map((AppLanguage lang) {
                final bool selected = isInput ? _inputLangId == lang.id : _outputLangId == lang.id;
                return ListTile(
                  title: Text(lang.label),
                  trailing: selected ? const Icon(Icons.check, color: Colors.lightGreenAccent) : null,
                  onTap: () async {
                    Navigator.of(context).pop();
                    setState(() {
                      if (isInput) {
                        final String oldIn = _inputLangId;
                        if (lang.id == _outputLangId) {
                          _outputLangId = oldIn;
                        }
                        _inputLangId = lang.id;
                        _offlineSttUxShown = false;
                      } else {
                        final String oldOut = _outputLangId;
                        if (lang.id == _inputLangId) {
                          _inputLangId = oldOut;
                          _offlineSttUxShown = false;
                        }
                        _outputLangId = lang.id;
                      }
                    });
                    await _persistLanguagePrefs();
                    _usingSecondary = false;
                    _buildChatSession(forceRecreate: true);
                    unawaited(_checkOfflineTranslationModelsAfterPairChange());
                    if (_isListening) {
                      await _restartListenAfterLangChange();
                    }
                  },
                );
              }),
            ],
          ),
        );
      },
    );
  }

  Future<void> _openHistoryPage() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => TranslationHistoryPage(
          initialHistory: List<TranslationEntry>.from(_history),
          onDeleteAt: (int index) => _removeHistoryAt(index),
          onClearAll: _clearAllHistory,
          onClearToday: _clearTodayHistory,
          onExportEntries: _exportEntriesAsTxt,
        ),
      ),
    );
  }

  Future<void> _openSettings({bool forceRequired = false}) async {
    if (_isSettingsOpen) return;
    if (!mounted) {
      return;
    }
    _isSettingsOpen = true;
    await showDialog<void>(
      context: context,
      barrierDismissible: !forceRequired,
      builder: (BuildContext context) {
        bool locationDraft = _locationOptimize;
        AppTranslationFontSize translationFontDraft = _translationFontSize;
        MainDisplayMode displayModeDraft = _displayMode;
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setDialogState) {
            return AlertDialog(
              title: const Text('設定'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    const Text('翻譯字級', style: TextStyle(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 4),
                    const Text(
                      '「大」為改版前預設；新安裝預設為「中」。',
                      style: TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                    const SizedBox(height: 8),
                    SegmentedButton<AppTranslationFontSize>(
                      segments: const <ButtonSegment<AppTranslationFontSize>>[
                        ButtonSegment<AppTranslationFontSize>(
                          value: AppTranslationFontSize.small,
                          label: Text('小'),
                        ),
                        ButtonSegment<AppTranslationFontSize>(
                          value: AppTranslationFontSize.medium,
                          label: Text('中'),
                        ),
                        ButtonSegment<AppTranslationFontSize>(
                          value: AppTranslationFontSize.large,
                          label: Text('大'),
                        ),
                      ],
                      selected: <AppTranslationFontSize>{translationFontDraft},
                      onSelectionChanged: (Set<AppTranslationFontSize> values) {
                        setDialogState(() {
                          translationFontDraft = values.first;
                        });
                      },
                    ),
                    const SizedBox(height: 16),
                    const Text('主畫面顯示', style: TextStyle(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 4),
                    const Text(
                      '「累積對話」會在本畫面保留多句；歷史紀錄仍照常儲存。',
                      style: TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                    const SizedBox(height: 8),
                    SegmentedButton<MainDisplayMode>(
                      segments: const <ButtonSegment<MainDisplayMode>>[
                        ButtonSegment<MainDisplayMode>(
                          value: MainDisplayMode.currentPhrase,
                          label: Text('目前一段'),
                        ),
                        ButtonSegment<MainDisplayMode>(
                          value: MainDisplayMode.conversation,
                          label: Text('累積對話'),
                        ),
                      ],
                      selected: <MainDisplayMode>{displayModeDraft},
                      onSelectionChanged: (Set<MainDisplayMode> values) {
                        setDialogState(() {
                          displayModeDraft = values.first;
                        });
                      },
                    ),
                    const SizedBox(height: 16),
                    FilledButton.tonalIcon(
                      onPressed: () {
                        unawaited(_preloadTranslationModelsForCurrentPair());
                      },
                      icon: const Icon(Icons.download_for_offline_outlined, size: 20),
                      label: const Text('預下載目前輸入／輸出語言（離線翻譯）'),
                    ),
                    const SizedBox(height: 12),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('依約略位置優化翻譯'),
                      subtitle: const Text(
                        '使用粗定位與逆地理（縣市／行政區），用於地名與景點譯法；不儲存精確座標。',
                        style: TextStyle(fontSize: 12),
                      ),
                      value: locationDraft,
                      onChanged: (bool value) {
                        setDialogState(() {
                          locationDraft = value;
                        });
                      },
                    ),
                    const SizedBox(height: 20),
                    const Divider(),
                    const SizedBox(height: 8),
                    Text(
                      '歷史筆數：${_history.length}',
                      style: const TextStyle(fontSize: 13, color: Colors.grey),
                    ),
                  ],
                ),
              ),
              actions: <Widget>[
                if (!forceRequired)
                  TextButton(
                    onPressed: () {
                      Navigator.of(context).pop();
                    },
                    child: const Text('取消'),
                  ),
                FilledButton(
                  onPressed: () {
                    setState(() {
                      _locationOptimize = locationDraft;
                      _translationFontSize = translationFontDraft;
                      _displayMode = displayModeDraft;
                      if (!locationDraft) {
                        _approximateLocationLabel = '';
                      }
                    });
                    if (locationDraft) {
                      unawaited(_refreshApproximateLocation(force: true));
                    }
                    _saveSettings();
                  },
                  child: const Text('儲存'),
                ),
              ],
            );
          },
        );
      },
    );
    if (mounted) {
      setState(() {
        _isSettingsOpen = false;
      });
    }
  }

  void _showSnackBar(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final Color cardColor = const Color(0xFF1A1A1A);
    final _MainUiTokens ui = _MainUiTokens.from(
      context,
      translationFontSize: _translationFontSize,
    );
    final AppLanguage inLang = _langById(_inputLangId);
    final AppLanguage outLang = _langById(_outputLangId);
    final String sourceLabel = '原文（${inLang.label}）';
    final String targetLabel = '譯文（${outLang.label}）';
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          '旅遊導覽翻譯',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: <Widget>[
          IconButton(
            onPressed: _openHistoryPage,
            icon: const Icon(Icons.history),
            tooltip: '歷史紀錄',
          ),
          IconButton(
            onPressed: () => _openSettings(),
            icon: const Icon(Icons.settings),
            tooltip: '設定',
          ),
          PopupMenuButton<String>(
            tooltip: '更多',
            onSelected: (String value) {
              switch (value) {
                case 'export':
                  if (!_isExporting) _exportHistoryAsTxt();
                  break;
                case 'offline':
                  _openOfflinePackManager();
                  break;
                case 'offline_ai':
                  _openOfflineAiModelPage();
                  break;
              }
            },
            itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
              PopupMenuItem<String>(
                value: 'export',
                enabled: !_isExporting,
                child: ListTile(
                  leading: _isExporting
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.ios_share),
                  title: const Text('匯出紀錄'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              const PopupMenuItem<String>(
                value: 'offline',
                child: ListTile(
                  leading: Icon(Icons.download_for_offline),
                  title: Text('離線語言包'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              if (_offlineAi.isSupported)
                const PopupMenuItem<String>(
                  value: 'offline_ai',
                  child: ListTile(
                    leading: Icon(Icons.memory),
                    title: Text('離線 AI 模型'),
                    subtitle: Text('Whisper + Qwen (iOS)'),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
            ],
          ),
        ],
      ),
      backgroundColor: const Color(0xFF101010),
      body: !_isInitialized
          ? const Center(child: CircularProgressIndicator())
          : MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: MediaQuery.textScalerOf(context).clamp(
                  minScaleFactor: 0.88,
                  maxScaleFactor: 1.12,
                ),
              ),
              child: SafeArea(
                minimum: EdgeInsets.only(bottom: ui.compact ? 2 : 6),
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                    ui.edgePadding,
                    ui.compact ? 2 : 4,
                    ui.edgePadding,
                    ui.compact ? 4 : 6,
                  ),
                  child: Column(
                    children: <Widget>[
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: <Widget>[
                          Flexible(
                            child: OutlinedButton(
                              style: OutlinedButton.styleFrom(
                                padding: EdgeInsets.symmetric(
                                  horizontal: ui.compact ? 6 : 10,
                                  vertical: ui.compact ? 8 : 10,
                                ),
                              ),
                              onPressed:
                                  _isListening ? null : () => _openLanguagePicker(isInput: true),
                              child: Text(
                                '輸入: ${inLang.label}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(fontSize: ui.metaFont + 0.5),
                              ),
                            ),
                          ),
                          IconButton(
                            visualDensity:
                                ui.compact ? VisualDensity.compact : VisualDensity.standard,
                            constraints: BoxConstraints(
                              minWidth: ui.compact ? 40 : 48,
                              minHeight: ui.compact ? 40 : 48,
                            ),
                            onPressed: _isListening ? null : _swapLanguages,
                            tooltip: '對調輸入與輸出',
                            icon: Icon(Icons.swap_horiz, size: ui.compact ? 22 : 26),
                          ),
                          Flexible(
                            child: OutlinedButton(
                              style: OutlinedButton.styleFrom(
                                padding: EdgeInsets.symmetric(
                                  horizontal: ui.compact ? 6 : 10,
                                  vertical: ui.compact ? 8 : 10,
                                ),
                              ),
                              onPressed:
                                  _isListening ? null : () => _openLanguagePicker(isInput: false),
                              child: Text(
                                '輸出: ${outLang.label}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(fontSize: ui.metaFont + 0.5),
                              ),
                            ),
                          ),
                          SizedBox(width: ui.compact ? 4 : 8),
                          IconButton(
                            visualDensity:
                                ui.compact ? VisualDensity.compact : VisualDensity.standard,
                            constraints: BoxConstraints(
                              minWidth: ui.compact ? 36 : 42,
                              minHeight: ui.compact ? 36 : 42,
                            ),
                            onPressed: _clearMainDisplay,
                            tooltip: '清除對話',
                            icon: const Icon(Icons.delete_sweep_outlined),
                          ),
                        ],
                      ),
                      SizedBox(height: ui.compact ? 4 : 8),
                      Expanded(
                        child: Container(
                          width: double.infinity,
                          padding: EdgeInsets.all(ui.cardPadding),
                          decoration: BoxDecoration(
                            color: cardColor,
                            borderRadius: BorderRadius.circular(ui.compact ? 12 : 16),
                          ),
                          child: _displayMode == MainDisplayMode.currentPhrase
                              ? _buildCurrentPhraseCardContent(ui, sourceLabel, targetLabel)
                              : _buildConversationCardContent(ui, sourceLabel, targetLabel),
                        ),
                      ),
                      SizedBox(height: ui.compact ? 10 : 14),
                      SizedBox(
                        width: double.infinity,
                        height: ui.bigButtonHeight,
                        child: FilledButton.icon(
                          style: FilledButton.styleFrom(
                            padding: EdgeInsets.symmetric(horizontal: ui.compact ? 8 : 16),
                          ),
                          onPressed: () {
                            if (_isListening) {
                              _stopListening();
                            } else {
                              _startListening();
                            }
                          },
                          icon: Icon(_isListening ? Icons.stop : Icons.mic, size: ui.bigIconSize),
                          label: Text(
                            _isListening ? '停止' : '開始',
                            style: TextStyle(fontSize: ui.bigButtonFont, fontWeight: FontWeight.bold),
                          ),
                        ),
                      ),
                      SizedBox(height: ui.compact ? 6 : 10),
                      Text(
                        '今日已用 $_dailyCount/$kDailyQuotaLimit · '
                        '${_usingSecondary ? 'Secondary' : 'Primary'} · '
                        '${_labelForModelSlot(_isKnownModelSlot(_selectedModel) ? _selectedModel : kDefaultModelSlot)}',
                        style: TextStyle(fontSize: ui.footerFont, color: Colors.grey),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              ),
            ),
    );
  }
}

class OfflinePackManagerPage extends StatefulWidget {
  const OfflinePackManagerPage({
    super.key,
    required this.modelManager,
    this.currentPairSummary,
    this.onPreloadCurrentPair,
  });

  final OnDeviceTranslatorModelManager modelManager;
  final String? currentPairSummary;
  final Future<void> Function()? onPreloadCurrentPair;

  @override
  State<OfflinePackManagerPage> createState() => _OfflinePackManagerPageState();
}

class _OfflinePackManagerPageState extends State<OfflinePackManagerPage> {
  late final List<Map<String, dynamic>> _packs;
  bool _pairPreloading = false;

  @override
  void initState() {
    super.initState();
    _packs = kAppLanguages
        .map(
          (AppLanguage l) => <String, dynamic>{
            'label': '${l.label} (${l.localeId})',
            'code': l.mlkit.bcpCode,
            'downloaded': false,
            'working': false,
          },
        )
        .toList();
    _refreshStatus();
  }

  Future<void> _refreshStatus() async {
    for (final Map<String, dynamic> item in _packs) {
      final bool downloaded = await widget.modelManager.isModelDownloaded(item['code'] as String);
      item['downloaded'] = downloaded;
    }
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _downloadAt(int index) async {
    setState(() {
      _packs[index]['working'] = true;
    });
    try {
      final bool ok = await widget.modelManager.downloadModel(
        _packs[index]['code'] as String,
        isWifiRequired: false,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ok ? '下載完成' : '下載失敗')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('下載失敗: $e')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _packs[index]['working'] = false;
        });
      }
      await _refreshStatus();
    }
  }

  Future<void> _deleteAt(int index) async {
    setState(() {
      _packs[index]['working'] = true;
    });
    try {
      final bool ok = await widget.modelManager.deleteModel(_packs[index]['code'] as String);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ok ? '已刪除語言包' : '刪除失敗')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('刪除失敗: $e')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _packs[index]['working'] = false;
        });
      }
      await _refreshStatus();
    }
  }

  Future<void> _downloadCurrentPair() async {
    if (widget.onPreloadCurrentPair == null) {
      return;
    }
    setState(() {
      _pairPreloading = true;
    });
    try {
      await widget.onPreloadCurrentPair!();
    } finally {
      if (mounted) {
        setState(() {
          _pairPreloading = false;
        });
      }
      await _refreshStatus();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('離線語言包管理'),
        actions: <Widget>[
          IconButton(
            onPressed: _refreshStatus,
            icon: const Icon(Icons.refresh),
            tooltip: '重新整理',
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (widget.onPreloadCurrentPair != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      const Text('目前翻譯方向', style: TextStyle(fontWeight: FontWeight.w600)),
                      if (widget.currentPairSummary != null) ...<Widget>[
                        const SizedBox(height: 4),
                        Text(
                          widget.currentPairSummary!,
                          style: TextStyle(color: Colors.grey.shade400),
                        ),
                      ],
                      const SizedBox(height: 10),
                      FilledButton.icon(
                        onPressed: _pairPreloading ? null : _downloadCurrentPair,
                        icon: _pairPreloading
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.download),
                        label: const Text('預下載目前語言組合'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          Expanded(
            child: ListView.separated(
        itemCount: _packs.length,
        separatorBuilder: (BuildContext context, int index) => const Divider(height: 1),
        itemBuilder: (BuildContext context, int i) {
          final String label = _packs[i]['label'] as String;
          final bool downloaded = _packs[i]['downloaded'] as bool;
          final bool working = _packs[i]['working'] as bool;
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: <Widget>[
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(label, style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 4),
                      Text(
                        downloaded ? '狀態：已下載' : '狀態：未下載',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.grey),
                      ),
                    ],
                  ),
                ),
                if (working)
                  const SizedBox(
                    width: 28,
                    height: 28,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else if (downloaded)
                  TextButton.icon(
                    onPressed: () => _deleteAt(i),
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('刪除'),
                  )
                else
                  FilledButton.icon(
                    onPressed: () => _downloadAt(i),
                    icon: const Icon(Icons.download),
                    label: const Text('下載'),
                  ),
              ],
            ),
          );
        },
            ),
          ),
        ],
      ),
    );
  }
}

class TranslationHistoryPage extends StatefulWidget {
  const TranslationHistoryPage({
    super.key,
    required this.initialHistory,
    required this.onDeleteAt,
    required this.onClearAll,
    required this.onClearToday,
    required this.onExportEntries,
  });

  final List<TranslationEntry> initialHistory;
  final Future<void> Function(int index) onDeleteAt;
  final Future<void> Function() onClearAll;
  final Future<void> Function() onClearToday;
  final Future<void> Function(List<TranslationEntry> entries) onExportEntries;

  @override
  State<TranslationHistoryPage> createState() => _TranslationHistoryPageState();
}

class _TranslationHistoryPageState extends State<TranslationHistoryPage> {
  String _query = '';
  late List<TranslationEntry> _history;
  bool _isExporting = false;

  List<MapEntry<int, TranslationEntry>> _filteredEntries() {
    final List<MapEntry<int, TranslationEntry>> indexed = _history.asMap().entries.toList();
    return indexed.where((MapEntry<int, TranslationEntry> e) {
      if (_query.trim().isEmpty) return true;
      final String q = _query.toLowerCase();
      return e.value.source.toLowerCase().contains(q) ||
          e.value.translation.toLowerCase().contains(q) ||
          e.value.locale.toLowerCase().contains(q);
    }).toList();
  }

  Future<void> _showExportChooser() async {
    if (_isExporting) return;
    final List<MapEntry<int, TranslationEntry>> filtered = _filteredEntries();
    if (_history.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('目前沒有可匯出的翻譯紀錄')),
      );
      return;
    }
    final String? choice = await showModalBottomSheet<String>(
      context: context,
      builder: (BuildContext context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ListTile(
              leading: const Icon(Icons.all_inclusive),
              title: Text('匯出全部 (${_history.length} 筆)'),
              onTap: () => Navigator.of(context).pop('all'),
            ),
            ListTile(
              leading: const Icon(Icons.filter_list),
              title: Text('只匯出搜尋結果 (${filtered.length} 筆)'),
              onTap: () => Navigator.of(context).pop('filtered'),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    if (choice == null) return;
    final List<TranslationEntry> toExport = choice == 'filtered'
        ? filtered.map((MapEntry<int, TranslationEntry> e) => e.value).toList()
        : List<TranslationEntry>.from(_history);
    if (toExport.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('搜尋結果為空，沒有可匯出的資料')),
      );
      return;
    }
    setState(() {
      _isExporting = true;
    });
    try {
      await widget.onExportEntries(toExport);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('匯出失敗: $e')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isExporting = false;
        });
      }
    }
  }

  @override
  void initState() {
    super.initState();
    _history = widget.initialHistory;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('翻譯歷史紀錄'),
        actions: <Widget>[
          IconButton(
            onPressed: _isExporting ? null : _showExportChooser,
            icon: _isExporting
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.ios_share),
            tooltip: '匯出',
          ),
          IconButton(
            onPressed: _history.isEmpty
                ? null
                : () async {
                    final DateTime now = DateTime.now();
                    final bool hasToday = _history.any((TranslationEntry e) {
                      final DateTime? d = DateTime.tryParse(e.timestampIso)?.toLocal();
                      return d != null && d.year == now.year && d.month == now.month && d.day == now.day;
                    });
                    if (!hasToday) return;
                    await widget.onClearToday();
                    if (!mounted) return;
                    setState(() {
                      _history = _history.where((TranslationEntry e) {
                        final DateTime? d = DateTime.tryParse(e.timestampIso)?.toLocal();
                        final bool isToday = d != null && d.year == now.year && d.month == now.month && d.day == now.day;
                        return !isToday;
                      }).toList();
                    });
                  },
            icon: const Icon(Icons.delete_sweep_outlined),
            tooltip: '清除今天',
          ),
          IconButton(
            onPressed: _history.isEmpty
                ? null
                : () async {
                    await widget.onClearAll();
                    if (!mounted) return;
                    setState(() {
                      _history = <TranslationEntry>[];
                    });
                  },
            icon: const Icon(Icons.delete_sweep),
            tooltip: '清空全部',
          ),
        ],
      ),
      body: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              onChanged: (String value) {
                setState(() {
                  _query = value;
                });
              },
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: '搜尋原文 / 翻譯 / 語言',
                border: OutlineInputBorder(),
              ),
            ),
          ),
          Expanded(
            child: (() {
              final List<MapEntry<int, TranslationEntry>> filtered = _filteredEntries();
              final Map<String, List<MapEntry<int, TranslationEntry>>> grouped =
                  <String, List<MapEntry<int, TranslationEntry>>>{};

              for (final MapEntry<int, TranslationEntry> entry in filtered) {
                final DateTime parsed =
                    DateTime.tryParse(entry.value.timestampIso)?.toLocal() ?? DateTime.now();
                final String key =
                    '${parsed.year.toString().padLeft(4, '0')}-${parsed.month.toString().padLeft(2, '0')}-${parsed.day.toString().padLeft(2, '0')}';
                grouped.putIfAbsent(key, () => <MapEntry<int, TranslationEntry>>[]).add(entry);
              }

              final List<String> dateKeys = grouped.keys.toList()..sort((String a, String b) => b.compareTo(a));
              if (dateKeys.isEmpty) {
                return const Center(child: Text('沒有符合的紀錄'));
              }

              final List<Object> rows = <Object>[];
              for (final String dateKey in dateKeys) {
                rows.add(dateKey);
                rows.addAll(grouped[dateKey] ?? <MapEntry<int, TranslationEntry>>[]);
              }

              return ListView.builder(
                itemCount: rows.length,
                itemBuilder: (BuildContext context, int i) {
                  final Object row = rows[i];
                  if (row is String) {
                    return Container(
                      width: double.infinity,
                      color: Colors.white10,
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      child: Text(
                        row,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    );
                  }

                  final MapEntry<int, TranslationEntry> mapped =
                      row as MapEntry<int, TranslationEntry>;
                  final int realIndex = mapped.key;
                  final TranslationEntry item = mapped.value;

                  return Column(
                    children: <Widget>[
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  Text(
                                    item.translation,
                                    maxLines: 3,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontWeight: FontWeight.w700),
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    '原文（${item.locale}）：${item.source}',
                                    style: const TextStyle(color: Colors.grey, height: 1.25),
                                    maxLines: 3,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    item.timestampIso,
                                    style: const TextStyle(color: Colors.grey, fontSize: 12),
                                  ),
                                ],
                              ),
                            ),
                            IconButton(
                              icon: const Icon(Icons.delete_outline),
                              onPressed: () async {
                                await widget.onDeleteAt(realIndex);
                                if (!mounted) return;
                                setState(() {
                                  _history.removeAt(realIndex);
                                });
                              },
                            ),
                          ],
                        ),
                      ),
                      const Divider(height: 1),
                    ],
                  );
                },
              );
            })(),
          ),
        ],
      ),
    );
  }
}

/// iOS 離線 AI 模型資訊頁：
/// - 顯示 Whisper-small（bundle）狀態
/// - 顯示 Qwen-2.5-1.5B-Instruct INT4 bundle 載入狀態（不再提供下載）
class OfflineAiModelPage extends StatefulWidget {
  const OfflineAiModelPage({
    super.key,
    required this.service,
    required this.initialStatus,
  });

  final OfflineAIService service;
  final OfflineAIStatus initialStatus;

  @override
  State<OfflineAiModelPage> createState() => _OfflineAiModelPageState();
}

class _OfflineAiModelPageState extends State<OfflineAiModelPage> {
  late OfflineAIStatus _status;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _status = widget.initialStatus;
    _refresh();
  }

  Future<void> _refresh() async {
    try {
      final OfflineAIStatus s = await widget.service.initialize();
      if (!mounted) return;
      setState(() => _status = s);
    } catch (_) {}
  }

  /// 嘗試請原生端把 bundle 內 Qwen 載入記憶體（等同 prewarm，但附回錯誤訊息）。
  Future<void> _loadBundled() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.service.ensureLlmDownloaded();
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('載入失敗：$e')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _fmtBytes(int? bytes) {
    if (bytes == null || bytes <= 0) return '—';
    const List<String> units = <String>['B', 'KB', 'MB', 'GB'];
    double value = bytes.toDouble();
    int u = 0;
    while (value >= 1024 && u < units.length - 1) {
      value /= 1024;
      u += 1;
    }
    return '${value.toStringAsFixed(value >= 10 ? 0 : 1)} ${units[u]}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('離線 AI 模型'),
        backgroundColor: const Color(0xFF1a1a1a),
      ),
      backgroundColor: const Color(0xFF101010),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          Card(
            color: const Color(0xFF1a1a1a),
            child: ListTile(
              leading: Icon(
                _status.whisperReady ? Icons.check_circle : Icons.error_outline,
                color: _status.whisperReady ? Colors.greenAccent : Colors.orangeAccent,
              ),
              title: const Text('語音辨識：Whisper-small (Core ML)',
                  style: TextStyle(color: Colors.white)),
              subtitle: Text(
                _status.whisperReady
                    ? '已就緒（${_status.whisperModelName ?? "bundled"}）'
                    : '未偵測到 bundle 內模型。請依 ios/Runner/OfflineAI/README.md 放入 Models/openai_whisper-small/。',
                style: const TextStyle(color: Colors.white70),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            color: const Color(0xFF1a1a1a),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Icon(
                        _status.llmReady ? Icons.check_circle : Icons.error_outline,
                        color: _status.llmReady ? Colors.greenAccent : Colors.orangeAccent,
                      ),
                      const SizedBox(width: 10),
                      const Expanded(
                        child: Text(
                          '翻譯：Qwen-2.5-1.5B-Instruct (Q4_K_M, 已內建)',
                          style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _status.llmReady
                        ? '模型已載入，可離線翻譯。檔案大小 ${_fmtBytes(_status.llmBytes)}。'
                        : '尚未載入，點「載入模型」手動載入；或重新啟動 app 會自動從 bundle 讀取。\n'
                            '若顯示未內建，請依 ios/Runner/OfflineAI/README.md 把 Qwen GGUF 加入 Runner target。',
                    style: const TextStyle(color: Colors.white70),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: <Widget>[
                      ElevatedButton.icon(
                        onPressed: _busy || _status.llmReady ? null : _loadBundled,
                        icon: const Icon(Icons.memory),
                        label: Text(_status.llmReady ? '已就緒' : '載入模型'),
                      ),
                      const SizedBox(width: 12),
                      OutlinedButton.icon(
                        onPressed: _refresh,
                        icon: const Icon(Icons.refresh),
                        label: const Text('重新檢查'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              '說明：Whisper 與 Qwen 模型均打包於 app bundle，毋須下載即可離線執行。Whisper 負責語音轉文字，Qwen 負責翻譯。',
              style: TextStyle(color: Colors.white54, fontSize: 12, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}
