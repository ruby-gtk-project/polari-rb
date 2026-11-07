# Component parity — Polari

| | |
|---|---|
| Upstream | `main` @ `dc5d9e34` |
| Port | `ruby` @ `b4f6097e` |
| Units with full (4-axis + driven) parity | 0 / ~21 |

This is an adversarial pass over the runtime gate's own claim (108 checks,
21 components, drive OK), not a restatement of it. The gate is real — both
drive scripts were re-run in this review and reproduce 95/95 and 13/13 — but
"108 checks passed" is a claim about the checks, not about the app, and the
two are not the same claim.

## 1. The transport gap makes every "component" a facade over nothing

Before any widget-level comparison: `component-identification.md` establishes
that the port has **no IRC transport at all** — no socket, no Telepathy, no
substitute protocol client anywhere in `lib/`. Every component below —
`RoomList`, `ChatView`, `UserList`, `EntryArea`, `SearchView` — is correctly
built as a widget and correctly wired to `RoomManager`/`Room`/`Message`
objects, but those objects are populated only by the test harness poking
synthetic data in directly (`test/drive_polari.rb` builds rooms and messages
by calling Ruby methods, never by connecting anywhere). A user who launches
`exe/polari`, picks a network and hits "Done" gets a window with an account
in it and no way for that account to ever show `connected`, because nothing
ever dials the server. **This is the single component-parity finding that
dominates all others**: the app cannot do the one thing an IRC client exists
to do. Every row below should be read in that light — "parity" on a widget
whose data can never arrive from a real network is parity on a prop.

## 2. Units with no check at all (0/4 axes verified — not driven, not screenshotted)

| Unit | Upstream file(s) | Port file | Checks in either drive script |
|---|---|---|---|
| Search | `src/searchView.js` + `data/ui/search-{row,section}.ui` | `lib/polari/search_view.rb` | 0 |
| Network picker list | `src/networksManager.js`(-equiv) | `lib/polari/networks_manager.rb` | 0 |
| Paste handling | `src/pasteManager.js`(-equiv) | `lib/polari/paste_manager.rb` | 0 |
| Server room list (join dialog's room browser) | `data/ui/server-room-list.ui` | `lib/polari/server_room_manager.rb` | 0 |
| Tab completion | (part of `src/entryArea.js`) | `lib/polari/tab_completion.rb` | 0 |
| Old-log import | — | `lib/polari/tpl_importer.rb` | 0 |
| Logging | — | `lib/polari/logger.rb` | 0 |

Per the task's own framing — "a component no check exercises is unverified,
not done" — these seven are gaps regardless of whether the code underneath
them is correct. None of them has ever run under the headless driver, so
none of them has ever been proven to not crash, let alone to match upstream's
widget tree, CSS or signals. `component-identification.md`'s per-file widget
tables for these files (where `component-inventory.md` has them) describe
what was *written*, not what was *checked*.

## 3. Units covered by the drive scripts (sampled, not exhaustive)

| Unit | Verdict | Note |
|---|---|---|
| `Polari::Application` / menu / actions | parity (driven) | 31+9 actions listed in `component-inventory.md`; the drive scripts exercise a subset (`run-in-background`, `leave-current-room`, `user-list`, remove/undo-remove-connection, etc.) — not all 40 action names appear in either drive script, so "driven" ≠ "every action driven" |
| `Polari::InitialSetupWindow` | parity (driven) | 13/13, titles, labels, page transitions, Back behaviour all checked |
| `Polari::ConnectionProperties` | parity (driven) | server/nick fields, Apply sensitivity |
| `Polari::JoinDialog` | referenced, not deeply driven | class appears in drive script; no check against upstream's join-room-dialog CSS classes or validation messages located |
| `Polari::AccountsMonitor` / `Settings` / `RoomManager` | driven (data-model level) | these are the data model gate checks live against — see §1, they are never driven against a real connection |
| `Polari::MainWindow`, `ChatView`, `RoomList`, `RoomStack`, `EntryArea`, `UserList` | partially driven | referenced via geometry/title/subtitle checks and screenshots, not via a full widget/CSS/signal table against `component-inventory.md`'s rows for these files |

No unit in this list has been driven against its CSS classes or stylesheet
(`data/style.css` vs the port's `data/style.css`) in this review — that
comparison was not run; see Gaps.

## 4. Known missing units (file-level, carried from `component-identification.md`)

- `src/urlPreview.js` → **no port file.** Links posted in chat upstream get an
  inline preview card; the port has no equivalent, and nothing in `chat_view.rb`
  renders one.
- `src/thumbnailer.js` → **no port file.** The separate WebKit thumbnailer
  process upstream uses for URL previews has no reason to exist without
  `urlPreview.rb`, but its absence is still an upstream unit with zero port.
- `src/telepathyClient.js` + `src/lib/polari-client-factory.c/.h` → **no port
  file**, and per §1 this is the gap that makes the rest cosmetic.
- `po/` (63 locales) → see `translation-parity.md`.

## Gaps (summary)

1. **No IRC transport** (§1) — the defining gap of this port.
2. **7 of 27 non-support components have zero check coverage** (§2).
3. **4 upstream units have no port file at all**: url preview, thumbnailer,
   telepathy client, client factory (§4).
4. **CSS-axis comparison not performed this round** — `data/style.css` exists
   on the port side (copied, per `component-inventory.md`) but no class-by-
   class attachment diff against upstream's `data/css/style.css` was run in
   this review; open.
5. **Not every installed action is exercised by a check** — the drive
   scripts cover a subset of the ~40 actions `component-inventory.md` lists;
   the untested remainder is unverified, not done, per the same rule as §2.

Nothing above is excused by the 108-check gate. The gate shows the app does
not crash while performing the 108 specific things the harness asked it to
do; it is not evidence for the seven undriven components, the four missing
files, or the fact that no account can ever actually connect.
