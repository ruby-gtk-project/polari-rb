# Component identification — Polari (refresh, 2026-11-08)

This supersedes the 2026-11-07 refresh. The headline finding of that
document — "there is no IRC transport" — is now **false**: `ba78af0a`
("Port the IRC transport") added `lib/polari/telepathy_client.rb` (722
lines) since that refresh was written, and it is wired into the app
(`Polari::Application#telepathy_client` instantiates it with the real
`accounts_monitor` and `room_manager`, `lib/polari/application.rb:125`), not
just reachable from a test. `test/drive_telepathy_client.rb` drives it
against a real TCP loopback server speaking actual IRC wire protocol
(NICK/USER, 001, JOIN, 353/366, PRIVMSG both ways, QUIT) and gets 15/15
checks — re-run twice in this pass, both `DRIVE OK`. This is a real
correction, not a restatement: the previous round's dominant finding no
longer holds and continuing to cite it would itself be a false claim.

## File-existence corrections

| Upstream unit | Prior refresh said | Actual state (2026-11-08) |
|---|---|---|
| `src/telepathyClient.js` | missing — "no IRC transport at all" | **exists** — `lib/polari/telepathy_client.rb` (722 lines), wired into `Application`, driven 15/15 by `test/drive_telepathy_client.rb` |
| `src/lib/polari-client-factory.c/.h` | missing | **still missing** — upstream's factory mediates `TpAccountManager`/`TpSimpleClientFactory` construction of Telepathy proxies; the port's socket-based transport has no Telepathy layer to factory, so this may be a legitimate architectural no-op rather than a gap, but nothing in the port says so — see `accountability-ensurance.md` |
| `src/urlPreview.js` | missing | **still missing** — no inline link-preview card anywhere in `chat_view.rb` |
| `src/thumbnailer.js` | missing | **still missing** — the separate WebKit thumbnailer binary upstream spawns for `urlPreview.js`; moot until that exists, but still an unported upstream unit |
| `po/` (63 locales) | missing in full | **still missing in full** — see `translation-parity.md` |

## Stale excuse language the transport port left behind

Five separate comments across four files still say the transport "is not
ported yet," now describing code that has been ported for one commit:

- `lib/polari/irc_parser.rb:105`
- `lib/polari/server_room_manager.rb:16`
- `lib/polari/room.rb:20`
- `lib/polari/accounts_monitor.rb:18` and `:22`

None of these is a *current* excuse for missing behaviour — the behaviour
exists now — but each is now a false statement in the source, and the
previous round's accountability report specifically flagged this five-files
pattern as "the finding that matters most" for the opposite reason (it was
true then and used to normalize a major gap). Leaving the sentences in place
after the gap closes trades one risk for another: the next person reading
`room.rb:20` will conclude there is still no transport and either re-port it
or route around a dependency that already exists. See
`accountability-ensurance.md` for the categorization.

## Components exercised by zero check (unchanged from prior refresh)

Still true after the transport port — cross-referencing `lib/polari/*.rb`
against every identifier in all three drive scripts
(`drive_polari.rb`, `drive_initial_setup.rb`, `drive_telepathy_client.rb`):

- `lib/polari/search_view.rb`
- `lib/polari/networks_manager.rb`
- `lib/polari/paste_manager.rb`
- `lib/polari/server_room_manager.rb`
- `lib/polari/tab_completion.rb`
- `lib/polari/tpl_importer.rb`
- `lib/polari/logger.rb`

Seven of the (now 29, `signals.rb` and version files excluded) port files
are built but never driven by any script in `test/`. A component no check
exercises is unverified, not done — the task's own framing for this round.

## Scope of this refresh

As before, this document does not re-walk every widget/CSS/signal table —
`component-inventory.md`'s per-unit tables for application, main window,
connections, join dialog etc. are reused as-is. This refresh updates the
transport-layer finding and adds the stale-comment finding above.
