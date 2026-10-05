# PLAN: contact naming, and what a name does not prove

| | |
|---|---|
| **Covers** | [#750](https://github.com/OffbandMesh/meshcore-client/issues/750) Epic · Citadel `meshcore-open-b5l` · [#751](https://github.com/OffbandMesh/meshcore-client/issues/751) docs · Citadel `meshcore-open-le5` |
| **Serves** | Feature [#609](https://github.com/OffbandMesh/meshcore-client/issues/609) Contacts. #609 has **no** plan of record; this plan covers the naming slice only and does not retroactively cover its delivered epics (#610, #611, #619). |
| **Status** | Draft. Approved when this PR merges. |
| **Owner** | @Strycher |
| **Agent** | HazyCove (session db2d6bf0) |
| **Last updated** | 2026-10-01 |

## At a glance

When this is done you can give any contact a name of your own, the way stock MeshCore's CUSTOM NAME field works, and it sticks. Adverts keep correcting what the node calls itself underneath, so accuracy improves without your label ever moving. Where the two differ, you can see both.

And the thing a client cannot fix is written down plainly instead of implied: a display name on the mesh is not unique, not owned, and not proof of who you are talking to. The key is the identity. The docs, the release notes and one short line in the app say so, and say what to check instead.

## 1. Diagnosis

| # | Finding | Evidence | Effect |
|---|---|---|---|
| 1 | Offband cannot rename a contact at all | No name field in `contact_settings_dialog.dart`; no contact edit screen; `git log -S renameContact -- lib/` returns nothing | Stock-parity gap. Stock has CUSTOM NAME per node |
| 2 | Firmware cannot hold a per-contact custom name | `ContactInfo.h:10` is a single `char name[32]`. `IdentityStore`'s `display_name` is the **device's own** name, not a per-contact override. No custom-name concept anywhere in firmware | A custom name is necessarily client-side, matching the owner's read that stock keeps the original underneath |
| 3 | An inbound advert overwrites the stored name | `meshcore_connector.dart:9122` → `name: hasName ? name : existing.name` | Accuracy is good, but the client can never hold a name the user chose; the next advert takes it back |
| 4 | An advertised name **is** cryptographically bound to the key | Firmware signs `pub_key‖timestamp‖app_data` and rejects a forged signature outright: `meshcore-firmware/src/Mesh.cpp:279-287` | Only the private-key holder can advertise a name for that key |
| 5 | A contact-card name is bound to **nothing** | `<key:type:name>` is plain unsigned channel text (#610) | Anyone can pair any name with any key they do not own. This is #645 |
| 6 | Display names are not unique and cannot be made so | No registry exists. Setting your own radio's name to another operator's name produces correctly signed, legitimate traffic | Unpreventable. A property to document, not a defect to fix. See §6 |
| 7 | Renames do not propagate | Adverts are not immediate and may never come (owner, 2026-10-01) | Everyone else keeps a stale name indefinitely, with no way to correct it locally |
| 8 | The name surface is read-heavy and write-light | **85** display reads of a contact name in `lib/`; **11** `Contact(...)` constructions passing `name:`; **6** `copyWith(... name: ...)`; **5** `buildUpdateContactPathFrame` call sites | Decides the architecture, §2. A loose grep suggested 114 constructions; the measured figure is 11, and planning on 114 would have mis-sized this epic |
| 9 | Per-contact settings already have a home | `contact_settings_store.dart` keys by pubkey hex (`contact_cyr2lat_<keyHex>`) | New prefix, proven pattern, no new storage design |
| 10 | The unverified state is already rendered | #630's badge separates `advertVerified` from `keyOnly` (`contact_verification_badge.dart:50-57`) | This epic gives that badge real data instead of inferring from `lastSeen` |
| 11 | `resolveContactsByName` already exists | `meshcore_connector.dart:1228`, built for #468; returns every identity behind a claimed name and never picks a winner | Reusable for #645's collision check, with a cost constraint. See §5 |

## 2. Architecture

The decision is driven by finding 8: **85 reads, 22 writes.** Protect the many, make the few explicit.

### Decisions

| Decision | Why |
|---|---|
| `Contact.name` becomes a **getter**: `customName ?? receivedName` | All 85 display reads stay correct and untouched. A future read site cannot forget, because reading `.name` is already right |
| The received name is called **`receivedName`**, not `advertName` | Writing the test matrix caught this. A contact-card name is **not** advertised (finding 5), so calling the field `advertName` would make it lie for every card-added contact, and #645's honest signal would be built on a false premise |
| "Is this name key-bound?" is answered by the **existing** `isAdvertVerified` | `contact.dart:270` already derives it from `lastSeen`, and #630 already renders it. No third field, no new concept, and the provenance question stays in one place |
| The constructor and `copyWith` take **`receivedName`**, not `name` | Renaming the write parameter turns all 11 constructions and 6 `copyWith` calls into **compile errors**. The compiler enumerates them; nothing is missed silently |
| `customName` lives on `Contact` and persists in `contact_settings_store` | Survives `copyWith`, so no re-application is needed at the four radio-sync points (6672, 6690, 6780, 6791) |
| An empty or whitespace-only custom name counts as **unset** | Otherwise a user who clears the field by deleting its text gets a blank display name with no way back |
| The **radio always receives `receivedName`** | The radio's contact table is the shared record of what a node calls itself. The client holds the user's label. §3 Task 2 covers this, because it is the one hole the compiler cannot see |
| The custom name is **never** sent to the radio | Finding 2: there is nowhere to put it, and writing it would corrupt the shared record |

### Alternatives considered but not chosen

- **Add `displayName` and migrate the 85 read sites.** Rejected: the failure mode is silent and permanent. A missed site, or any future site that reaches for `.name`, shows the advertised name instead of the user's and nothing complains.
- **Resolve the custom name at render time from a connector map, leaving `Contact` untouched.** Rejected: it still needs all 85 reads to call the resolver, so it has the silent-failure problem plus a second lookup path.
- **Store the custom name on the radio.** Not possible, finding 2.

### The one hole, named

The 5 `buildUpdateContactPathFrame` call sites read `.name` today. Under the chosen design `.name` still compiles there, so the compiler will **not** flag them, and a miss would write the user's private label into the radio's contact table. They are: `meshcore_connector.dart` 4048, 4114, 4531, 4562, and `stock_config_import_service.dart:303`. Task 2 changes all five and adds a test that fails if a frame is built with a custom name, so the hole is closed by a test rather than by care.

## 3. Epic #750: tasks

| Task | What | Pts |
|---|---|---|
| **750.1 · Model and storage** | `receivedName` (required) + `customName` (nullable) on `Contact`; `name` becomes the getter; constructor and `copyWith` renamed; `contact_store` migration reads a legacy `name` into `receivedName`; `contact_settings_store` persists `customName` by pubkey hex. Tests T1 to T9 and T31 | 4 |
| **750.2 · Radio boundary** | All 5 `buildUpdateContactPathFrame` sites send `receivedName`. Tests T10 to T14, including the source guard | 3 |
| **750.3 · Advert path** | `meshcore_connector.dart:9122` writes `receivedName` always; the display name follows from the getter with no extra branch. Tests T15 to T22 | 3 |
| **750.4 · Contacts UI** | Set, edit and clear a custom name from the contacts screen; show the received name wherever it differs, so the user can see what the node calls itself. New l10n strings in `app_en.arb`. Tests T23 to T30 | 3 |
| **750.5 · Epic verification** | Owner, on hardware, Windows and Android. §7 | 1 |

**Not in this epic:** #645's collision warning and the verify-the-key advisory. #645 is already blocked-by #750 and lands after, because the check must match the display name and the advisory should reference real advertised-name data.

## 4. Automated tests

Every behaviour below gets a **positive** test (it does the right thing) and a **negative** test (it does not do the wrong thing). The negatives are the ones that catch a future regression, because a positive test keeps passing while a new code path quietly breaks the guarantee next to it. Nothing in this epic is done on positives alone.

All of these run in CI through the existing `analyze` job (`flutter test`), so a regression fails the build rather than waiting for someone to notice.

### 750.1 Model and storage · `test/models/contact_naming_test.dart`, `test/storage/contact_settings_store_test.dart`

| # | +/- | Test |
|---|---|---|
| T1 | **+** | `name` returns `customName` when one is set |
| T2 | **-** | `name` returns `receivedName` when `customName` is null, and the custom name does not leak in |
| T3 | **-** | An empty-string `customName` is treated as unset, so `name` falls back rather than returning `""` |
| T4 | **-** | A whitespace-only `customName` is treated as unset, same reason |
| T5 | **+** | `copyWith(receivedName:)` changes the received name and leaves `customName` intact |
| T6 | **-** | `copyWith(receivedName:)` does not change what `name` returns while a custom name is set |
| T7 | **+** | A legacy stored contact with only a `name` key migrates into `receivedName` |
| T8 | **-** | That migration leaves `customName` **null**. If it populated it, every existing contact would silently become "renamed" and adverts would stop updating any of them |
| T9 | **+/-** | Custom name round-trips through `contact_settings_store`; clearing removes it; a load for an unknown pubkey returns **null**, not `""`, and does not throw |

### 750.2 Radio boundary · `test/connector/contact_frame_naming_test.dart`

| # | +/- | Test |
|---|---|---|
| T10 | **+** | With a custom name set, `buildUpdateContactPathFrame` carries the **received** name |
| T11 | **-** | The built frame bytes do not contain the custom name anywhere. This is the test that stops a private label reaching the shared contact table |
| T12 | **+** | With no custom name, the frame is byte-identical to today's, so this change is behaviour-neutral for every existing path |
| T13 | **+** | `addContactByKey` on a card stub still sends the card's name, since a stub's received name is the card name |
| T14 | **-** | **Source guard:** exactly 5 `buildUpdateContactPathFrame` call sites exist and none passes `.name`. The test reads the source and fails if a sixth appears or an existing one regresses. The compiler cannot see this hole (§2), so a test holds it |

### 750.3 Advert path · `test/connector/advert_name_update_test.dart`

| # | +/- | Test |
|---|---|---|
| T15 | **+** | An advert carrying a name updates `receivedName` |
| T16 | **-** | That same advert does not change what `name` returns while a custom name is set. This is the whole point of the epic |
| T17 | **+** | Clearing the custom name afterwards reveals the newly advertised name, not the stale one |
| T18 | **-** | An advert with no name (`hasName` false) does not null or clobber `receivedName` |
| T19 | **-** | An advert does not write, alter or clear `customName` by any path |
| T20 | **+** | A card-added contact with no advert yet reports `isAdvertVerified == false` and displays the card's name |
| T21 | **-** | That contact is not reported verified, so #630's badge cannot show green on an unsigned name |
| T22 | **+** | A node renamed on its own radio whose advert never arrived still displays the user's custom name, and the stale received name remains available to show beside it |

### 750.4 Contacts UI · `test/screens/contact_rename_test.dart`

| # | +/- | Test |
|---|---|---|
| T23 | **+** | Setting a custom name updates the contact tile |
| T24 | **+** | Clearing it restores the received name in the tile |
| T25 | **+** | Where the two differ, both are visible, so the user can see what the node calls itself |
| T26 | **-** | Where they are the same, the received name is not shown twice |
| T27 | **+/-** | Error surfacing, per the owner's standing requirement: the over-length message appears when the field exceeds the UI maximum, and is **absent** when the input is valid |
| T28 | **-** | A custom name containing CJK, emoji or a ZWJ sequence is stored and displayed intact. It never crosses the wire, so #636's grapheme truncation must not be applied to it |
| T29 | **-** | Saving the dialog with an **empty** field writes `null` to the store, not `""`. Without this the display looks right (T3 makes the getter fall back) while the stored data is wrong, and the dialog can never truly unset a name through its primary save action |
| T30 | **-** | Saving the dialog with a **whitespace-only** field does the same |

T29 and T30 come from the pre-PR adversarial review. T3 and T4 prove the *getter* tolerates an empty custom name; nothing proved the *UI* never writes one, and a clear button passing (T24) would have masked a broken save path.

### 750.1 addendum: the fallback the rename could drop

| # | +/- | Test |
|---|---|---|
| T31 | **-** | A legacy stored contact whose `name` key is **missing or null** migrates to `receivedName == 'Unknown'`, preserving the existing fallback at `contact_store.dart:145` (`json['name'] as String? ?? 'Unknown'`) |

The review raised this as a crash risk. That premise is wrong: the fallback already exists and predates this epic, so there is no crash and no data-loss path. The real risk is narrower and worth a test anyway. Moving the deserializer from `name:` to `receivedName:` is exactly the kind of edit that drops a trailing `?? 'Unknown'` without anyone noticing, and the result would be a crash on load for any user holding such a row. T31 pins it.

### Regression guarantee

T8, T11, T14, T16, T19, T21, T29, T30 and T31 exist purely to fail if someone later breaks a guarantee this epic makes. They assert **absence**, which is what a regression actually looks like. T14 is the only source-reading test, and it is deliberate: it guards the one hole the type system cannot see.

## 5. `resolveContactsByName`, and its cost

It matches on `c.name`. Under the chosen design that keeps meaning **what the user reads**, which is the string any deception operates on, so #645's collision check needs **no resolver change**. Under the rejected `displayName` design it would have silently matched the advertised name instead. That is a second reason the chosen design wins.

**[hypothesis: cost model read from the code, not measured. 750.1 measures it before 750.4 ships.]**

It spreads `contacts` + `discoveredContacts` (both getters allocate a fresh list) and calls `trim().toLowerCase()` per element, allocating a string each. At the owner's reported scale of roughly 350 contacts (#188) plus discovered nodes, that is on the order of 700 allocations per call.

| Call site | Frequency | Verdict |
|---|---|---|
| A dialog, on open | Once per user action | Fine. Sub-millisecond, invisible |
| Any list-rendered widget via `context.select` | Re-runs on **every** `notifyListeners()`; the connector notifies on every received packet | Not acceptable. 700 allocations × visible widgets × notifications per second |

So any name-collision check belongs in a **dialog**, never in a tile or chip. `add_contact_by_key_dialog.dart:132` already holds the connector, so this needs no connector change and stays clear of the contact-sync work in P0 #660 / #668. A list-level signal would need a maintained `Map<String, Set<String>>` index keyed by lowercased display name, not a per-build scan; out of scope here, to be filed when a design calls for it.

## 6. #751: documenting what cannot be fixed

Finding 6 is permanent. The client's obligation is to stop presenting a name as an identity and to make the key reachable at the moment of decision. It is not to prevent collisions, which it cannot.

Owner, 2026-10-01: *"Without an official registry enforcing globally unique display names, this is an unpreventable consequence."*

| Surface | Content |
|---|---|
| `CHANGELOG.md` | Short entry, user-facing voice, under the release that ships it |
| Release notes | The same text, so it reaches people who never open the repo |
| Docs site (`OffbandMesh/offband-site`) | The full explanation: why names are not unique, what a signature does and does not prove, how to confirm a key out of band once, what the #630 badge states mean |
| In-app | One short advisory at the point a contact is added, as an l10n string. Placement rides with 750.4, since the honest wording references the advertised name |

**Wording constraints, binding:**

- Do **not** call this an attack or a vulnerability. It is how a registry-free mesh behaves. Overstating it is the same dishonesty as hiding it, and reads as alarmism to operators who already know.
- Do **not** imply Offband is weaker than stock. Stock has no name-key binding either; the verification badge is something Offband adds.
- Lead with what the user should **do**, which is confirm a key out of band with the person once, not with what could go wrong.
- No em-dashes.
- The docs-site page is public, so the draft is reviewed before it is published.

## 7. Verification

**750.5, owner, on hardware, Windows and Android:**

1. Rename a contact. The new name shows everywhere that contact appears.
2. Let that contact advert. The name does **not** change back.
3. Clear the custom name. The advertised name returns.
4. Add a contact from a card, with no advert yet. It reads unverified, and shows the card's name.
5. Let that contact advert. It becomes verified, and the advertised name is now visible as distinct from any custom name set.
6. A contact renamed on its own radio, whose advert has not reached you, still shows your name, and shows the stale advertised name where the two differ.

**Automated, in CI:** the full T1 to T31 matrix in §4, positives and negatives, including the radio-boundary source guard T14.

**#751:** the owner reads the docs-site draft before it is published. The in-app string is checked in 750.5 step 4.

## 8. What the owner has to do

One step, at the end: run the Windows build and the Android build and walk §7. Everything else, including the T1 to T31 matrix and the measurement in §5, is run by the session and brought to him as evidence.

## 9. Risks

| Risk | Handling |
|---|---|
| A custom name reaches the radio and corrupts the shared record | §2 "the one hole". Five named sites, changed in 750.2, closed by a test, not by care |
| `meshcore_connector.dart` is OrangeDog's file for P0 #660 / #668 | 750.1 and 750.3 touch it. Announce on Agent Mail before starting, and carry the rebase rather than asking anyone to work around it |
| A `contact_store` migration loses names | Nullable, additive migration: a legacy `name` is read into `receivedName`, `customName` starts null. T7 and T8 cover both halves, and T8 is the negative that catches the worse failure: a migration that populated `customName` would silently mark every existing contact as renamed and stop adverts updating any of them. Data safety is not optional |
| The docs wording overstates the risk | §6 constraints, and the owner reviews the public draft |

```grant-terms
{
  "epic_chain": [750],
  "chain": true,
  "verification": { "mode": "owner" },
  "merge": { "budget": 2, "basis": "One PR for Epic #750 (tasks 750.1-750.5, one branch, merged after owner verification), and one PR for the #751 documentation. The docs-site page merges in OffbandMesh/offband-site, outside this grant." },
  "flash": null,
  "reset": null,
  "expires_after_hours": 168
}
```

---
*Agent: HazyCove (session db2d6bf0).*
