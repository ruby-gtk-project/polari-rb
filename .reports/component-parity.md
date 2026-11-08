# Component parity — Polari

| | |
|---|---|
| Upstream | `main` @ `dc5d9e34` |
| Port | `ruby` @ `ae37f5b2` |
| Units with full (4-axis + driven) parity | 0 / ~21 |

This is an adversarial pass over this round's own runtime-gate claim
(123 checks, 17 components, `drive_ok=true`, 0 failed), not a restatement
of it. Every drive script was re-run multiple times in this review, live,
not assumed from a prior report.

## 1. The transport gap is closed — correct the previous finding, do not carry it forward

The previous round's `component-parity.md` led with "no IRC transport at
all... every component is a facade over nothing." That is no longer true.
`lib/polari/telepathy_client.rb` opens a real `TCPSocket`, speaks real IRC
protocol, and is instantiated by `Application` for real use, not only by a
test. `test/drive_telepathy_client.rb` proves this against a real server on
a loopback socket (registration, JOIN, member list from a real NAMES reply,
a real incoming PRIVMSG landing in the chat view, a real outgoing PRIVMSG
the fake server reads back, QUIT tearing the channel down) — 15/15, reread
and re-run twice in this pass. Repeating last round's "facade over nothing"
framing this round would itself be a false claim; this report does not.

## 2. The runtime gate's "0 failed" does not reproduce reliably

This round's stated gate is `drive_ok=true, 123 checks passed, 0 failed,
covering 17 components`. `test/drive_polari.rb` (95 checks) +
`test/drive_initial_setup.rb` (13) + `test/drive_telepathy_client.rb` (15)
= **123**, so the total is real and was independently reproduced. But run
three separate times in this review, `test/drive_polari.rb` was:

```
run 1: 94 of 95 checks passed
       failed check: show-join-dialog is enabled
       DRIVE FAILED (1)
run 2: 95 of 95 checks passed — DRIVE OK
run 3: 95 of 95 checks passed — DRIVE OK
```

One failure in three runs on the same check, same machine, same command —
`show-join-dialog is enabled` — with no retry or quarantine in the harness.
`test/drive_initial_setup.rb` also threw a non-fatal `RuntimeError: widget
produced no render node (not realised yet?)` while capturing a screenshot
on at least one run, swallowed before it could fail the check count.
**A flaky check is not a passed check reported honestly** — "0 failed" is
a true statement about the one run someone happened to report, and a false
one about the suite's actual behavior. Treat this round's gate number as
unverified-stable, not as the clean bill of health its own framing implies.
See `accountability-ensurance.md` for why this is this review's most
serious finding.

## 3. Units with no check at all (0/4 axes verified — not driven, not screenshotted)

Unchanged by the transport port, because none of these units is reachable
from any of the three drive scripts:

| Unit | Upstream file(s) | Port file | Checks in any drive script |
|---|---|---|---|
| Search | `src/searchView.js` + `data/ui/search-{row,section}.ui` | `lib/polari/search_view.rb` | 0 |
| Network picker list | `src/networksManager.js`(-equiv) | `lib/polari/networks_manager.rb` | 0 |
| Paste handling | `src/pasteManager.js`(-equiv) | `lib/polari/paste_manager.rb` | 0 |
| Server room list (join dialog's room browser) | `data/ui/server-room-list.ui` | `lib/polari/server_room_manager.rb` | 0 |
| Tab completion | (part of `src/entryArea.js`) | `lib/polari/tab_completion.rb` | 0 |
| Old-log import | — | `lib/polari/tpl_importer.rb` | 0 |
| Logging | — | `lib/polari/logger.rb` | 0 |

Per the task's own framing, these seven are gaps regardless of whether the
code underneath is correct.

## 4. Units covered by the drive scripts (sampled, not exhaustive)

| Unit | Verdict | Note |
|---|---|---|
| `Polari::TelepathyClient` / `IrcConnection` | parity (driven, real wire protocol) | 15/15, see §1 |
| `Polari::Application` / menu / actions | parity (driven, partial) | 31+9 actions catalogued in `component-inventory.md`; the drive scripts exercise a subset |
| `Polari::InitialSetupWindow` | parity (driven), but see §2 for the screenshot error | 13/13 |
| `Polari::ConnectionProperties` | parity (driven) | server/nick fields, Apply sensitivity |
| `Polari::JoinDialog` | partially driven, and now with a flaky check attached | the show-join-dialog sensitivity check is the one that failed in §2 |
| `Polari::MainWindow`, `ChatView`, `RoomList`, `RoomStack`, `EntryArea`, `UserList` | partially driven | geometry/title/subtitle checks and screenshots, not a full widget/CSS/signal table against `component-inventory.md`'s rows |

No unit has been driven against its CSS classes or stylesheet
(`data/style.css` vs upstream `data/css/style.css`) in any round so far;
that comparison has still not been run.

## 5. Known missing units (file-level)

- `src/urlPreview.js` → no port file.
- `src/thumbnailer.js` → no port file (moot until `urlPreview.rb` exists,
  but still an unported upstream unit).
- `src/lib/polari-client-factory.c/.h` → no port file, and no note anywhere
  in the port saying whether this is dead weight under the new socket
  architecture or an actual gap — see `accountability-ensurance.md`.
- `po/` (63 locales) → see `translation-parity.md`; total, not partial.

## Gaps (summary)

1. **The runtime gate's "0 failed" is not stable** — reproduced a real
   failure in 1 of 3 runs on the same check (§2). This is this round's
   most serious finding.
2. **7 of ~29 non-support components have zero check coverage** (§3).
3. **3 upstream units have no port file at all**: url preview, thumbnailer,
   client factory (§5); translations are a fourth, tracked separately.
4. **CSS-axis comparison still not performed**, any round.
5. **Not every installed action is exercised by a check** — the drive
   scripts cover a subset of the ~40 actions `component-inventory.md` lists.
6. **Stale "not ported yet" comments** about the transport that is now
   ported, in four files — see `component-identification.md`.

Nothing above is excused by the 123-check gate. The gate — when it passes —
shows the app does not crash while performing the specific things the
harness asked it to do; it is not evidence for the seven undriven
components, the three missing files, or the CSS axis, and this round it is
not even reliable evidence for itself.
