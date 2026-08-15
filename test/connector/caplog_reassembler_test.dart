import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/caplog_reassembler.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';

Uint8List _start(int total) => Uint8List.fromList([
  respCodeOffbandCaplog,
  caplogSubStart,
  total & 0xFF,
  (total >> 8) & 0xFF,
  (total >> 16) & 0xFF,
  (total >> 24) & 0xFF,
]);

Uint8List _startNoLen() =>
    Uint8List.fromList([respCodeOffbandCaplog, caplogSubStart]);

Uint8List _chunk(List<int> bytes) =>
    Uint8List.fromList([respCodeOffbandCaplog, caplogSubChunk, ...bytes]);

Uint8List _end() => Uint8List.fromList([respCodeOffbandCaplog, caplogSubEnd]);

void main() {
  group('CaplogReassembler', () {
    test('reassembles START/CHUNK*/END into the full payload', () {
      final r = CaplogReassembler();
      expect(r.accept(_start(5)).status, CaplogStatus.started);
      expect(r.accept(_chunk([1, 2, 3])).status, CaplogStatus.chunk);
      expect(r.accept(_chunk([4, 5])).status, CaplogStatus.chunk);
      final end = r.accept(_end());
      expect(end.status, CaplogStatus.completed);
      expect(end.bytes, Uint8List.fromList([1, 2, 3, 4, 5]));
    });

    test('empty capture: START(0) then END completes with no bytes', () {
      final r = CaplogReassembler();
      r.accept(_start(0));
      final end = r.accept(_end());
      expect(end.status, CaplogStatus.completed);
      expect(end.bytes, isEmpty);
    });

    test('flags truncation when reassembled bytes < announced total', () {
      final r = CaplogReassembler();
      r.accept(_start(10));
      r.accept(_chunk([1, 2, 3]));
      final end = r.accept(_end());
      expect(end.status, CaplogStatus.truncated);
      expect(end.expected, 10);
      expect(end.bytes!.length, 3);
    });

    test('START without a length reassembles with no truncation check', () {
      final r = CaplogReassembler();
      r.accept(_startNoLen());
      r.accept(_chunk([9, 9]));
      final end = r.accept(_end());
      expect(end.status, CaplogStatus.completed);
      expect(end.bytes, Uint8List.fromList([9, 9]));
    });

    test('ignores CHUNK/END with no preceding START', () {
      final r = CaplogReassembler();
      expect(r.accept(_chunk([1])).status, CaplogStatus.ignored);
      expect(r.accept(_end()).status, CaplogStatus.ignored);
    });

    test('ignores non-caplog frames', () {
      final r = CaplogReassembler();
      expect(
        r.accept(Uint8List.fromList([respCodeOk])).status,
        CaplogStatus.ignored,
      );
      expect(
        r.accept(Uint8List.fromList([cmdOffbandFemLna, 0x01, 0x01])).status,
        CaplogStatus.ignored,
      );
    });

    test('a second download reuses the same reassembler cleanly', () {
      final r = CaplogReassembler();
      r.accept(_start(2));
      r.accept(_chunk([1, 2]));
      expect(r.accept(_end()).status, CaplogStatus.completed);
      r.accept(_start(3));
      r.accept(_chunk([7, 8, 9]));
      final end = r.accept(_end());
      expect(end.status, CaplogStatus.completed);
      expect(end.bytes, Uint8List.fromList([7, 8, 9]));
    });

    test('a fresh START mid-stream discards the prior partial buffer', () {
      final r = CaplogReassembler();
      r.accept(_start(99));
      r.accept(_chunk([1, 2, 3])); // abandoned
      r.accept(_start(2)); // restart
      r.accept(_chunk([4, 5]));
      final end = r.accept(_end());
      expect(end.status, CaplogStatus.completed);
      expect(end.bytes, Uint8List.fromList([4, 5]));
    });

    test('large multi-chunk payload reassembles in order', () {
      final r = CaplogReassembler();
      final expected = List<int>.generate(500, (i) => i % 256);
      r.accept(_start(expected.length));
      for (var i = 0; i < expected.length; i += 50) {
        r.accept(_chunk(expected.sublist(i, i + 50)));
      }
      final end = r.accept(_end());
      expect(end.status, CaplogStatus.completed);
      expect(end.bytes, Uint8List.fromList(expected));
    });
  });

  group('CaplogDownload', () {
    test('truncated when received < expected, and keeps the partial bytes', () {
      final d = CaplogDownload(
        bytes: Uint8List.fromList([1, 2, 3]),
        received: 3,
        expected: 10,
        chunks: 2,
      );
      expect(d.truncated, isTrue);
      expect(d.bytes, Uint8List.fromList([1, 2, 3]));
    });

    test('not truncated when received == expected', () {
      final d = CaplogDownload(
        bytes: Uint8List.fromList([1, 2, 3]),
        received: 3,
        expected: 3,
        chunks: 1,
      );
      expect(d.truncated, isFalse);
    });
  });
}
