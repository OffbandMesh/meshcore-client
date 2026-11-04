# Offset-87 realignment, client half

**Epic:** #1094 · **Agent:** CalmBay · **Night of 2026-11-04**

Read §1 and §6. The rest is evidence.

---

## 1. What you need to decide

| # | Decision | Why it is yours |
|---|---|---|
| 1 | **Push and PR?** Nothing is pushed. Two branches sit local. | Tollgate. |
| 2 | **`feat/523-display-indicators` still carries the dangerous rotation.** Rebase it onto the fix, or leave it parked? | It is ChartreuseGate's branch, in their live worktree. I could not commit to it. |
| 3 | **One contract gap is unanswered by firmware.** I shipped a resolution and told FuchsiaCreek. | If they rule differently it is a one-line change. |

Everything else ran to completion. No stopping, no waiting.

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

---

## 6. What I could not finish, and the workaround

### The rotation hazard still exists on ChartreuseGate's branch

`89f1768e` on `feat/523-display-indicators` still sends rotation on `0x18`/`0x19`. Against `4e5a6c85` a rotation SET of `0` lands as a valid channel-notify mode write on **channel slot 0, which is Public and undeletable**, and both sides report success. No error, no banner, nothing in any log.

I could not fix it there: that branch is checked out in their live worktree, so git will not let another worktree commit to it, and writing into their working tree would corrupt their state. **Workaround:** the fix lives on a derived branch, so their work is neither blocked nor overwritten, and a rebase or merge carries it across. They were told on mail 1450, before I started, including not to flash `89f1768e`. They have not replied in 40 minutes; neither has FuchsiaCreek.

**Until that branch is rebased, do not point `89f1768e` at any radio carrying `4e5a6c85`.**

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

## 7. State

| Branch | Commit | Contents |
|---|---|---|
| `feat/1068-radio-channel-notify` | `5dc968ee` | advert, offset 87 gone, channel notify re-gated |
| `fix/1098-rotation-subcodes` | `ea09d2f3` | the above plus all of #523, rotation on `0x1A`/`0x1B` |

`fix/1098-rotation-subcodes` is the combined branch and the one to build and test.

**Nothing pushed. No PR. No merge. No device flashed or installed.**

Issues #1095, #1096, #1097, #1099 closed. #1098 left **open** on purpose, because the branch that ships rotation does not have the fix yet. #1094 is the epic. Citadel tasks `7mv`, `5rc`, `uaa`, `381`, `rhm` closed with evidence.

Worktree `C:\Dev\.worktrees\meshcore-open-1098` is new tonight and holds the combined branch.
