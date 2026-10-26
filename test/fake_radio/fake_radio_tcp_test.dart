import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import '../support/fake_radio/fake_radio.dart';
import '../support/fake_radio/fake_radio_codes.dart';
import '../support/fake_radio/fake_radio_tcp.dart';

// The fake's TCP framing against firmware ArduinoSerialInterface::
// checkRecvFrame: frames split across reads, a zero length skipped, and a
// frame over MAX_FRAME_SIZE read to its end and cut.

void main() {
  late FakeRadio radio;
  late FakeRadioTcpServer server;
  late Socket socket;
  late StreamController<List<int>> replies;
  late StreamIterator<List<int>> next;

  setUp(() async {
    radio = FakeRadio();
    server = await FakeRadioTcpServer.start(radio);
    socket = await Socket.connect(server.host, server.port);
    replies = StreamController<List<int>>();
    next = StreamIterator(replies.stream);
    final buf = <int>[];
    socket.listen((data) {
      buf.addAll(data);
      while (buf.length >= 3 && buf.length >= 3 + (buf[1] | buf[2] << 8)) {
        final len = buf[1] | buf[2] << 8;
        replies.add(buf.sublist(3, 3 + len));
        buf.removeRange(0, 3 + len);
      }
    });
  });

  tearDown(() async {
    socket.destroy();
    await server.close();
  });

  List<int> frame(List<int> payload) => [
    0x3c,
    payload.length & 0xFF,
    payload.length >> 8,
    ...payload,
  ];

  Future<List<int>> nextReply() async {
    expect(await next.moveNext().timeout(const Duration(seconds: 5)), isTrue);
    return next.current;
  }

  test('a frame split across two writes is put back together', () async {
    final f = frame([fwCmdDeviceQuery, 3]);
    socket.add(f.sublist(0, 2));
    await socket.flush();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    socket.add(f.sublist(2));
    expect((await nextReply())[0], fwRespDeviceInfo);
  });

  test('a zero-length frame is skipped, and the next one is handled', () async {
    socket.add([
      ...frame([]),
      ...frame([fwCmdDeviceQuery, 3]),
    ]);
    expect((await nextReply())[0], fwRespDeviceInfo);
    expect(radio.received, hasLength(1));
  });

  test('a frame over MAX_FRAME_SIZE is read to its end, then cut', () async {
    final big = [fwCmdDeviceQuery, 3, ...List<int>.filled(200, 0x41)];
    socket.add([
      ...frame(big),
      ...frame([fwCmdGetDeviceTime]),
    ]);
    expect((await nextReply())[0], fwRespDeviceInfo);
    expect((await nextReply())[0], fwRespCurrTime);
    expect(radio.received.first, hasLength(maxFrameSize));
    expect(radio.received.first, Uint8List.fromList(big.take(176).toList()));
  });
}
