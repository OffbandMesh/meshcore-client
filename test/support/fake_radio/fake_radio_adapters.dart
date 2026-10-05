import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:meshcore_open/connector/meshcore_connector.dart';

import 'fake_radio.dart';

/// Serial framing the TCP companion link uses (firmware
/// `ArduinoSerialInterface`; client `usb_serial_frame_codec.dart`): the app
/// sends `0x3c len_lo len_hi payload`, the radio answers `0x3e len_lo len_hi
/// payload`. Written here independently of the client's codec.
const int _appToRadioStart = 0x3c;
const int _radioToAppStart = 0x3e;

/// The fake radio on a loopback TCP port, for the client's real
/// `connectTcp` path and for the desktop app (#768).
class FakeRadioTcpServer {
  FakeRadioTcpServer._(this.radio, this._server) {
    _server.listen(_accept);
    _pushSub = radio.pushes.listen((frame) {
      for (final s in _sockets) {
        s.add(_wrap(frame));
      }
    });
    _dropSub = radio.drops.listen((_) async {
      for (final s in List<Socket>.of(_sockets)) {
        await s.flush();
        s.destroy();
      }
      _sockets.clear();
    });
  }

  late final StreamSubscription<void> _dropSub;

  static Future<FakeRadioTcpServer> start(
    FakeRadio radio, {
    InternetAddress? address,
    int port = 0,
  }) async {
    final server = await ServerSocket.bind(
      address ?? InternetAddress.loopbackIPv4,
      port,
    );
    return FakeRadioTcpServer._(radio, server);
  }

  final FakeRadio radio;
  final ServerSocket _server;
  final List<Socket> _sockets = [];
  late final StreamSubscription<Uint8List> _pushSub;

  String get host => _server.address.address;
  int get port => _server.port;

  void _accept(Socket socket) {
    _sockets.add(socket);
    final buffer = <int>[];
    socket.listen(
      (data) {
        buffer.addAll(data);
        while (true) {
          final start = buffer.indexOf(_appToRadioStart);
          if (start < 0) {
            buffer.clear();
            return;
          }
          if (start > 0) buffer.removeRange(0, start);
          if (buffer.length < 3) return;
          final len = buffer[1] | (buffer[2] << 8);
          if (buffer.length < 3 + len) return;
          final payload = Uint8List.fromList(buffer.sublist(3, 3 + len));
          buffer.removeRange(0, 3 + len);
          for (final reply in radio.handle(payload)) {
            socket.add(_wrap(reply));
          }
        }
      },
      onDone: () => _sockets.remove(socket),
      onError: (_) => _sockets.remove(socket),
    );
  }

  static Uint8List _wrap(Uint8List payload) {
    final out = Uint8List(3 + payload.length);
    out[0] = _radioToAppStart;
    out[1] = payload.length & 0xFF;
    out[2] = (payload.length >> 8) & 0xFF;
    out.setRange(3, out.length, payload);
    return out;
  }

  Future<void> close() async {
    await _pushSub.cancel();
    await _dropSub.cancel();
    for (final s in List<Socket>.of(_sockets)) {
      s.destroy();
    }
    await _server.close();
  }
}

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
