# Component parity — Polari (round 3)

| | |
|---|---|
| Upstream | `main` @ `dc5d9e34` |
| Port | `ruby` @ `c9a99285` |
| Units with full (4-axis + driven) parity | 0 / ~24 |

This round was handed: `drive_ok=true, 148 checks passed, 0 failed,
covering 24 components`. Every drive script was re-run multiple times in
this review, live, against `c9a99285`, not assumed from the gate's own
report or from either prior round's document.

## 1. The 148-check total is real; "0 failed" is not stable

```
test/drive_polari.rb            115 checks
test/drive_initial_setup.rb      16 checks
test/drive_telepathy_client.rb   17 checks
                                ----
                                 148  ✓ matches the stated gate total
```

Re-running `test/drive_polari.rb` repeatedly (7 runs total across two
batches in this session):

```
batch A, run 1: 115 of 115 checks passed — DRIVE OK
batch A, run 2: 115 of 115 checks passed — DRIVE OK
batch A, run 3: errored step: typing into the entry area and pressing
                Enter sends the text (NoMethodError: undefined method
                'entry_area' for nil)
                errored step: a slash command runs through the IRC parser
                (NoMethodError: undefined method 'entry_area' for nil)
                DRIVE FAILED (27)
batch B, run 1: 115 of 115 checks passed — DRIVE OK
batch B, run 2: 115 of 115 checks passed — DRIVE OK
batch B, run 3: 115 of 115 checks passed — DRIVE OK
```

One failure in 7 runs, same machine, same command. The symptom is new and
different from the `show-join-dialog is enabled` flake the last round's
report caught and this round's commits fixed — this one is
`room_stack.view_for_room(@room)` returning `nil` at the step that types
into the entry area, i.e. the room view is not guaranteed to be registered
in `@views` by the time the drive script reaches that step. The fix that
shipped this round (turning off GTK animations, counting shot failures)
closed the *specific* flake it targeted but did not make the suite
deterministic — it has a different single point of timing-dependent
failure now instead of zero.

**This repeats, in substance, the finding both prior rounds made about the
gate's "0 failed" claim.** The fact that the specific flake changed (join
dialog → entry area) between rounds, while the underlying property — "the
suite fails intermittently and the gate reports 0 failed because someone
ran it once" — did not change, is itself informative: the fixes applied
this round treated symptoms, not the root cause (UI state the test
advances past before a widget finishes being built/registered). Treat this
round's "0 failed" the same way the prior two rounds treated theirs: real
most of the time, not a property of the suite.

`test/drive_initial_setup.rb` (16/16 both runs) and
`test/drive_telepathy_client.rb` (17/17 both runs) were stable across every
run in this review.

## 2. Closed since the last round

- **Stale "not ported yet" comments** (5 locations, 4 files) — corrected.
  Verified by reading `irc_parser.rb:105`, `server_room_manager.rb:16-19`,
  `room.rb:20`, `accounts_monitor.rb:18-22` directly.
- **Swallowed screenshot failures** — `gtk_driver.rb`'s `shot` now adds a
  failed check instead of printing and continuing. Did not independently
  trigger a screenshot failure in this round's runs to confirm the new path
  fires, but the code change is real and matches the fix prior rounds
  called for.
- **Undocumented client-factory scope decision** — `PORTING.md` now states
  the reasoning in full. Read and agree it is a defensible architectural
  call, correctly scoped to the one file it's about.
- **No FINDINGS.md** — now exists, documents the one known binding gap
  (`Gtk::Accessible#update_property`).

## 3. Units with no check at all — unchanged, still 0/4 axes verified

```
$ for f in search_view networks_manager paste_manager server_room_manager \
    tab_completion tpl_importer logger; do grep -l "$f" test/*.rb; done
(no output)
```

| Unit | Upstream file(s) | Port file | Checks in any drive script |
|---|---|---|---|
| Search | `src/searchView.js` + `data/ui/search-{row,section}.ui` | `lib/polari/search_view.rb` | 0 |
| Network picker list | `src/networksManager.js`(-equiv) | `lib/polari/networks_manager.rb` | 0 |
| Paste handling | `src/pasteManager.js`(-equiv) | `lib/polari/paste_manager.rb` | 0 |
| Server room list (join dialog's room browser) | `data/ui/server-room-list.ui` | `lib/polari/server_room_manager.rb` | 0 |
| Tab completion | (part of `src/entryArea.js`) | `lib/polari/tab_completion.rb` | 0 |
| Old-log import | — | `lib/polari/tpl_importer.rb` | 0 |
| Logging | — | `lib/polari/logger.rb` | 0 |

This round's "24 components" gate figure cannot include these seven as
*driven* components — if they are among the 24 counted, the count itself
overstates verification; if they are not among the 24, the port has at
least 7 more files than the gate claims to cover, either way the same
underlying gap the task asked to watch for (a component no check exercises
is unverified, not done) stands, unchanged across three rounds now.

## 4. Units newly covered this round

- Nick popover from a chat-log click (`chat_view.rb#build_nick_popover`) —
  new checks, type and nickname verified.
- User-list row expand/collapse on activation (`user_list.rb`) — new
  checks, both directions verified.

Both are real additions to files that already had partial coverage, not new
components; they do not close any of the seven zero-coverage files above.

## 5. Known missing units (file-level, re-verified against `origin/main`)

- `src/urlPreview.js` → no port file.
- `src/thumbnailer.js` → no port file (moot until `urlPreview.rb` exists).
- `src/lib/polari-client-factory.c/.h` → no port file, but now documented
  as an intentional no-op in `PORTING.md` — no longer counted as an
  unaccountable gap, though it is still a file-level absence relative to
  upstream.
- `po/` (63 locales) → see `translation-parity.md`; still total, not
  partial.

No round so far has compared the port's stylesheet (`data/style.css`, if
it exists) against upstream's `data/css/style.css` CSS-class-by-class; that
comparison still has not been run.

## Gaps (summary)

1. **The runtime gate's "0 failed" is still not stable** — a different
   flake than the one this round's commits fixed, reproduced once in 7
   runs (§1). Carried forward in substance across all three rounds now.
2. **7 of ~29 non-support components still have zero check coverage**,
   unchanged by this round's widening of `drive_polari.rb` (§3).
3. **2 upstream units still have no port file**: url preview, thumbnailer
   (§5). Client factory is now documented, not a gap by this skill's
   standard, but still absent as a file.
4. **CSS-axis comparison has still never been performed**, any round.
5. **Translation layer is still a total gap** — tracked in
   `translation-parity.md`.

Closed since last round: stale comments, swallowed screenshot failures,
undocumented client-factory decision, missing FINDINGS.md. Real progress,
verified by reading the diffs and the resulting files, not by trusting the
commit subjects.
