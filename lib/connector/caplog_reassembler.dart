import 'dart:typed_data';

import 'meshcore_protocol.dart';

/// Outcome of feeding one `0xC4` frame to [CaplogReassembler.accept].
enum CaplogStatus { started, chunk, completed, truncated, ignored }

/// Result of [CaplogReassembler.accept]. [bytes] is set on [CaplogStatus.completed]
/// and [CaplogStatus.truncated]; [expected] is set on [CaplogStatus.truncated].
class CaplogEvent {
  const CaplogEvent(this.status, {this.bytes, this.expected});
  final CaplogStatus status;
  final Uint8List? bytes;
  final int? expected;
}

/// Pure state machine that reassembles an Offband caplog (`0xC4`) streamed dump:
/// START `[0xC4, 0x01, total_len(uint32 LE)]` → CHUNK `[0xC4, 0x02, <bytes>]*`
/// → END `[0xC4, 0x03]`.
///
/// A CHUNK or END arriving without a preceding START, and any non-`0xC4` frame,
/// is [CaplogStatus.ignored]. Kept free of connector/transport concerns so the
/// reassembly is unit-testable in isolation. (#430)
class CaplogReassembler {
  final BytesBuilder _buffer = BytesBuilder();
  int? _expected;
  bool _active = false;

  CaplogEvent accept(Uint8List frame) {
    if (frame.length < 2 || frame[0] != respCodeOffbandCaplog) {
      return const CaplogEvent(CaplogStatus.ignored);
    }
    switch (frame[1]) {
      case caplogSubStart:
        _buffer.clear();
        // total_len is optional/defensive: an older device might omit it. When
        // absent we can't detect truncation, but still reassemble what arrives.
        _expected = frame.length >= 6 ? readUint32LE(frame, 2) : null;
        _active = true;
        return const CaplogEvent(CaplogStatus.started);
      case caplogSubChunk:
        if (!_active) return const CaplogEvent(CaplogStatus.ignored);
        if (frame.length > 2) _buffer.add(frame.sublist(2));
        return const CaplogEvent(CaplogStatus.chunk);
      case caplogSubEnd:
        if (!_active) return const CaplogEvent(CaplogStatus.ignored);
        _active = false;
        final bytes = _buffer.takeBytes();
        final expected = _expected;
        _expected = null;
        if (expected != null && bytes.length != expected) {
          return CaplogEvent(
            CaplogStatus.truncated,
            bytes: bytes,
            expected: expected,
          );
        }
        return CaplogEvent(CaplogStatus.completed, bytes: bytes);
      default:
        return const CaplogEvent(CaplogStatus.ignored);
    }
  }
}

/// Thrown when a caplog download is rejected because another streamed response
/// is already in flight on the device (firmware answers `RESP_CODE_ERR`). (#430)
class CaplogBusyException implements Exception {
  const CaplogBusyException();
  @override
  String toString() =>
      'CaplogBusyException: device busy — another stream is in flight';
}

/// Thrown when the reassembled caplog byte count doesn't match the length the
/// device announced in its START frame. (#430)
class CaplogTruncatedException implements Exception {
  const CaplogTruncatedException({
    required this.received,
    required this.expected,
    this.chunks,
  });
  final int received;
  final int expected;

  /// Number of CHUNK frames the client accumulated before END — a diagnostic to
  /// tell client/transport frame loss apart from the firmware streaming short.
  final int? chunks;

  @override
  String toString() =>
      'CaplogTruncatedException: received $received of $expected bytes'
      '${chunks != null ? ' in $chunks chunks' : ''}';
}
