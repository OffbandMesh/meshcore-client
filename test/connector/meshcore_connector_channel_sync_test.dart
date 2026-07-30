// Channel-sync decision helper (#82).
//
// The firmware answers RESP_CODE_ERR for an empty/invalid channel index. The
// sync must skip that slot the instant the ERR arrives; without this branch it
// waits out the 2s timeout + 3 retries on EVERY empty slot, so a device with a
// few populated channels out of a large capacity takes minutes to sync (~8s per
// empty slot). This pins the decision: advance on ERR only while a channel GET
// is in flight AND no generic-ack command is waiting, a pending generic-ack
// (a SET / channel-text send) is order-correlated to the ERR first.

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';

void main() {
  group('shouldAdvanceChannelSyncOnError', () {
    test('advances when a channel GET is in flight and nothing else awaits the '
        'ERR', () {
      expect(
        MeshCoreConnector.shouldAdvanceChannelSyncOnError(
          isSyncingChannels: true,
          channelSyncInFlight: true,
          hasPendingGenericAck: false,
        ),
        isTrue,
      );
    });

    test('does not advance when not syncing channels', () {
      expect(
        MeshCoreConnector.shouldAdvanceChannelSyncOnError(
          isSyncingChannels: false,
          channelSyncInFlight: true,
          hasPendingGenericAck: false,
        ),
        isFalse,
      );
    });

    test('does not advance when no channel GET is in flight', () {
      expect(
        MeshCoreConnector.shouldAdvanceChannelSyncOnError(
          isSyncingChannels: true,
          channelSyncInFlight: false,
          hasPendingGenericAck: false,
        ),
        isFalse,
      );
    });

    test('a pending generic-ack command owns the ERR first (no channel '
        'advance)', () {
      expect(
        MeshCoreConnector.shouldAdvanceChannelSyncOnError(
          isSyncingChannels: true,
          channelSyncInFlight: true,
          hasPendingGenericAck: true,
        ),
        isFalse,
      );
    });
  });
}
