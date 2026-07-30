import 'dart:collection';

import 'package:flutter/foundation.dart';

/// A node (repeater/relay) in the passively-observed mesh topology, keyed by its
/// width-byte path-hash prefix. (#186 Phase B, see docs/trace-topology-spec.md)
class TopoNode {
  final Uint8List prefix;
  int lastSeen; // unix seconds
  /// Set ONLY for our own direct neighbours (the last hop of a packet we heard),
  /// where we actually measured the reception SNR. Null for deeper hops, whose
  /// link quality we can't observe from here.
  double? neighbourSnr;
  int seenCount;

  TopoNode({
    required this.prefix,
    required this.lastSeen,
    this.neighbourSnr,
    this.seenCount = 1,
  });
}

/// An undirected observed adjacency between two nodes ("seen consecutive in a
/// packet's path"). Stored once, canonically keyed.
class TopoEdge {
  final Uint8List a;
  final Uint8List b;
  int lastSeen;
  int count;

  /// Set when a trace routed over this link timed out, inference deprioritises
  /// it so the graph self-heals as topology drifts.
  int? lastFailed;

  TopoEdge({
    required this.a,
    required this.b,
    required this.lastSeen,
    this.count = 1,
    this.lastFailed,
  });
}

/// Accumulates the routing paths of received packets into a topology graph and
/// infers trace routes from it, the thing the firmware can't do (it only walks
/// a caller-supplied route) and the reference apps push onto the user (manual
/// build). Deliberately SEPARATE from PathHistoryService (Ben, 2026-07-05):
/// PathHistory weights message routing; this is the trace oracle.
///
/// Storage is bounded by design: the graph is deduplicated (a node/edge stored
/// once, refreshed), pruned by freshness, and hard-capped by node count, so it
/// scales with mesh size, not hop depth or packet volume. (#186)
class MeshTopologyService extends ChangeNotifier {
  static const int defaultFreshnessSeconds = 7 * 24 * 3600; // 7 days
  static const int defaultMaxNodes = 2000;

  final int freshnessSeconds;
  final int maxNodes;
  final int Function() _now;

  final Map<String, TopoNode> _nodes = {};
  final Map<String, TopoEdge> _edges = {};
  final Map<String, Set<String>> _adj = {}; // nodeHex -> neighbour nodeHex set

  Uint8List? _self; // our own node prefix (width bytes)

  MeshTopologyService({
    int? freshnessSeconds,
    int? maxNodes,
    int Function()? now,
  }) : freshnessSeconds = freshnessSeconds ?? defaultFreshnessSeconds,
       maxNodes = maxNodes ?? defaultMaxNodes,
       _now = now ?? _defaultNow;

  static int _defaultNow() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  int get nodeCount => _nodes.length;
  int get edgeCount => _edges.length;

  /// Our own node prefix (the BFS origin), or null until the first RX set it.
  Uint8List? get self => _self;

  /// The service's clock in unix seconds, so a debug/inspection UI computes
  /// last-heard ages against the same clock the graph is stamped with.
  int get clockSeconds => _now();

  /// Read-only snapshot of learned nodes, for debug/inspection UIs only.
  List<TopoNode> get nodes => List.unmodifiable(_nodes.values);

  /// Read-only snapshot of observed edges, for debug/inspection UIs only.
  List<TopoEdge> get edges => List.unmodifiable(_edges.values);

  bool hasNode(List<int> prefix) => _nodes.containsKey(_hex(prefix));

  /// The measured reception SNR for a node, set only when it was our direct
  /// neighbour (the last hop of a packet we heard); null for deeper hops.
  double? neighbourSnrOf(List<int> prefix) =>
      _nodes[_hex(prefix)]?.neighbourSnr;

  /// Our own node prefix, the BFS origin for inference and the anchor for the
  /// `us ~ direct-neighbour` edges.
  void setSelf(List<int> prefix, int width) {
    final w = width < 1 ? 1 : width;
    _self = Uint8List.fromList(
      prefix.sublist(0, w > prefix.length ? prefix.length : w),
    );
  }

  static String _hex(List<int> b) =>
      b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

  static String _edgeKey(String x, String y) =>
      x.compareTo(y) <= 0 ? '$x|$y' : '$y|$x';

  /// Ingests one received packet's routing path (as received:
  /// `origin → h1 → … → hk → us`, so `hk` = `path`'s last hop = our direct
  /// neighbour). [lastHopSnr] is the SNR of our reception (attributed to `hk`).
  /// Returns true on a notify-worthy STRUCTURAL change (new node/edge). Cheap:
  /// O(path length ≤ 64) map writes, the path was already parsed upstream.
  bool observePath(
    List<int> path, {
    required int width,
    double? lastHopSnr,
    int? ts,
  }) {
    final w = width < 1 ? 1 : width;
    if (path.length < w) return false;
    final now = ts ?? _now();

    final hops = <Uint8List>[];
    for (var i = 0; i + w <= path.length; i += w) {
      hops.add(Uint8List.fromList(path.sublist(i, i + w)));
    }
    if (hops.isEmpty) return false;

    var changed = false;
    for (var i = 0; i < hops.length; i++) {
      final isLastHop = i == hops.length - 1; // our direct neighbour
      changed |= _upsertNode(hops[i], now, isLastHop ? lastHopSnr : null);
    }
    for (var i = 0; i + 1 < hops.length; i++) {
      changed |= _upsertEdge(hops[i], hops[i + 1], now);
    }
    final self = _self;
    if (self != null && self.length >= w) {
      changed |= _upsertNode(self, now, null);
      changed |= _upsertEdge(self, hops.last, now); // us ~ last hop
    }

    _enforceCap();
    if (changed) notifyListeners();
    return changed;
  }

  bool _upsertNode(Uint8List prefix, int now, double? neighbourSnr) {
    final k = _hex(prefix);
    final existing = _nodes[k];
    if (existing == null) {
      _nodes[k] = TopoNode(
        prefix: Uint8List.fromList(prefix),
        lastSeen: now,
        neighbourSnr: neighbourSnr,
      );
      _adj.putIfAbsent(k, () => <String>{});
      return true; // structural growth
    }
    existing.lastSeen = now;
    existing.seenCount++;
    if (neighbourSnr != null) existing.neighbourSnr = neighbourSnr;
    return false; // refresh only
  }

  bool _upsertEdge(Uint8List a, Uint8List b, int now) {
    final ha = _hex(a);
    final hb = _hex(b);
    if (ha == hb) return false; // no self-loops
    final k = _edgeKey(ha, hb);
    final existing = _edges[k];
    if (existing == null) {
      _edges[k] = TopoEdge(
        a: Uint8List.fromList(a),
        b: Uint8List.fromList(b),
        lastSeen: now,
      );
      _adj.putIfAbsent(ha, () => <String>{}).add(hb);
      _adj.putIfAbsent(hb, () => <String>{}).add(ha);
      return true;
    }
    existing.lastSeen = now;
    existing.count++;
    return false;
  }

  /// The ordered intermediate hops from us to [target], EXCLUDING both us and
  /// the target, feed straight into
  /// `PathHelper.buildTraceRoundTrip(routingPath: result, targetPrefix: target)`.
  ///
  /// - `[]`   → target is a direct neighbour (a one-hop ping is correct).
  /// - `null` → target isn't reachable in the FRESH graph (→ manual builder).
  ///
  /// Shortest hop count over edges within the freshness window, biased at each
  /// step toward stronger first-hop SNR / fresher / more-seen links. (Phase B
  /// uses ordered-BFS; a weighted search is a later refinement.)
  List<Uint8List>? inferRoute(List<int> target, {int? nowTs}) {
    final self = _self;
    if (self == null) return null;
    final now = nowTs ?? _now();
    final selfHex = _hex(self);
    final targetHex = _hex(target);
    if (targetHex == selfHex) return <Uint8List>[];
    if (!_nodes.containsKey(targetHex)) return null; // never observed

    final visited = <String>{selfHex};
    final parent = <String, String>{};
    final queue = Queue<String>()..add(selfHex);
    while (queue.isNotEmpty) {
      final cur = queue.removeFirst();
      if (cur == targetHex) break;
      for (final nb in _freshNeighbours(cur, now, selfHex)) {
        if (visited.add(nb)) {
          parent[nb] = cur;
          queue.add(nb);
        }
      }
    }
    if (!visited.contains(targetHex)) return null;

    final chain = <String>[];
    var node = targetHex;
    while (node != selfHex) {
      chain.add(node);
      final p = parent[node];
      if (p == null) return null;
      node = p;
    }
    // chain = [target, …, n1]; reverse and drop self(implicit)+target ends.
    final ordered = chain.reversed.toList(); // [n1, …, target]
    if (ordered.isEmpty) return <Uint8List>[];
    final intermediates = ordered.sublist(0, ordered.length - 1); // drop target
    return intermediates.map((h) => _nodes[h]!.prefix).toList();
  }

  List<String> _freshNeighbours(String nodeHex, int now, String selfHex) {
    final adj = _adj[nodeHex];
    if (adj == null || adj.isEmpty) return const [];
    final out = <String>[];
    for (final nb in adj) {
      final e = _edges[_edgeKey(nodeHex, nb)];
      if (e == null) continue;
      if (now - e.lastSeen > freshnessSeconds) continue; // stale link
      out.add(nb);
    }
    final isSelfRing = nodeHex == selfHex;
    out.sort((x, y) {
      if (isSelfRing) {
        final sx = _nodes[x]?.neighbourSnr ?? -1e9;
        final sy = _nodes[y]?.neighbourSnr ?? -1e9;
        if (sx != sy) return sy.compareTo(sx); // stronger first hop first
      }
      final ex = _edges[_edgeKey(nodeHex, x)]!;
      final ey = _edges[_edgeKey(nodeHex, y)]!;
      // Deprioritise links a trace recently failed over, so inference self-heals
      // as topology drifts; failures decay out of the freshness window. (#186)
      final fx =
          (ex.lastFailed != null && now - ex.lastFailed! < freshnessSeconds)
          ? 1
          : 0;
      final fy =
          (ey.lastFailed != null && now - ey.lastFailed! < freshnessSeconds)
          ? 1
          : 0;
      if (fx != fy) return fx.compareTo(fy);
      final byFresh = ey.lastSeen.compareTo(ex.lastSeen);
      if (byFresh != 0) return byFresh;
      return ey.count.compareTo(ex.count);
    });
    return out;
  }

  /// Flags every link on a failed route so inference deprioritises it next time.
  void markRouteFailed(List<List<int>> hopChain, {int? ts}) {
    final now = ts ?? _now();
    for (var i = 0; i + 1 < hopChain.length; i++) {
      final e = _edges[_edgeKey(_hex(hopChain[i]), _hex(hopChain[i + 1]))];
      if (e != null) e.lastFailed = now;
    }
  }

  /// Drops nodes/edges not heard within the freshness window, for persistence
  /// bounds (Phase D). Inference already ignores stale links at query time.
  void pruneStale([int? nowTs]) {
    final now = nowTs ?? _now();
    final dead = _nodes.entries
        .where((e) => now - e.value.lastSeen > freshnessSeconds)
        .map((e) => e.key)
        .toList();
    for (final k in dead) {
      _removeNode(k);
    }
  }

  void _enforceCap() {
    if (_nodes.length <= maxNodes) return;
    final byAge = _nodes.entries.toList()
      ..sort((a, b) => a.value.lastSeen.compareTo(b.value.lastSeen));
    final removeCount = _nodes.length - maxNodes;
    for (var i = 0; i < removeCount; i++) {
      _removeNode(byAge[i].key);
    }
  }

  void _removeNode(String hex) {
    _nodes.remove(hex);
    final adj = _adj.remove(hex);
    if (adj != null) {
      for (final nb in adj) {
        _adj[nb]?.remove(hex);
        _edges.remove(_edgeKey(hex, nb));
      }
    }
  }
}
