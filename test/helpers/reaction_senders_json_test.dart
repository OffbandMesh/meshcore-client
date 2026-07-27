import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/helpers/reaction_helper.dart';

void main() {
  group('ReactionHelper.reactionSendersFromJson (#383)', () {
    test('round-trips a real sender map through JSON', () {
      final original = <String, List<String>>{
        '\u{1F44D}': ['Alice', 'Bob'],
        '\u{2764}\u{FE0F}': ['Carol'],
      };
      final decoded = ReactionHelper.reactionSendersFromJson(
        jsonDecode(jsonEncode(original)),
      );
      expect(decoded, original);
    });

    test('an old store with no reactionSenders key degrades to empty', () {
      // This is the backward-compat guarantee: a record written before #383
      // has no such key, so the field is absent from the decoded JSON.
      expect(ReactionHelper.reactionSendersFromJson(null), isEmpty);
    });

    test('a non-map value is ignored rather than thrown', () {
      // A single bad entry must never fail the whole message-list load (#355).
      expect(ReactionHelper.reactionSendersFromJson('garbage'), isEmpty);
      expect(ReactionHelper.reactionSendersFromJson(42), isEmpty);
      expect(ReactionHelper.reactionSendersFromJson(['a', 'b']), isEmpty);
    });

    test('malformed entries within a map are skipped, valid ones kept', () {
      final decoded = ReactionHelper.reactionSendersFromJson({
        '\u{1F44D}': ['Alice', 42, null, 'Bob'], // non-strings dropped
        '\u{1F525}': 'not a list', // whole entry dropped
        '\u{1F389}': ['Dave'],
      });
      expect(decoded, {
        '\u{1F44D}': ['Alice', 'Bob'],
        '\u{1F389}': ['Dave'],
      });
    });
  });
}
