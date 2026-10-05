import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';

void main() {
  // Frame layout per the doc comment on buildUpdateContactPathFrame:
  //   [cmd][pub_key x32][type][flags][path_len][path x64][name x32]
  //   [timestamp x4][Lat? x4, Lon? x4][timestamp? x4]
  //
  // Base (mandatory) bytes:
  //   1 cmd + 32 pubKey + 1 type + 1 flags + 1 pathLen + 64 path
  //   + 32 name + 4 timestamp = 136 bytes
  const int baseFrameLength = 136;

  final pubKey = Uint8List.fromList(List<int>.generate(32, (i) => i));
  final path = Uint8List.fromList([0xAA, 0xBB]);

  // Byte offset of path_len in the frame: 1 cmd + 32 pubKey + 1 type + 1 flags.
  const int pathLenOffset = 35;

  group('buildUpdateContactPathFrame path_len encoding (#309)', () {
    test('packs the hash width into the high 2 bits', () {
      // One 2-byte hop must go out as 0x41, not a bare 1. Writing the count
      // raw leaves mode bits 00, which tells the radio "1-byte hashes" while
      // handing it 2-byte hash data, so it routes to nodes that were never on
      // the route. That is the send-side half of #240's misrouting.
      final frame = buildUpdateContactPathFrame(
        pubKey,
        Uint8List.fromList([0xC6, 0x5C]),
        1,
        hashWidth: 2,
      );
      expect(frame[pathLenOffset], 0x41);
      expect(pathHopCount(frame[pathLenOffset]), 1);
      expect(pathHashSizeBytes(frame[pathLenOffset]), 2);
    });

    test('two 2-byte hops encode as 0x42', () {
      final frame = buildUpdateContactPathFrame(
        pubKey,
        Uint8List.fromList([0xC6, 0x5C, 0xA1, 0xB2]),
        2,
        hashWidth: 2,
      );
      expect(frame[pathLenOffset], 0x42);
      expect(pathByteLength(frame[pathLenOffset]), 4);
    });

    test('1-byte width is byte-identical to the pre-fix encoding', () {
      // Legacy 1-byte nets must see no change on the wire.
      final frame = buildUpdateContactPathFrame(
        pubKey,
        Uint8List.fromList([0xAA, 0xBB, 0xCC]),
        3,
        hashWidth: 1,
      );
      expect(frame[pathLenOffset], 3);
    });

    test('negative hop count emits the 0xFF flood sentinel', () {
      final frame = buildUpdateContactPathFrame(
        pubKey,
        Uint8List(0),
        -1,
        hashWidth: 2,
      );
      expect(frame[pathLenOffset], 0xFF);
    });
  });

  group('buildUpdateContactPathFrame', () {
    test('omits lat/lon and timestamp tail when neither is provided', () {
      final frame = buildUpdateContactPathFrame(
        pubKey,
        path,
        path.length,
        name: 'Alice',
      );

      // Should be exactly the base frame, no optional tail.
      expect(frame.length, baseFrameLength);
    });

    test('appends only an 8-byte lat/lon tail when location is provided', () {
      final frame = buildUpdateContactPathFrame(
        pubKey,
        path,
        path.length,
        lat: 49.123456,
        lon: -123.123456,
      );

      expect(frame.length, baseFrameLength + 8);
    });

    test(
      'appends 8 bytes lat/lon + 4 bytes timestamp when both are provided',
      () {
        final frame = buildUpdateContactPathFrame(
          pubKey,
          path,
          path.length,
          lat: 49.0,
          lon: -123.0,
          lastModified: DateTime.utc(2026, 1, 2, 3, 4, 5),
        );

        expect(frame.length, baseFrameLength + 8 + 4);
      },
    );

    test('zero-fills the lat/lon slots and appends timestamp when only '
        'lastModified is provided', () {
      final frame = buildUpdateContactPathFrame(
        pubKey,
        path,
        path.length,
        lastModified: DateTime.utc(2026, 1, 2, 3, 4, 5),
      );

      // 8 zero bytes for lat/lon + 4 bytes timestamp
      expect(frame.length, baseFrameLength + 8 + 4);

      // Verify the lat/lon slot is actually zero, guards against a
      // regression where the function writes garbage into those bytes.
      final tailStart = baseFrameLength;
      for (var i = tailStart; i < tailStart + 8; i++) {
        expect(frame[i], 0, reason: 'byte $i in lat/lon slot must be 0');
      }
    });

    test('encodes positive lat/lon as little-endian fixed-point (×1e6)', () {
      final frame = buildUpdateContactPathFrame(
        pubKey,
        path,
        path.length,
        lat: 49.123456,
        lon: -123.123456,
      );

      // Latitude is the first 4 bytes of the optional tail.
      final latBytes = ByteData.sublistView(
        frame,
        baseFrameLength,
        baseFrameLength + 4,
      );
      final lonBytes = ByteData.sublistView(
        frame,
        baseFrameLength + 4,
        baseFrameLength + 8,
      );

      expect(latBytes.getInt32(0, Endian.little), (49.123456 * 1e6).round());
      expect(lonBytes.getInt32(0, Endian.little), (-123.123456 * 1e6).round());
    });
  });

  group('last_advert_timestamp for key-only adds (#627)', () {
    // 1 cmd + 32 pubKey + 1 type + 1 flags + 1 pathLen + 64 path + 32 name.
    const int advertTsOffset = 132;

    int advertTs(Uint8List frame) => ByteData.sublistView(
      frame,
      advertTsOffset,
      advertTsOffset + 4,
    ).getUint32(0, Endian.little);

    test('a key-only add writes zero, not the current time', () {
      // The whole point. The firmware discards any advert whose timestamp is
      // <= this value as a replay attack (BaseChatMesh.cpp:142-145), and
      // advert timestamps come from the SENDER's clock. Writing "now" here
      // would leave a key-added contact permanently deaf to its own adverts.
      final frame = buildUpdateContactPathFrame(
        pubKey,
        Uint8List(0),
        -1,
        name: 'Bob',
        lastAdvert: DateTime.fromMillisecondsSinceEpoch(0),
      );
      expect(advertTs(frame), 0);
    });

    test(
      'omitting lastAdvert still stamps now, so path updates are unchanged',
      () {
        final before = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        final frame = buildUpdateContactPathFrame(pubKey, path, 1);
        final after = DateTime.now().millisecondsSinceEpoch ~/ 1000;

        expect(advertTs(frame), greaterThanOrEqualTo(before));
        expect(advertTs(frame), lessThanOrEqualTo(after));
      },
    );

    test('a pre-epoch value clamps to zero rather than wrapping', () {
      // writeUInt32LE on a negative would wrap to a huge timestamp, which is
      // the worst possible value for the replay guard.
      final frame = buildUpdateContactPathFrame(
        pubKey,
        Uint8List(0),
        -1,
        lastAdvert: DateTime.fromMillisecondsSinceEpoch(-86400000),
      );
      expect(advertTs(frame), 0);
    });

    test('a key-only add is a full-length frame with the flood sentinel', () {
      // The firmware guard is only `len >= 36`, but updateContactFromFrame
      // reads through offset 136 regardless (MyMesh.cpp:295-318), so a short
      // frame would have it read past what we sent. Never trim this.
      final frame = buildUpdateContactPathFrame(
        pubKey,
        Uint8List(0),
        -1,
        name: 'Bob',
        lastAdvert: DateTime.fromMillisecondsSinceEpoch(0),
      );
      expect(frame.length, greaterThanOrEqualTo(baseFrameLength));
      expect(frame[pathLenOffset], 0xFF);
    });
  });
}
