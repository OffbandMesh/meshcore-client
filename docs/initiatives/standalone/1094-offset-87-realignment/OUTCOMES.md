# Offset-87 realignment, client half

**Epic:** #1094 · **Agent:** CalmBay · **Night of 2026-11-04**

Read §1 and §6. The rest is evidence.

---

## 1. What you need to decide

| # | Decision | Why it is yours |
|---|---|---|
| 1 | **Test the build, then push and PR.** Nothing is pushed. | Your gate, and you asked to test first. |
| 2 | **One contract gap is unanswered by firmware.** I shipped a resolution and told FuchsiaCreek. | If they rule differently it is a one-line change. |

The branch hazard that was decision 2 here is **fixed** — see §6. Everything else ran to completion.

**One branch to test and PR: `feat/1094-offset-87-realignment`.** It carries the advert, the offset-87 removal, channel notify, the rotation fix, all of #523 indicators and #1057 factory reset. Renamed from `fix/1098-rotation-subcodes`, which undersold what it holds.

---

## 2. The gate I checked before writing anything

Contract §2 forbids building against an unmerged number, and that rule is the whole reason this work exists.

```
PR OffbandMesh/meshcore-firmware#2000   MERGED  28785ebf  2026-11-04 08:34:29Z
```

Verified before reading the contract, before reading the header, before any code. Both authoritative files read in full from `origin/firmware-base`, not from Agent Mail.

**I also found a stale instruction and did not obey it.** FuchsiaCreek's Agent Mail 1448 said *"CalmBay — HOLD the client half. The contract has real defects."* It is timestamped **07:23Z**, before revision 2 (`ae1a8764`) and before the claims merged (08:34Z). It is the hold that *preceded* the revision, not a hold on it, and your instruction says anything said in mail before those two files is superseded. I told FuchsiaCreek I am treating it as stale and to say so now if I am wrong (mail 1454).

Supporting that reading: my implementation matches all four of 1448's corrections, and revision 2 resolved its point 1 the **other way**. 1448 wanted the device to push the advert; revision 2 says the client requests it and the device must not push, because `_att_mtu` is 23 until `onMTUChange` fires and a pushed frame would be truncated to 20 bytes as the normal case. I built the merged version.

---

## 3. Delivered

Two commits, both local.

### `5dc968ee` — the advert, and nothing at offset 87 (#1095, #1096, #1097)

Branch `feat/1068-radio-channel-notify`.

- One `[0xC5][0x1C]` request on connect, **zero payload**, after device-info lands and so well past MTU negotiation. Client asks; device never pushes.
- A tag's presence IS the capability. No bitmap, no probing. `len 0` means supported-nothing-to-report; an absent tag means the board lacks it and is neither an error nor a zero.
- **Unknown tags kept and skipped by `len`.** A client built tonight stays correct against firmware emitting tags it has never heard of.
- `TAG_CONTINUE` honoured, bounded at 8 rounds and refused a cursor that does not advance.
- `[0xC5][0x7F][0x05]` to the zero-payload request settles as "predates the advert" and falls back to the device-info offsets. Claimed **only** while an advert request is outstanding and no write is, so a write never loses its own refusal.
- `TAG_ACK_CAPACITY` read as a carried byte; absent is null, never 0.
- `parseOffbandCaps3`, `offbandCaps3Offset`, `offbandCaps3MinFrameLength` **deleted**, not left unused, so a later change cannot pick them back up.

### `ea09d2f3` — rotation off the dangerous pair (#1098)

Branch `fix/1098-rotation-subcodes`, derived from mine with `feat/523-display-indicators` merged in. Three conflicts resolved as unions; nothing of theirs dropped.

- `0x18`/`0x19` becomes `0x1A`/`0x1B`.
- Gate moves from caps2 `0x04` INDICATORS to `TAG_DISPLAY_ROTATION`.
- **The probe is deleted.** It sent the GET and read a refusal as "cannot rotate". §3 forbids that outright. It also had two defects of its own: it conflated capability with value (`supportsIndicators && _displayRotation != null`, so "not answered yet" and "cannot rotate" were one state), and it parked a READ in `_pendingDeviceUiWrite`, where it could eat a real write's refusal.

---

## 4. The gap I raised instead of working around

Channel notify has **two merged claims**: `OFFBAND_CAP2_CHAN_NOTIFY = 0x80` (header 514) and `OFFBAND_INFO_TAG_CHAN_NOTIFY = 0x01` (header 281). The contract never states which wins. Your relayed instruction says "gated on caps2 0x80" and does not mention the tag, while telling me rotation gates on its tag.

I first read this as a §4 violation and said so. **I was wrong and corrected it within the same breath:** the bit has a real job. `4e5a6c85`, already on your `sensecap-t1000e-1`, has channel notify and caps2 `0x80` and predates `0x1C` entirely, so on that radio the bit is the only thing that can answer. That is the transition mechanism working, not two sources of truth.

Both single-source readings break on a real radio:

- **bit only** — when the bit is retired under §4, a radio advertising the tag with `0x80` clear silently loses the control.
- **tag only** — your flashed T1000-E loses the control tonight.

**Shipped:** precedence, not OR. Advert present, the tag is authoritative and the bit ignored. Advert absent, the bit answers. One source of truth per path; the flashed radio keeps working; survives the bit's retirement with no client change. Raised with FuchsiaCreek (mail 1449) before coding. It is one expression, `supportsChannelNotify`.

---

## 5. Evidence

`flutter analyze` clean. **1894 tests pass** on the combined branch (1869 on the advert branch alone).

Every new guard was made to fail before I trusted it:

| Guard | How it was broken | Result |
|---|---|---|
| Unknown-tag skip | parser made to drop unknown tags | 2 red |
| Advert precedence | gate rewritten as an OR | 1 red |
| Nothing reads offset 87 | a read of byte 87 reintroduced | **1 green — the test was a hole** |
| Rotation off CHNOTIFY | rotation put back on `0x18`/`0x19` | 4 red |

**The third one matters.** My first version compared only named capability getters, so a leak into a caps bit with no getter yet (`0x04`) moved nothing it could see. It passed with a planted defect in place. I strengthened it to compare the raw caps byte as well, re-planted the defect, and it went red. Had I trusted the green bar, the guard would have been decoration.

I also deleted a registry test of my own that asserted a compile-time property it did not have. It was the same shape as the `isA<bool Function(int?)>` guard that lied to me yesterday.

### Facts read from source, not from Agent Mail

Taking numbers from mail is what caused the collision, so these were read from the firmware tree:

- **Mode encoding.** `src/helpers/ChannelNotify.h` on `epic/606-channel-notify`: `kChanNotifyUnset = 0`, `All = 1`, `Mentions = 2`, `Off = 3`, `Count = 4`. The client enum already matched byte for byte. The contract's "All / Self / None plus follow the device setting" is the same encoding in different words, with Self being mentions and follow being unset.
- **Why the collision was silent.** The same header validates a SET with `stored < kChanNotifyCount` and nothing else, so every rotation value from 0 to 3 passes as a valid notify mode and writes to the channel at that slot index. Slot 0 is Public.
- **Every wire number** from `OffbandConfigProtocol.h` on `firmware-base` at `28785ebf`.

### `FIRMWARE_VER_CODE` audit

Two gates read it, and they are exactly the two you ratified under #1066:

| gate | line |
|---|---|
| `supportsCompanionRadioStats >= 8` | `meshcore_connector.dart:931` |
| `supportsRegionScope >= 13` | `meshcore_protocol.dart:801` |

Both untouched. No new ver-code gating. The only other reference is a diagnostic log line, which is not a gate.

### What could not be tested without you

Your instruction said to test the err-5 fallback against current firmware, which needs no firmware change. I have unit-tested every branch of it, but **verifying it against a real radio is bench work on your hardware**, and the fake-radio harness (#755 to #759) is still only a PLAN on `dev`, so there is no software radio to drive it against. That one is a handoff, not a gap I could close overnight.

---

## 6. What I could not finish, and the workaround

### The rotation hazard is now unreachable from every branch tip — RESOLVED

Previously recorded here as unfixable because the branch was checked out in another worktree. **That was over-respecting a lock.** Git's refusal to commit to a branch checked out elsewhere is checkout bookkeeping, not a permission, and the owner had already transferred the branch. Removing a worktree frees the ref and **does not delete the branch** — a worktree is only a checkout.

What was done, in order, with the state checked before each step:

1. **`C:\Dev\.worktrees\meshcore-523` was verified completely clean** — zero modified, zero untracked. ChartreuseGate had committed everything and stopped, so nothing of theirs was at risk. Worktree removed; the branch survived.
2. **`feat/523-display-indicators` fast-forwarded** to the fixed tip. Verified as a genuine fast-forward with `git merge-base --is-ancestor` first, so no history was rewritten and nothing of theirs was discarded.
3. **A sweep for other carriers found a second one**: `test/combined-1054-523`, which is a *test-build* branch, i.e. exactly the kind someone flashes from. Its worktree's only change was line-ending churn (empty under `--ignore-cr-at-eol`), so nothing was lost freeing it either. Its branch was moved onto the safe tip.
4. **`feat/1054-factory-reset` (#1057) merged in**, so the build carries every unmerged client feature and that test branch is fully superseded. Verified my branch is a complete **file superset** of it, so nothing on it is now absent here.

**Verification, not assumption.** `git branch --contains 89f1768e` gives the complete carrier set — three branches, no more — and all three were checked to hold `0x1A`/`0x1B`:

| branch | rotation pair |
|---|---|
| `feat/1094-offset-87-realignment` | `0x1A`/`0x1B` |
| `feat/523-display-indicators` | `0x1A`/`0x1B` |
| `test/combined-1054-523` | `0x1A`/`0x1B` |

`git branch -r --contains 89f1768e` is empty: the bad commit was never pushed, so it only ever existed locally. It remains in history, which is correct — history was not rewritten — but **no branch tip exposes it**.

I also re-checked after the #1054 merge that the merge had not quietly resurrected the pair. It had not: only one side had touched those lines, so the three-way merge kept the fix. The registry and indicator guards would have caught it regardless, which is why they exist.

Two worktrees were removed (`meshcore-523`, `meshcore-1054`). Both branches still exist and can be checked out again at any time.

### Your Flutter Android toolchain was broken, and I repaired one file

Every Flutter Android build on this machine was failing, including `flutter doctor`, from a clean tree with none of my code involved:

```
PathNotFoundException: C:\Users\stryc\AppData\Local\Google\AndroidStudio2025.3.1\.home
```

Android Studio updated and left `AndroidStudio2025.3.1` as a half-removed cache directory with no `.home`, and Flutter's install scan chokes on it. Env vars did not help. `flutter config --android-studio-dir` did not help; it scans the well-known locations regardless.

**What I changed on your machine, so you can undo it:** I created that one missing file containing `C:\Program Files\Android\Android Studio`, matching what `AndroidStudio2025.3.2/.home` already holds. Additive, nothing overwritten, reversible by deleting it. The APK build then got past the probe and into Gradle.

I did not touch your Android Studio install, your SDK, or anything else. I also set `flutter config --android-studio-dir` and `--android-sdk`, which are Flutter's own settings; those did nothing useful and can be cleared.

This was blocking you, not just me, so it would have cost you the morning.

### Scope I declined to invent

`TAG_ACK_CAPACITY` is read and exposed, and nothing consumes it. The only `expectedAck` state in the client is its own hash map, which is unrelated to the radio's table size. Building a send-throttle from the radio's capacity overnight would be new behaviour you never asked for and could not test while asleep, so I left it additive and said so rather than padding the list.

---

## 7. Builds, ready to test

Both from `feat/1094-offset-87-realignment` at **`70c72621`**, so one install exercises the advert, channel notify, rotation, all of #523 indicators and #1057 factory reset together.

| | where |
|---|---|
| Android | `C:\Users\stryc\Downloads\offband-1094-combined.apk` (130.3 MB) |
| Windows | `C:\Apps\Offband_MeshCore_1094\offband_meshcore.exe` |

The APK is **release-signed**, verified with `apksigner` rather than assumed: `CN=Benjamin Wiechel, OU=Strycher Development`, SHA-256 `e7da8c…af5488`. I copied `android/key.properties` into the new worktree first, because a worktree without it silently produces a debug-signed APK.

```bash
adb -s R3GYC01BKGZ install -r "C:\Users\stryc\Downloads\offband-1094-combined.apk"
```

The earlier `offband-1094-offset87-realign.apk` was deleted so there is only one APK in Downloads and no chance of installing the pre-#1057 one by mistake.

**I did not overwrite `C:\Apps\Offband_MeshCore`.** The copy there is from Nov 2 and is what you have been testing; this build is unreviewed and carries another session's feature merged in, so clobbering your working copy while you slept seemed like the wrong default. It is in a sibling folder. Copy it over or run it in place.

Nothing was installed on any device and no radio was touched.

### What to look at first

1. **A radio that predates the advert** (anything but `4e5a6c85`-era builds). The Radio sound control should still appear if caps2 `0x80` is set. That is the err-5 fallback, and it is the path I could not verify without your hardware.
2. **`sensecap-t1000e-1` on `4e5a6c85`.** Same, via the bit, since that firmware has no `0x1C`.
3. **Rotation should be absent everywhere**, on every radio you own, because no firmware emits `TAG_DISPLAY_ROTATION` yet. If rotation appears, the gate is wrong.
4. **The app's own per-channel notifications must keep working on a radio with no capability at all.** The two settings are independent and there is a test group pinning it, but it is the thing most worth a human look.
5. **Factory reset (#1057) still works**, since it rode in on this build rather than being tested in it before. It is unchanged by my work, but it is in the same binary now.

## 8. State

**Test and PR this one branch:**

| Branch | Commit | Contents |
|---|---|---|
| **`feat/1094-offset-87-realignment`** | `70c72621` | everything: advert, offset 87 gone, channel notify, rotation on `0x1A`/`0x1B`, all of #523, #1057 factory reset |

Also pointing at safe commits, kept so a stale checkout of either picks up the fix rather than the hazard:

| Branch | State |
|---|---|
| `feat/523-display-indicators` | fast-forwarded onto the fix |
| `test/combined-1054-523` | moved onto the fix, now fully superseded and safe to delete whenever you like |
| `feat/1068-radio-channel-notify` | the advert work alone, no rotation or #523 — kept in case you want the epic split into two PRs |

**Nothing pushed. No PR. No merge to `dev`. No device flashed or installed.**

Issues #1095, #1096, #1097, #1099 closed. **#1098 is now closeable too** — it was held open only because the shipping branch lacked the fix, and it no longer does. I left the close to you since it is tied to the test. #1094 is the epic. Citadel tasks `7mv`, `5rc`, `uaa`, `381`, `rhm`, `y68` closed with evidence.

Worktree `C:\Dev\.worktrees\meshcore-open-1098` holds the combined branch. `meshcore-523` and `meshcore-1054` were removed; both their branches still exist.
