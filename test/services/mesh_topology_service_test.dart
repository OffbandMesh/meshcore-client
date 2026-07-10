import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/services/mesh_topology_service.dart';

/// #186 Phase B — the passive-topology route oracle.
/// Path orientation used throughout: a received path is `origin → h1 → … → hk → us`,
/// so `hk` (the path's LAST hop) is our direct neighbour.
void main() {
  // 2-byte path-hash width fixtures.
  const self = [0x00, 0x01];
  const r1 = [0x11, 0x11];
  const r2 = [0x22, 0x22];
  const r3 = [0x33, 0x33];
  const t = [0xCC, 0xCC]; // target — only ever seen relaying
  const u = [0x99, 0x99]; // never observed

  List<int> path(List<List<int>> hops) => hops.expand((h) => h).toList();
  List<List<int>>? asLists(List<dynamic>? r) =>
      r?.map((u) => (u as List).cast<int>()).toList();

  MeshTopologyService svc({int? maxNodes}) {
    final s = MeshTopologyService(maxNodes: maxNodes);
    s.setSelf(self, 2);
    return s;
  }

  group('observePath — orientation + graph growth', () {
    test('last hop is our neighbour (SNR); mids are relays (no SNR)', () {
      final s = svc();
      // packet: origin → R2 → T → R1 → us   (R1 = neighbour, T relayed)
      final changed = s.observePath(
        path([r2, t, r1]),
        width: 2,
        lastHopSnr: 6.5,
      );
      expect(changed, isTrue);
      expect(s.nodeCount, 4); // self, R2, T, R1
      expect(s.edgeCount, 3); // R2~T, T~R1, self~R1
      expect(s.neighbourSnrOf(r1), 6.5); // last hop = measured neighbour
      expect(s.neighbourSnrOf(t), isNull); // relayed — no measurable SNR
      expect(s.neighbourSnrOf(r2), isNull);
    });

    test('re-observing the same path is a silent refresh (no growth)', () {
      final s = svc();
      s.observePath(path([r2, t, r1]), width: 2);
      final n = s.nodeCount, e = s.edgeCount;
      final changed = s.observePath(path([r2, t, r1]), width: 2);
      expect(changed, isFalse);
      expect(s.nodeCount, n);
      expect(s.edgeCount, e);
    });
  });

  group('inferRoute', () {
    test('direct neighbour → empty route (one-hop ping is correct)', () {
      final s = svc();
      s.observePath(path([r1]), width: 2); // us ~ R1
      expect(asLists(s.inferRoute(r1)), isEmpty);
    });

    test('KEY: routes to a node only ever heard RELAYING', () {
      final s = svc();
      // T never arrives as a last hop — only mid-path — yet we can reach it.
      s.observePath(path([r2, t, r1]), width: 2); // origin→R2→T→R1→us
      expect(s.neighbourSnrOf(t), isNull); // proof T was never our neighbour
      // us → R1 → T
      expect(asLists(s.inferRoute(t)), [r1]);
    });

    test('unobserved target → null (→ manual builder)', () {
      final s = svc();
      s.observePath(path([r2, t, r1]), width: 2);
      expect(s.inferRoute(u), isNull);
    });

    test('picks the shorter of two known routes', () {
      final s = svc();
      s.observePath(path([t, r1]), width: 2); // us→R1→T   (2 hops)
      s.observePath(path([t, r3, r2]), width: 2); // us→R2→R3→T (3 hops)
      expect(asLists(s.inferRoute(t)), [r1]);
    });
  });

  group('freshness + bounds', () {
    test('a stale-only route is not inferred', () {
      const now = 1000000000;
      const eightDays = 8 * 24 * 3600;
      final s = svc();
      s.observePath(path([t, r1]), width: 2, ts: now - eightDays); // stale
      expect(s.inferRoute(t, nowTs: now), isNull); // stale link excluded
      // a fresh observation of the same link makes it routable again
      s.observePath(path([t, r1]), width: 2, ts: now);
      expect(asLists(s.inferRoute(t, nowTs: now)), [r1]);
    });

    test('node count is hard-capped (oldest evicted)', () {
      final s = svc(maxNodes: 3);
      s.observePath(path([r1]), width: 2, ts: 100); // self, R1
      s.observePath(path([r2]), width: 2, ts: 200); // + R2  → 3
      s.observePath(path([r3]), width: 2, ts: 300); // + R3  → 4 → evict oldest
      expect(s.nodeCount, 3);
      expect(s.hasNode(r1), isFalse); // R1 was the oldest
      expect(s.hasNode(r3), isTrue);
    });

    test('pruneStale drops nodes past the freshness window', () {
      const now = 1000000000;
      final s = svc();
      s.observePath(path([r2, t, r1]), width: 2, ts: now - 8 * 24 * 3600);
      expect(s.nodeCount, greaterThan(0));
      s.pruneStale(now);
      expect(s.nodeCount, 0);
    });
  });
}
