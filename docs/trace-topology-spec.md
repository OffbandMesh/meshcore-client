# Passive Mesh Topology → Inferred Trace Routes (design spec)

**Status:** proposal / design review (2026-07-05). Owner: Offband. Related: #150 (trace), the RX-fed nearest-repeater work, `meshcore-firmware/docs/trace-path-format.md`.

## 1. The problem we're solving

A MeshCore TRACE only walks a route **the caller hands it**. The firmware never discovers or reverses a route (`trace-path-format.md`), and the reference apps make the user **hand-build** the path (pick nodes from a list, or click them on a map). So multi-hop trace today is either a clunky manual chore or it silently fails. No client discovers the route for you — that's the gap.

**The opportunity:** we *already* parse every received packet's full routing path (for the new RX-fed nearest-repeater detection in `_handleRxData`). That firehose is a **passive map of the mesh**. If we accumulate it into a topology graph, we can **infer** a route to a target we've observed — and auto-suggest it, with a builder to confirm/tweak. The firmware can't discover routes; the *client* can remember what it has already seen. That's the thing no client does.

## 2. Core idea, in one line

Every received packet carries the ordered list of repeaters it crossed. Merge those observations into a graph; to trace node *T*, find a path to *T* on the graph and hand it to the existing round-trip builder.

## 3. What we already have (reuse, don't rebuild)

| Existing | Role in this feature |
|---|---|
| `_handleRxData` → `pathBytes` (per packet) | The observation firehose — the ordered hops a packet crossed. Already parsed; today only adverts are used. |
| `_handlePayloadAdvertReceived`, `_handleLogRxData` | Additional path observations (adverts, channel messages). |
| `DirectRepeater` list (RX-fed) | The **first ring** of the graph — our direct neighbours + their SNR. The only hops we can SNR-rank. |
| `PathHistoryService` | Per-contact observed ACK/flood paths — another observation input; the graph generalises it. |
| `PathHelper.buildTraceRoundTrip(routingPath, targetPrefix, throughTarget, …)` | Assembles the out-and-back frame from a route. Inference output feeds straight into this. |
| `PathSelectionDialog` | The manual route builder — becomes the confirm/edit surface, pre-filled from inference. |

## 4. Path orientation (get this right)

A received flooded/routed packet's `pathBytes` = `[h1, h2, …, hk]`, where the packet travelled `origin → h1 → … → hk → us`. So:
- `hk` (= `pathBytes.last`) is **our direct neighbour** (the last hop before us).
- `h1` is the hop closest to the origin.
- The reversed path `[hk, …, h1]` is a **known route from us toward `origin`**.

Adjacencies contributed by one observation: `us~hk`, `hk~h(k-1)`, …, `h2~h1`, and `h1~origin` when the sender prefix is known.

## 5. Data model — `MeshTopologyService` (new, ChangeNotifier)

Graph, scoped per device key (like the other stores).

```
Node {
  prefix   : Uint8List   // width-byte repeater hash (the key)
  lastSeen : int         // unix seconds, refreshed on every observation
  neighbourSnr : double? // only set for OUR direct neighbours (from RX SNR); null for deep hops
  seenCount : int
  // name is resolved on demand from contacts — NOT stored here
}

Edge {                    // undirected link A~B ("observed adjacent in a path")
  a, b     : Uint8List   // the two endpoints (store canonically ordered)
  lastSeen : int
  count    : int         // observation confidence
  lastFailed : int?      // set when a trace routed through this link timed out (self-healing)
}
```

Sizes (why storage is a non-issue): ~8 B/node, ~12 B/edge. Scales with **mesh size** (distinct repeaters × their links), **not** hop depth or packet volume — each node/link is stored once and merely refreshed. 100 repeaters ≈ 6 KB; 1,000 ≈ 80 KB (≈200 KB as JSON). See §9 for the hard bound.

## 6. Ingestion

On every parsed RX path (from `_handleRxData` and the advert/channel handlers), call:

```
bool observePath(List<int> path, {int width, double? lastHopSnr, Uint8List? senderPrefix, int ts})
```

- Chunk `path` into width-byte hops.
- Upsert a `Node` per hop (refresh `lastSeen`, bump `seenCount`); set `neighbourSnr` on `hk` from `lastHopSnr`.
- Upsert the `us~hk … h1~origin` `Edge`s (refresh `lastSeen`, bump `count`).
- Return `true` only on a **notify-worthy change** (new node/edge, or a materially newer observation) — same notify-on-change discipline as `DirectRepeater.recordHop`.
- Cost: `O(path length)` ≤ 64. The parse already happened; this is a handful of map writes. No new per-packet parsing.

`DirectRepeater.recordHop` and `observePath` can share the same call site — the direct-neighbour list is just the graph's first ring.

## 7. Route inference

```
List<Uint8List>? inferRoute(Uint8List target)   // ordered hops us→…→(excluding target); null if unreachable
```

- Target is a **direct neighbour** → return `[]` (one-hop ping is correct).
- Else run a shortest-path search (BFS by hop count) from `us` to `target` over the **fresh** subgraph (edges within the freshness window §9). Among equal-length routes, prefer: (1) strongest **first-hop** SNR (we can rank the entry neighbour), (2) freshest edges, (3) highest `count`, (4) no recent `lastFailed`.
- Return the intermediate hops `[n1, …, n(m-1)]`. The trace launch then calls `buildTraceRoundTrip(routingPath: that, targetPrefix: target, throughTarget: true)` — existing, tested code.
- `null` when `target` isn't in the fresh graph → manual builder.

**Honest limit:** we measure SNR only for **our own** receptions, i.e. the first hop. Deep-link quality isn't observable from here, so intermediate hops are chosen topologically (shortest + freshest + most-seen), not by signal. That's still far better than a blind guess or a manual build, and the first hop — the one most likely to matter — *is* SNR-optimised.

## 8. Trace UX (replaces the guess)

Repeater / contact **Path Trace**:
1. Committed `contact.path` exists → trace it (today's `hasRoute`).
2. Else `inferRoute(target)`:
   - **Route found** → open the builder **pre-filled** with the suggestion (`Suggested: A → B → target`), one tap to trace or edit first. (Setting: auto-run vs always-confirm.)
   - **No route** → open the **empty** builder with an honest hint: *"No route learned yet — build one, or send it a flood ping / catch an advert to learn it."*
3. **Delete the strongest-repeater guess entirely.** The builder is always the transparent surface; inference just pre-fills it.

## 9. Persistence & bounding (storage is capped by design)

- Persist the **graph** (deduped nodes + edges), never raw paths — raw paths are the only thing that would bloat.
- **Freshness prune:** on load/save, drop nodes/edges whose `lastSeen` is older than `W` (default 7 days; configurable). Keeps the map to the *live* mesh, not all-time.
- **Hard cap:** LRU by `lastSeen` at a fixed ceiling (default ~2,000 nodes / ~256 KB). Physically can't run away, even pathologically.
- Store: `topology_store` keyed by the first 10 hex of the device pubkey, like the others.

## 10. Failure modes & honesty

- **Stale route** (topology moved): the trace just times out like any wrong route; we stamp `lastFailed` on that route's edges so the next inference avoids it. Self-healing over time.
- **Asymmetric / duty-cycled return leg** (firmware `#2`): inference can't fully solve this — a route good outbound may not return. Preferring recently- and frequently-observed links mitigates it; a later refinement can weight bidirectionally-seen links higher.
- **Unobserved target:** never heard, directly or as an intermediate → no inference → manual builder. Expected and honest.

## 11. Why this is the differentiator

The firmware *cannot* discover routes (no flood-trace; empty route = error 1). The reference clients push that cost onto the user (manual build). We turn traffic we're **already parsing** into a route oracle that **improves the longer the app runs** — auto-suggesting routes nobody else can. It degrades gracefully to the same manual builder everyone else has, so we're never worse and usually better.

## 12. Phased build (epic → issues, filed once this design is approved)

| Phase | Deliverable |
|---|---|
| **A — design** | This spec. |
| **B — core** | `MeshTopologyService` (graph, `observePath`, `inferRoute`) + unit tests (orientation, dedup, pathfind, bound). Wire ingestion into `_handleRxData`/advert/channel. No UI. |
| **C — UX** | Trace launch uses `inferRoute` → pre-filled `PathSelectionDialog`; delete the guess. |
| **D — persist + bound** | `topology_store`, freshness prune, LRU cap. |
| **E — polish** | `lastFailed` confidence decay; optional on-map topology overlay; auto-run vs confirm setting. |

Phases B–D are the working feature; A is done; E is gravy.

## 13. Decisions & open questions

**Decided (Ben, 2026-07-05):**
- **Separate services.** `PathHistoryService` stays the message-router weighter; `MeshTopologyService` is a distinct trace oracle that *reads* PathHistory's observations as one input — no merge.
- **Confirm-first.** An inferred route **pre-fills the builder** and the user confirms/edits before it traces (transparent). Auto-run is a later opt-in setting, not the default.

**Still open (tuning, not blocking):**
- **Freshness window `W`** — 7 days is a starting guess; tune against real advert/traffic cadence (repeaters now advert ~12 h).
