import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/l10n/app_localizations.dart';
import 'package:meshcore_open/services/app_debug_log_service.dart';
import 'package:meshcore_open/services/app_settings_service.dart';
import 'package:meshcore_open/services/ble_debug_log_service.dart';
import 'package:meshcore_open/services/block_service.dart';
import 'package:meshcore_open/services/chat_text_scale_service.dart';
import 'package:meshcore_open/services/mesh_topology_service.dart';
import 'package:meshcore_open/services/message_retry_service.dart';
import 'package:meshcore_open/services/path_history_service.dart';
import 'package:meshcore_open/services/storage_service.dart';
import 'package:meshcore_open/services/timeout_prediction_service.dart';
import 'package:meshcore_open/services/translation_service.dart';
import 'package:meshcore_open/services/ui_view_state_service.dart';
import 'package:meshcore_open/storage/drift/blob_store.dart';
import 'package:meshcore_open/storage/drift/offband_database.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The app's services, wired as `main.dart` wires them, for screen tests
/// against the fake radio (#779). Heavy native pieces (map tiles, background
/// service, notifications, file logging) are left out: no screen under test
/// needs them.
class FakeRadioAppServices {
  FakeRadioAppServices._(this.db);

  static Future<FakeRadioAppServices> create() async {
    SharedPreferences.setMockInitialValues({});
    PrefsManager.reset();
    await PrefsManager.initialize();
    final db = OffbandDatabase(NativeDatabase.memory());
    BlobStore.overrideForTest(BlobStore(db));
    final s = FakeRadioAppServices._(db);
    await s.appSettings.loadSettings();
    s.connector.initialize(
      retryService: s.retry,
      pathHistoryService: s.pathHistory,
      topologyService: s.topology,
      appSettingsService: s.appSettings,
      translationService: s.translation,
      bleDebugLogService: s.bleLog,
      appDebugLogService: s.appLog,
      timeoutPredictionService: s.timeouts,
      blockService: s.blocks,
    );
    return s;
  }

  final OffbandDatabase db;
  final StorageService storage = StorageService();
  final MeshCoreConnector connector = MeshCoreConnector();
  final MessageRetryService retry = MessageRetryService();
  late final PathHistoryService pathHistory = PathHistoryService(storage);
  final MeshTopologyService topology = MeshTopologyService();
  final AppSettingsService appSettings = AppSettingsService();
  final BleDebugLogService bleLog = BleDebugLogService();
  final AppDebugLogService appLog = AppDebugLogService();
  final ChatTextScaleService textScale = ChatTextScaleService();
  late final TranslationService translation = TranslationService(appSettings);
  final UiViewStateService viewState = UiViewStateService();
  final TimeoutPredictionService timeouts =
      TimeoutPredictionService.noStorage();
  final BlockService blocks = BlockService();

  /// [home] inside the app's providers, localizations and theme.
  Widget app(Widget home) => MultiProvider(
    providers: [
      ChangeNotifierProvider.value(value: connector),
      ChangeNotifierProvider.value(value: retry),
      ChangeNotifierProvider.value(value: pathHistory),
      ChangeNotifierProvider.value(value: topology),
      ChangeNotifierProvider.value(value: appSettings),
      ChangeNotifierProvider.value(value: bleLog),
      ChangeNotifierProvider.value(value: appLog),
      ChangeNotifierProvider.value(value: textScale),
      ChangeNotifierProvider.value(value: translation),
      ChangeNotifierProvider.value(value: viewState),
      Provider.value(value: storage),
      ChangeNotifierProvider.value(value: timeouts),
      ChangeNotifierProvider.value(value: blocks),
    ],
    child: MaterialApp(
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('en'),
      home: home,
    ),
  );

  Future<void> dispose() async {
    await connector.disconnect();
    BlobStore.clearTestOverride();
    await db.close();
  }
}
