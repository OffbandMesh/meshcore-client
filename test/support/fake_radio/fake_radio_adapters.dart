import 'dart:async';
import 'dart:typed_data';

import 'package:meshcore_open/connector/meshcore_connector.dart';

import 'fake_radio.dart';

export 'fake_radio_tcp.dart';

/// The fake radio plugged straight into the connector's test seam: no
/// sockets, so widget tests stay fast (#768). Replies arrive on a later
/// microtask, like a transport delivers them.
class FakeRadioInProcess {
  FakeRadioInProcess._(this.connector, this.radio) {
    connector.sendFrameOverrideForTest = (frame) {
      for (final reply in radio.handle(frame)) {
        scheduleMicrotask(() => connector.handleFrameForTest(reply));
      }
    };
    _pushSub = radio.pushes.listen(
      (frame) => scheduleMicrotask(() => connector.handleFrameForTest(frame)),
    );
    // A dropped link ends the transport, as TCP's onDone does in connectTcp.
    _dropSub = radio.drops.listen((_) {
      connector.sendFrameOverrideForTest = null;
      unawaited(connector.disconnect(manual: false));
    });
  }

  late final StreamSubscription<void> _dropSub;

  /// Attaches [radio] and runs the connector's real handshake against it.
  static Future<FakeRadioInProcess> connect(
    MeshCoreConnector connector,
    FakeRadio radio,
  ) async {
    final link = FakeRadioInProcess._(connector, radio);
    await connector.connectInProcessForTest();
    return link;
  }

  final MeshCoreConnector connector;
  final FakeRadio radio;
  late final StreamSubscription<Uint8List> _pushSub;

  Future<void> close() async {
    await _pushSub.cancel();
    await _dropSub.cancel();
    connector.sendFrameOverrideForTest = null;
  }
}
