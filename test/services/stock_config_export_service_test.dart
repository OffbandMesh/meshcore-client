// #573 (epic #568): mapping live device state onto the stock export format.
//
// The mapping functions are pure, so they are tested directly. The parts that
// need a radio (identity read, connector state) belong to the T1 hardware gate.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/models/channel.dart';
import 'package:meshcore_open/models/contact.dart';
import 'package:meshcore_open/models/stock_config.dart';
import 'package:meshcore_open/services/stock_config_export_service.dart';

Uint8List bytes(List<int> values) => Uint8List.fromList(values);

Contact makeContact({
  int type = 1,
  int flags = 0,
  String name = 'Node',
  double? latitude,
  double? longitude,
  int pathLength = -1,
  int pathHashWidth = 1,
  List<int> path = const [],
  DateTime? lastSeen,
  DateTime? lastModified,
}) {
  return Contact(
    publicKey: Uint8List(32),
    name: name,
    type: type,
    flags: flags,
    pathLength: pathLength,
    pathHashWidth: pathHashWidth,
    path: bytes(path),
    latitude: latitude,
    longitude: longitude,
    lastSeen: lastSeen ?? DateTime.fromMillisecondsSinceEpoch(1785706493000),
    lastModified: lastModified,
  );
}

void main() {
  group('channel mapping', () {
    test('carries name and psk, and writes no index', () {
      final stock = toStockChannel(
        Channel(index: 4, name: 'Public', psk: Uint8List(16)),
      );

      expect(stock.name, 'Public');
      expect(stock.secret, hasLength(16));
      expect(stock.toJson().keys, unorderedEquals(['name', 'secret']));
    });
  });

  group('contact mapping', () {
    test('an absent position becomes zero, which is what stock writes', () {
      final stock = toStockContact(makeContact());

      expect(stock.latitude, 0);
      expect(stock.toJson()['latitude'], '0.0');
    });

    test('a position is carried through as a decimal string', () {
      final stock = toStockContact(
        makeContact(latitude: 39.561991, longitude: -84.635731),
      );

      expect(stock.toJson()['latitude'], '39.561991');
      expect(stock.toJson()['longitude'], '-84.635731');
    });

    test('timestamps convert to epoch seconds', () {
      final stock = toStockContact(
        makeContact(
          lastSeen: DateTime.fromMillisecondsSinceEpoch(1785706493000),
          lastModified: DateTime.fromMillisecondsSinceEpoch(1785706508000),
        ),
      );

      expect(stock.lastAdvert, 1785706493);
      expect(stock.lastModified, 1785706508);
    });

    test('a contact with no recorded modification falls back to last seen', () {
      final stock = toStockContact(
        makeContact(
          lastSeen: DateTime.fromMillisecondsSinceEpoch(1785706493000),
        ),
      );

      expect(stock.lastModified, 1785706493);
    });

    test('a flood route is written as no path', () {
      // pathLength of -1 means flood, which stock has no representation for.
      final stock = toStockContact(makeContact(pathLength: -1));

      expect(stock.outPath, isNull);
      expect(stock.toJson()['out_path_list'], isNull);
    });

    test('a width-aware path keeps both its hop count and its width', () {
      final stock = toStockContact(
        makeContact(
          pathLength: 2,
          pathHashWidth: 2,
          path: [0xa1, 0xb2, 0xc3, 0xd4],
        ),
      );

      expect(stock.outPath!.hopCount, 2);
      expect(stock.outPath!.hashWidth, 2);
      expect(stock.toJson()['out_path_list'], 'a1b2,c3d4');
    });

    test('a single-width path round trips to comma separated bytes', () {
      final stock = toStockContact(
        makeContact(pathLength: 3, pathHashWidth: 1, path: [0x0a, 0x0b, 0x0c]),
      );

      expect(stock.toJson()['out_path_list'], '0a,0b,0c');
    });

    test('trailing path bytes beyond the hop count are not written', () {
      // The buffer can be longer than the live path; only hopCount * width
      // bytes are meaningful.
      final stock = toStockContact(
        makeContact(
          pathLength: 1,
          pathHashWidth: 2,
          path: [0xa1, 0xb2, 0xff, 0xff],
        ),
      );

      expect(stock.toJson()['out_path_list'], 'a1b2');
    });

    test(
      'a path shorter than its declared hop count is dropped, not guessed',
      () {
        final stock = toStockContact(
          makeContact(pathLength: 4, pathHashWidth: 2, path: [0xa1, 0xb2]),
        );

        expect(stock.outPath, isNull);
      },
    );

    test('a hash width stock cannot express is dropped', () {
      final stock = toStockContact(
        makeContact(pathLength: 1, pathHashWidth: 4, path: [1, 2, 3, 4]),
      );

      expect(stock.outPath, isNull);
    });

    test('flags and type pass through untouched', () {
      final stock = toStockContact(makeContact(type: 3, flags: 15));

      expect(stock.type, 3);
      expect(stock.flags, 15);
      expect(stock.isFavourite, isTrue);
    });
  });

  group('export result', () {
    test('is only complete when nothing was omitted', () {
      const complete = StockConfigExportResult(
        config: StockConfig(),
        included: {StockConfigSection.name},
        omitted: {},
      );
      const partial = StockConfigExportResult(
        config: StockConfig(),
        included: {},
        omitted: {StockConfigSection.identity: StockConfigOmission.unsupported},
      );

      expect(complete.isComplete, isTrue);
      expect(partial.isComplete, isFalse);
    });
  });
}
