// Custom Name override for contacts (#750), task 750.2: the radio boundary.
//
// The radio's contact table is the shared record of what a node calls itself.
// A user's private label must never reach it. Firmware holds a single
// `char name[32]` per contact (`ContactInfo.h:10`), so writing the custom name
// there would overwrite the real one for no gain.
//
// This is the hole the type system cannot see: every frame-builder call site
// reads `.name`, which still compiles after the 750.1 rename and silently
// sends the custom name. T14 is a source-reading guard because nothing else
// can hold it.
//
// Tests T10 to T14 and T33 from the plan of record,
// docs/initiatives/standalone/750-contact-naming/PLAN.md.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';
import 'package:meshcore_open/models/contact.dart';
import 'package:meshcore_open/services/stock_config_export_service.dart';
import 'package:meshcore_open/storage/drift/blob_store.dart';
import 'package:meshcore_open/storage/drift/offband_database.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _received = 'KQ4EZN-Repeater';
const _custom = 'ChuckTheRepeater';

Contact _contact({String? customName}) => Contact(
  publicKey: Uint8List.fromList(List<int>.filled(32, 0x33)),
  receivedName: _received,
  customName: customName,
  type: advTypeChat,
  pathLength: -1,
  path: Uint8List(0),
  lastSeen: DateTime.utc(2026, 7, 1),
);

/// True when [needle] appears anywhere in [frame] as UTF-8 bytes.
bool _frameContains(Uint8List frame, String needle) {
  final n = utf8.encode(needle);
  for (var i = 0; i + n.length <= frame.length; i++) {
    var hit = true;
    for (var j = 0; j < n.length; j++) {
      if (frame[i + j] != n[j]) {
        hit = false;
        break;
      }
    }
    if (hit) return true;
  }
  return false;
}

void main() {
  late OffbandDatabase db;
  late MeshCoreConnector connector;
  late List<Uint8List> sent;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PrefsManager.reset();
    await PrefsManager.initialize();
    db = OffbandDatabase(NativeDatabase.memory());
    BlobStore.overrideForTest(BlobStore(db));

    connector = MeshCoreConnector();
    connector.contactsForTest.clear();
    sent = [];
    connector.sendFrameOverrideForTest = sent.add;
    connector.setConnectedForTest();
  });

  tearDown(() async {
    BlobStore.clearTestOverride();
    await db.close();
  });

  group('the radio receives the received name, never the custom one (#750)', () {
    test(
      'T10 + a renamed contact still sends what the node calls itself',
      () async {
        await connector.addContactByKey(_contact(customName: _custom));

        expect(sent, isNotEmpty, reason: 'a frame should have been emitted');
        expect(_frameContains(sent.single, _received), isTrue);
      },
    );

    test('T11 - the custom name appears nowhere in the frame bytes', () async {
      // The guard that stops a private label reaching the shared contact
      // table. `contact.name` would be '$_custom' here.
      await connector.addContactByKey(_contact(customName: _custom));

      expect(
        _frameContains(sent.single, _custom),
        isFalse,
        reason: 'the user label must not cross the wire',
      );
    });

    test(
      'T12 + with no custom name the frame is unchanged from before',
      () async {
        // Proves this change is behaviour-neutral for every existing path.
        await connector.addContactByKey(_contact());
        final withoutCustom = sent.single;

        sent.clear();
        await connector.addContactByKey(_contact(customName: _custom));
        final withCustom = sent.single;

        expect(withCustom, equals(withoutCustom));
      },
    );

    test(
      'T13 + a card stub sends the card name, which is its received name',
      () async {
        // A stub built from a contact-share card has the card's name as its
        // received name and no custom name, so nothing changes for the add path.
        await connector.addContactByKey(_contact());

        expect(_frameContains(sent.single, _received), isTrue);
      },
    );
  });

  group('T33 the stock config export is an interchange format (#750)', () {
    // A stock config file is loaded by other operators, where a contact name
    // reads as what that node calls itself. Exporting one user's private label
    // would hand it to everyone who imports the file.
    //
    // Written after the fix rather than before it, unlike the rest of this
    // file, so it is falsified below instead: breaking the export line must
    // make this test fail and nothing else.
    test('+ the export carries the received name', () {
      final stock = toStockContact(_contact(customName: _custom));

      expect(stock.name, _received);
    });

    test('- the custom name is absent from the exported record', () {
      final stock = toStockContact(_contact(customName: _custom));

      expect(stock.name, isNot(contains(_custom)));
    });
  });

  group('T36 sharing a renamed contact does not leak the label (#750)', () {
    // Found by the pre-PR adversarial review, not by me, and not reachable by
    // T14 because contact.dart was not in its watched list. A share payload
    // becomes the RECEIVED name on every device that imports it, so this leak
    // propagates to other operators rather than stopping at our own radio.
    test(
      '- the channel share carries the received name, not the custom one',
      () {
        final shared = _contact(customName: _custom).toChannelShare();

        expect(shared, contains(_received));
        expect(shared, isNot(contains(_custom)));
      },
    );

    test('- the share URI carries the received name, not the custom one', () {
      final shared = _contact(customName: _custom).toShareUri();

      expect(shared, contains(Uri.encodeComponent(_received)));
      expect(shared, isNot(contains(_custom)));
    });

    test('+ with no custom name both share formats are unchanged', () {
      expect(_contact().toChannelShare(), contains(_received));
      expect(_contact().toShareUri(), contains(Uri.encodeComponent(_received)));
    });
  });

  group('T14 source guard: no name-write site reads the display getter', () {
    // KNOWN LIMIT, measured not assumed. This guard matches `name: <ident>.name`
    // and therefore CANNOT see an intra-class read, where the getter is reached
    // as bare `name` with an implicit `this`. That is exactly where the share
    // leak T36 covers was living, inside contact.dart, and reverting the fix
    // was confirmed to leave this guard green while T36 failed.
    //
    // Widening the regex to catch bare `name:` is not possible without flooding
    // on legitimate parameter pass-through: the static build* helpers in
    // contact.dart take a `name` parameter and forward it, which is correct.
    //
    // So: this guard covers CROSS-class reads. Intra-class reads are covered
    // behaviourally, by T36 and T11. Do not add a site to contact.dart and
    // assume this test is watching it.
    // The compiler cannot catch these: `.name` still resolves after the 750.1
    // rename, so a site that reads it compiles and silently sends or stores
    // the user's label. Nine sites were found by grep during 750.1; this test
    // fails if any of them regresses or a tenth appears.
    const watched = <String>[
      // Added after the pre-PR review found the leak this list had missed:
      // toShareUri and toChannelShare both read `.name`, and a share payload
      // becomes the RECEIVED name on every device that imports it. The guard
      // was only watching the radio and the stores, not the paths that send a
      // name to other operators. (#750)
      'lib/models/contact.dart',
      'lib/connector/meshcore_connector.dart',
      'lib/services/stock_config_import_service.dart',
      'lib/services/stock_config_export_service.dart',
      'lib/storage/contact_store.dart',
      'lib/storage/contact_discovery_store.dart',
    ];

    // Reviewed exceptions, matched on line CONTENT rather than line number so
    // an edit above them does not quietly re-open the hole, and a genuinely
    // new offender still fails.
    //
    // `Channel` has no custom-name concept: its name is not a per-contact user
    // label, there is no override to confuse it with, and the stock channel
    // record wants exactly that string. (reviewed 2026-10-20)
    // `StockContact` is a record parsed from an imported stock config file,
    // not our `Contact`. It has no custom-name concept and its name is what
    // the file says the node calls itself, so it is already a received name.
    // This site was in the nine the plan correction listed; analyze proved it
    // was never wrong, so the real count of Contact-typed sites is eight.
    // (reviewed 2026-10-20)
    // Keyed by PATH. An exception in one file must never excuse the same line
    // in another: `name: contact.name,` is correct in the import service and
    // wrong in the connector, where `contact` is ours.
    const allowed = <String, Set<String>>{
      'lib/services/stock_config_export_service.dart': {
        'StockChannel(name: channel.name, secret: channel.psk);',
      },
      'lib/services/stock_config_import_service.dart': {'name: contact.name,'},
    };

    test('no watched file passes a Contact display name into a name field', () {
      final offenders = <String>[];
      // Matches `name: <ident>.name` and `'name': <ident>.name`, which is how
      // every one of the nine sites looked before 750.1 and 750.2 fixed them.
      final bad = RegExp(r"""'?name'?\s*:\s*[A-Za-z_][A-Za-z0-9_]*\.name\b""");

      for (final path in watched) {
        final lines = File(path).readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          final line = lines[i].trim();
          final exempt = allowed[path]?.contains(line) ?? false;
          if (bad.hasMatch(line) && !exempt) {
            offenders.add('$path:${i + 1}: $line');
          }
        }
      }

      expect(
        offenders,
        isEmpty,
        reason:
            'these sites send or store a name. They must read receivedName, '
            'never the .name getter, which returns the user custom name when '
            'one is set. See PLAN.md section 2, "the one hole".',
      );
    });

    test('the frame-builder call-site count is still five', () {
      // A sixth caller is not forbidden, but it must be reviewed against the
      // rule above rather than slipping in unnoticed.
      var calls = 0;
      for (final path in watched) {
        calls += RegExp(
          'buildUpdateContactPathFrame\\(',
        ).allMatches(File(path).readAsStringSync()).length;
      }

      expect(
        calls,
        5,
        reason:
            'a new buildUpdateContactPathFrame caller appeared or one was '
            'removed. Confirm it passes receivedName, then update this count.',
      );
    });
  });
}
