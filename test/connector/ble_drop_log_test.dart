// #1186: a user's iPhone dropped its BLE link 44 times in 3 hours, and no log
// line said why. Every drop came through the connector's connectionState
// listener, which ended the connection without recording anything.
//
// These tests push a real `disconnected` event through that listener, using a
// fake Bluetooth platform, and read the debug log.

import 'dart:async';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_blue_plus_platform_interface/flutter_blue_plus_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/services/app_debug_log_service.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _radio = '00:11:22:33:44:55';

/// Lets the connect reach the platform and then holds it there, so the
/// connector's connectionState listener is live and the test decides when the
/// link drops.
final class _FakeBle extends FlutterBluePlusPlatform {
  final states = StreamController<BmConnectionStateResponse>.broadcast();
  Completer<void> connectCalled = Completer<void>();
  final _held = Completer<bool>();

  @override
  Stream<BmConnectionStateResponse> get onConnectionStateChanged =>
      states.stream;

  @override
  Future<bool> connect(BmConnectRequest request) {
    if (!connectCalled.isCompleted) connectCalled.complete();
    return _held.future;
  }

  void drop({int? code, String? text}) => states.add(
    BmConnectionStateResponse(
      remoteId: const DeviceIdentifier(_radio),
      connectionState: BmConnectionStateEnum.disconnected,
      disconnectReasonCode: code,
      disconnectReasonString: text,
    ),
  );

  void release() {
    if (!_held.isCompleted) _held.complete(false);
  }
}

Future<void> _settle() async {
  for (var i = 0; i < 10; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late _FakeBle ble;
  late MeshCoreConnector connector;
  late AppDebugLogService log;

  List<String> dropLines() => log.entries
      .map((e) => e.message)
      .where((m) => m.startsWith('BLE link dropped'))
      .toList();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PrefsManager.reset();
    await PrefsManager.initialize();
    ble = _FakeBle();
    FlutterBluePlusPlatform.instance = ble;
    log = AppDebugLogService()..setEnabled(true);
    connector = MeshCoreConnector()..setAppDebugLogServiceForTest(log);

    unawaited(
      connector.connect(BluetoothDevice.fromId(_radio)).catchError((_) {}),
    );
    await ble.connectCalled.future.timeout(const Duration(seconds: 5));
  });

  tearDown(() async {
    await connector.stopAutoReconnect();
    ble.release();
  });

  test('a drop reported by the OS writes one line saying why', () async {
    connector.setConnectedForTest();
    ble.drop(code: 15, text: 'Failed to encrypt the connection');
    await _settle();

    expect(
      dropLines(),
      hasLength(1),
      reason: 'the bug: the listener ended the connection and logged nothing',
    );
    final line = dropLines().single;
    expect(line, contains('last frame from the radio'));
    expect(line.toLowerCase(), isNot(contains('unknown')));
  });

  // The listener only acts on a drop of an established link. A manual
  // disconnect relies on the same guard: it leaves `connected` and cancels the
  // listener before the link goes down.
  test('a disconnect before the link is up is not logged as a drop', () async {
    ble.drop();
    await _settle();

    expect(dropLines(), isEmpty);
  });
}
