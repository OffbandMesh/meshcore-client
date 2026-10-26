import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/l10n/app_localizations.dart';
import 'package:meshcore_open/screens/scanner_screen.dart';
import 'package:meshcore_open/screens/usb_screen.dart';
import 'package:meshcore_open/utils/platform_info.dart';

class _FakeMeshCoreConnector extends MeshCoreConnector {
  _FakeMeshCoreConnector({
    this.initialState = MeshCoreConnectionState.disconnected,
    List<String>? ports,
  }) : _ports = ports ?? <String>[];

  final MeshCoreConnectionState initialState;
  final List<String> _ports;

  MeshCoreTransportType fakeTransport = MeshCoreTransportType.usb;
  bool fakeAutoReconnecting = false;
  bool fakeGaveUp = false;
  int stopCalls = 0;
  int retryCalls = 0;

  String? requestPortLabel;
  String? fallbackDeviceName;
  int connectUsbCalls = 0;
  String? lastConnectPortName;
  String? fakeActiveUsbPort;
  String? fakeActiveUsbPortDisplayLabel;
  bool fakeUsbTransportConnected = false;
  Future<List<String>> Function()? listUsbPortsImpl;
  Future<void> Function({required String portName})? connectUsbImpl;

  @override
  MeshCoreConnectionState get state => initialState;

  @override
  MeshCoreTransportType get activeTransport => fakeTransport;

  @override
  bool get isAutoReconnecting => fakeAutoReconnecting;

  @override
  bool get autoReconnectGaveUp => fakeGaveUp;

  @override
  int get autoReconnectAttempt => 2;

  @override
  String? get autoReconnectTargetName => 'T1000-E';

  @override
  Future<void> stopAutoReconnect() async => stopCalls += 1;

  @override
  Future<void> retryLastDevice() async => retryCalls += 1;

  @override
  String? get activeUsbPort => fakeActiveUsbPort;

  @override
  String? get activeUsbPortDisplayLabel =>
      fakeActiveUsbPortDisplayLabel ?? fakeActiveUsbPort;

  @override
  bool get isUsbTransportConnected => fakeUsbTransportConnected;

  @override
  Future<List<String>> listUsbPorts() async {
    if (listUsbPortsImpl != null) {
      return listUsbPortsImpl!();
    }
    return List<String>.from(_ports);
  }

  @override
  Future<void> connectUsb({
    required String portName,
    int baudRate = 115200,
  }) async {
    if (connectUsbImpl != null) {
      return connectUsbImpl!(portName: portName);
    }
    connectUsbCalls += 1;
    lastConnectPortName = portName;
  }

  @override
  void setUsbRequestPortLabel(String label) {
    requestPortLabel = label;
  }

  @override
  void setUsbFallbackDeviceName(String label) {
    fallbackDeviceName = label;
  }
}

Widget _buildTestApp({
  required MeshCoreConnector connector,
  required Widget child,
}) {
  return ChangeNotifierProvider<MeshCoreConnector>.value(
    value: connector,
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: child,
    ),
  );
}

void main() {
  testWidgets('UsbScreen passes localized chooser label to connector', (
    tester,
  ) async {
    final connector = _FakeMeshCoreConnector();

    await tester.pumpWidget(
      _buildTestApp(connector: connector, child: const UsbScreen()),
    );
    await tester.pumpAndSettle();

    expect(connector.requestPortLabel, 'Select a USB device');
  });

  testWidgets(
    'UsbScreen does not call connectUsb when connector is not disconnected',
    (tester) async {
      final connector = _FakeMeshCoreConnector(
        initialState: MeshCoreConnectionState.connected,
        ports: <String>['COM6 - USB Serial Device (COM6)'],
      );

      await tester.pumpWidget(
        _buildTestApp(connector: connector, child: const UsbScreen()),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byType(ListTile).first);
      await tester.pump();

      expect(connector.connectUsbCalls, 0);

      // UsbScreen.dispose() schedules disconnect work that debounces notify.
      // Drain that debounce timer before test teardown.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 60));
    },
  );

  testWidgets('UsbScreen sends raw port name when tapping Connect', (
    tester,
  ) async {
    final connector = _FakeMeshCoreConnector(
      ports: <String>['COM6 - USB Serial Device (COM6)'],
    );

    await tester.pumpWidget(
      _buildTestApp(connector: connector, child: const UsbScreen()),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byType(ListTile).first);
    await tester.pump();

    expect(connector.connectUsbCalls, 1);
    expect(connector.lastConnectPortName, 'COM6');
  });

  testWidgets(
    'UsbScreen connects while a BLE auto-reconnect holds the state (#997)',
    (tester) async {
      // The 2026-10-25 log: a USB tap during the retry loop was dropped
      // silently, for 74 minutes, until the app was restarted.
      final connector =
          _FakeMeshCoreConnector(
              initialState: MeshCoreConnectionState.connecting,
              ports: <String>['COM13 - USB Serial Device (COM13)'],
            )
            ..fakeTransport = MeshCoreTransportType.bluetooth
            ..fakeAutoReconnecting = true;

      await tester.pumpWidget(
        _buildTestApp(connector: connector, child: const UsbScreen()),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byType(ListTile).first);
      await tester.pump();

      expect(connector.connectUsbCalls, 1);
      expect(connector.lastConnectPortName, 'COM13');

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 60));
    },
  );

  testWidgets('ScannerScreen shows the retry and a Stop that ends it (#997)', (
    tester,
  ) async {
    final connector =
        _FakeMeshCoreConnector(initialState: MeshCoreConnectionState.connecting)
          ..fakeTransport = MeshCoreTransportType.bluetooth
          ..fakeAutoReconnecting = true;

    await tester.pumpWidget(
      _buildTestApp(connector: connector, child: const ScannerScreen()),
    );
    await tester.pump();

    expect(find.textContaining('attempt 2 of 5'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Stop'));
    await tester.pump();
    expect(connector.stopCalls, 1);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 60));
  });

  testWidgets('ScannerScreen offers Retry once the retry gave up (#997)', (
    tester,
  ) async {
    final connector = _FakeMeshCoreConnector()
      ..fakeTransport = MeshCoreTransportType.bluetooth
      ..fakeGaveUp = true;

    await tester.pumpWidget(
      _buildTestApp(connector: connector, child: const ScannerScreen()),
    );
    await tester.pump();

    expect(find.textContaining("Couldn't reach T1000-E"), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Retry'));
    await tester.pump();
    expect(connector.retryCalls, 1);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 60));
  });

  testWidgets('ScannerScreen USB action reflects platform support', (
    tester,
  ) async {
    final connector = _FakeMeshCoreConnector();

    await tester.pumpWidget(
      _buildTestApp(connector: connector, child: const ScannerScreen()),
    );
    await tester.pumpAndSettle();

    if (PlatformInfo.supportsUsbSerial) {
      expect(find.widgetWithText(FloatingActionButton, 'USB'), findsOneWidget);
    } else {
      expect(find.widgetWithText(FloatingActionButton, 'USB'), findsNothing);
    }

    // ScannerScreen.dispose() schedules disconnect work that debounces notify.
    // Drain that debounce timer before test teardown.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 60));
  });

  testWidgets('ScannerScreen narrow width keeps actions without overflow', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final connector = _FakeMeshCoreConnector();

    await tester.pumpWidget(
      _buildTestApp(connector: connector, child: const ScannerScreen()),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);

    final context = tester.element(find.byType(ScannerScreen));
    final l10n = AppLocalizations.of(context);
    expect(find.text(l10n.scanner_scan), findsOneWidget);

    if (PlatformInfo.supportsUsbSerial) {
      expect(find.text(l10n.connectionChoiceUsbLabel), findsOneWidget);
    }
    if (!PlatformInfo.isWeb) {
      expect(find.text(l10n.connectionChoiceTcpLabel), findsOneWidget);
    }

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 60));
  });

  testWidgets('UsbScreen narrow width long status text does not overflow', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final connector =
        _FakeMeshCoreConnector(initialState: MeshCoreConnectionState.connected)
          ..fakeUsbTransportConnected = true
          ..fakeActiveUsbPortDisplayLabel =
              '/dev/bus/usb/001/002 - KD3CGK mesh-utility.org very long label';

    await tester.pumpWidget(
      _buildTestApp(connector: connector, child: const UsbScreen()),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);

    final context = tester.element(find.byType(UsbScreen));
    final l10n = AppLocalizations.of(context);
    expect(
      find.text(
        l10n.scanner_connectedTo(connector.fakeActiveUsbPortDisplayLabel!),
      ),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 60));
  });

  group('Error Handling', () {
    testWidgets('shows error SnackBar when listing ports fails', (
      tester,
    ) async {
      final connector = _FakeMeshCoreConnector();
      connector.listUsbPortsImpl = () async {
        throw PlatformException(
          code: 'usb_permission_denied',
          message: 'Permission denied',
        );
      };

      await tester.pumpWidget(
        _buildTestApp(connector: connector, child: const UsbScreen()),
      );
      await tester.pumpAndSettle();

      expect(find.text('USB permission was denied.'), findsOneWidget);
    });

    testWidgets('connection failure shows SnackBar error', (tester) async {
      final connector = _FakeMeshCoreConnector(ports: <String>['COM1']);
      var connectAttempted = false;
      connector.connectUsbImpl = ({required String portName}) async {
        connectAttempted = true;
        throw PlatformException(code: 'usb_busy', message: 'Device is busy');
      };

      await tester.pumpWidget(
        _buildTestApp(connector: connector, child: const UsbScreen()),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byType(ListTile).first);
      await tester.pumpAndSettle();

      expect(connectAttempted, isTrue);
      expect(
        find.text('Another USB connection request is already in progress.'),
        findsOneWidget,
      );
    });
  });
}
