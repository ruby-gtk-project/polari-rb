# Component identification — Polari (refresh, 2026-11-07)

This supersedes the stale sections of `component-inventory.md` (last updated
2026-11-02, before `b4f6097e`/`084b2321`). It does not replace that file's
per-unit widget tables, which are still the canonical widget/CSS/signal
inventory for the units they cover — it corrects the file-existence claims at
the top of it and adds what that survey did not check: network transport.

## File-existence corrections

| Upstream unit | `component-inventory.md` said | Actual state (2026-11-07) |
|---|---|---|
| `src/initialSetup.js` | **missing** | **exists** — `lib/polari/initial_setup.rb` (209 lines), ported in `084b2321`, driven by `test/drive_initial_setup.rb` (13/13 checks) |
| `src/urlPreview.js` | missing | still missing |
| `src/thumbnailer.js` | missing | still missing |
| `src/telepathyClient.js` | missing | still missing, and see below — this is not a UI unit, it is the IRC transport |
| `src/lib/polari-client-factory.c/.h` | missing | still missing |
| `po/` (63 locales) | not scoped by that survey | missing in full — see `translation-parity.md` |

## The gap this round's survey undercounted: there is no IRC transport

`src/telepathyClient.js` is not a dialog or a page — it is the code that
opens a connection to an IRC server, logs in, joins channels, sends and
receives messages, and turns Telepathy channel/contact signals into the
`Polari::Room` / `Polari::Message` objects the UI displays. Searching the
whole port for any substitute:

```
$ grep -rn "TCPSocket\|Socket\.\|Gio::SocketClient\|EventMachine" lib/ exe/
(no matches)
$ grep -rn "Telepathy" lib/polari/accounts_monitor.rb
18:  # Telepathy account manager; there is no Telepathy here, so the same
```

confirms it directly: `lib/polari/accounts_monitor.rb:17-18` states in a
comment that there is no Telepathy integration. No file in `lib/` opens a
socket, speaks the IRC protocol, or talks to any transport at all. The 28
files under `lib/polari/` implement the account/room/message *data model* and
the full widget tree on top of it, and nothing that makes any of it connect
to a real network. This is scope no `component-identification` survey scoped
to "window, dialog, page" will surface, because it is not a widget — it is
the unit the application class exists to use, and it has to be named as its
own component: **`src/telepathyClient.js` + `src/lib/polari-client-factory.c`
→ nothing**, a two-file upstream unit with zero lines of port.

## Components exercised by zero check (test-parity / component-parity input)

Cross-referencing `lib/polari/*.rb` against every identifier appearing in
`test/drive_polari.rb` and `test/drive_initial_setup.rb` (the whole runtime
gate), these port files are not referenced, directly or by any accessor name,
anywhere in either drive script:

- `lib/polari/search_view.rb`
- `lib/polari/networks_manager.rb`
- `lib/polari/paste_manager.rb`
- `lib/polari/server_room_manager.rb`
- `lib/polari/tab_completion.rb`
- `lib/polari/tpl_importer.rb`
- `lib/polari/logger.rb`

Seven of the 27 non-support port files (`signals.rb` is explicitly excluded
from counts per the earlier survey) are built but never driven. Per this
round's gate framing, a component no check exercises is unverified, not done
— see `component-parity.md` and `test-parity.md` for the consequence.

## Scope of this refresh

This document intentionally does not re-walk every widget/CSS/signal table —
`component-inventory.md`'s unit tables for the units it covered (application,
main window, connections, join dialog, etc.) were produced carefully and are
reused as-is in `component-parity.md`. This refresh exists to fix the
file-existence claims and add the transport-layer finding above, which the
previous survey's "window/dialog/page" framing did not ask about.
