# Component identification — Polari (refresh, 2026-11-08, round 3)

| | |
|---|---|
| Upstream | `main` @ `dc5d9e34` |
| Port | `ruby` @ `c9a99285` |

This refresh re-derives the file inventory against upstream from scratch
(`git ls-tree -r --name-only origin/main`, `git show origin/main:<path>`
for the files in question) rather than trusting the prior round's table.

## What changed since the last refresh (`ae37f5b2`)

Commits `5ebfcc3b` and `c9a99285` landed between the last audit and this
one. Verified by reading the diffs, not just the commit subjects:

- The five stale "not ported yet" comments the last two rounds flagged
  (`irc_parser.rb:105`, `server_room_manager.rb:16`, `room.rb:20`,
  `accounts_monitor.rb:18,:22`) are now corrected to describe
  `telepathy_client.rb` as ported. Confirmed by reading each file.
- `PORTING.md` now exists and documents, in detail, why
  `src/lib/polari-client-factory.c/.h` has no `lib/polari/client_factory.rb`
  counterpart (the port's socket transport has no `TpAccountManager`/
  `TpSimpleClientFactory` machinery for a factory to intercept). This is a
  real, substantive scope decision written down, not a placeholder file —
  read in full, it closes last round's "undocumented scope decision" gap.
- `FINDINGS.md` now exists and documents the `Gtk::Accessible#update_property`
  enum-array binding gap. `main_window.rb`'s inline comment was shortened to
  point at it instead of repeating it. Closes last round's "no FINDINGS.md"
  gap, raised twice before.
- `test/gtk_driver.rb`'s `shot` helper now counts a screenshot failure as a
  failed check (`@failed_checks << "shot #{name}"`) instead of logging and
  swallowing it. This closes the specific "silent screenshot error" gap from
  the last two rounds' reports.
- `test/drive_polari.rb` gained two new step pairs: a nick-popover check
  (clicking a nick in the chat log) and a user-list row expand/collapse
  check, plus `pump(100)` calls after dialog-open animations. Check count
  rose from 95 to 115 in this file alone.

## File-existence status (re-verified against `origin/main`, not copied forward)

| Upstream unit | Status |
|---|---|
| `src/telepathyClient.js` | ported — `lib/polari/telepathy_client.rb`, wired into `Application`, driven by `test/drive_telepathy_client.rb` (16/16 this run — see `component-parity.md`) |
| `src/lib/polari-client-factory.c/.h` | **no port file, now documented as an intentional no-op** in `PORTING.md` — no longer an unaccountable gap |
| `src/urlPreview.js` | **still missing** — no inline link-preview card in `chat_view.rb` or anywhere else |
| `src/thumbnailer.js` | **still missing** — the WebKit thumbnailer binary `urlPreview.js` spawns; moot until `urlPreview.rb` exists, but still an unported upstream unit |
| `po/` (63 locales) | **still missing in full** — see `translation-parity.md`, unchanged at zero |

## Components exercised by zero check — re-checked against the current drive scripts, not assumed unchanged

Grepped `test/drive_polari.rb`, `test/drive_initial_setup.rb`, and
`test/drive_telepathy_client.rb` for every port filename's identifiers
after this round's widening of `drive_polari.rb`:

```
$ for f in search_view networks_manager paste_manager server_room_manager \
    tab_completion tpl_importer logger; do
    grep -l "$f" test/*.rb
  done
(no output for any of the seven)
```

All seven are still unreferenced by any drive script, unchanged from the
last two rounds despite this round's widening of `drive_polari.rb` — the
new checks added (nick popover, user-list row expansion) exercise
`chat_view.rb` and `user_list.rb`, both of which already had coverage, not
any of the seven zero-coverage files:

- `lib/polari/search_view.rb`
- `lib/polari/networks_manager.rb`
- `lib/polari/paste_manager.rb`
- `lib/polari/server_room_manager.rb`
- `lib/polari/tab_completion.rb`
- `lib/polari/tpl_importer.rb`
- `lib/polari/logger.rb`

A component no check exercises is unverified, not done — unchanged finding,
carried forward because it is still true, not because it was copied.

## Scope of this refresh

As with prior rounds, the widget/CSS/signal-level tables in
`component-inventory.md` are reused as-is; nothing in this round's commits
touched the window/dialog/menu surface those tables describe. This refresh
is specifically about what changed (stale comments, FINDINGS/PORTING, the
shot-failure counting fix) and what, despite the round's framing, still has
not changed (the seven undriven files, translations, the two missing
upstream files).
