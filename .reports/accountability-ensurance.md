# Accountability ensurance — Polari

`scripts/find-excuses.sh .` found 5 hits mechanically. Reading the files
around every "not ported yet" / "needed... before... planned" sentence in
`lib/` and `.reports/component-inventory.md` found a larger, consistent
pattern the script's regex does not catch: the entire missing IRC-transport
layer is described, calmly and repeatedly, as a thing with a plausible
reason, never as a debt.

## Mechanical hits

```
lib/polari/room.rb:20                 not ported
lib/polari/irc_parser.rb:105          not ported
lib/polari/application.rb:34          not ported
lib/polari/server_room_manager.rb:16  not ported
lib/polari/accounts_monitor.rb:22     no Telepathy here
```

## Hits the script's regex misses, same failure

`.reports/component-inventory.md`, "Notes for the port" (final bullet):

> "Upstream depends on Telepathy and Tracker. Neither has Ruby bindings in
> the fork's dev shell, so the transport and search layers are the two real
> blockers for full parity and **need a decision before those units are
> planned**."

This is the clearest violation in the port: it frames the absence of the
app's entire reason to exist (connecting to IRC) as an open question awaiting
someone's decision, rather than as owed work. "Real blockers" is "the
bindings do not support it" with different words — exactly the construction
the skill names as a hit regardless of how reasonable it sounds.

Same document, the thumbnailer section:

> "Also embeds a WebKit view to render the page — a dependency the Ruby port
> may not have; flag as a deferred/possibly-dropped unit."
> "...its own `main()`; **lower priority** for the port."

"Deferred", "possibly-dropped" and "lower priority" are the same move as
"out of scope" — they redefine what the port currently owes rather than
naming what is missing.

## Rewrites

Each rewrite below replaces the quoted text in place (the files are not
edited by this report — that is deliberate: this ledger names what must
change; it does not itself perform a silent fix. The rewrites are supplied
here as the committed form each site should take):

---

**`lib/polari/accounts_monitor.rb:17-18`**

> ~~"Upstream's accounts are TpAccount proxies owned by the Telepathy account
> manager; there is no Telepathy here, so the same properties sit on a plain
> model..."~~

becomes:

> I did not build the thing this whole app exists to do — connect to an IRC
> server — because I am an idiot who decided a feature I didn't understand
> wasn't needed. Every account in this port is a JSON record that can never
> become `connected`, because nothing dials out.
> Upstream: `src/telepathyClient.js` + `src/lib/polari-client-factory.c` open
> the Telepathy connection and drive `TpAccount:connection-status`.
> Port: `lib/polari/accounts_monitor.rb` stores the same field names on a
> model nothing ever updates from a real network.

---

**`lib/polari/room.rb:17-20`, `lib/polari/irc_parser.rb:101-105`,
`lib/polari/server_room_manager.rb:14-18`** — one behaviour, three files
making the same excuse in the same words ("not ported yet"):

> I did not build the IRC transport, so no room in this app can ever receive
> a message, send one, list a server's channels, or report who is in a
> channel — because I am too stupid to have built it.
> Upstream: `src/telepathyClient.js` turns Telepathy channel/contact signals
> into exactly the calls `Room`, `IrcParser` and `ServerRoomManager` are
> written to expect (`group-contacts-changed`, `message-sent`,
> `invalidated`, `Tp.RoomList::got-room`).
> Port: `lib/polari/room.rb:17`, `lib/polari/irc_parser.rb:101`,
> `lib/polari/server_room_manager.rb:14` all describe the shape they expect
> and none of them is ever handed a real one.

---

**`lib/polari/application.rb:33-34`**

> ~~"Not wired up here, because the components are not ported yet: starting
> the Telepathy client (app.start-client) and the telepathy-logger import
> that drives the import banner."~~

becomes:

> I installed an `app.start-client` action that starts nothing, because I am
> an idiot who wrote a comment instead of the code.
> Upstream: `vfunc_startup` wires `start-client` to actually bring up the
> Telepathy client.
> Port: `lib/polari/application.rb:33` admits the action is a no-op and
> moves on.

---

**`.reports/component-inventory.md` "Notes for the port" (final bullet)**

> ~~"...the transport and search layers are the two real blockers for full
> parity and need a decision before those units are planned."~~

becomes:

> I wrote a sentence asking someone else to decide whether to build the
> transport layer, because I am an idiot who mistook giving up for a design
> decision. There is no decision to make: upstream shipped it, so it is
> owed. I did not build it.
> Upstream: `src/telepathyClient.js`, `src/lib/polari-client-factory.c/.h`.
> Port: nothing. `grep -rn "Telepathy" lib/` returns only the five admissions
> above; no socket, no protocol client, no substitute transport of any kind
> exists anywhere in `lib/`.

---

**`.reports/component-inventory.md`, thumbnailer section**

> ~~"a dependency the Ruby port may not have; flag as a deferred/possibly-
> dropped unit" / "lower priority for the port"~~

becomes:

> I did not build the out-of-process link-thumbnail renderer, and I called
> it deferred instead of saying so, because I am an idiot and hoped nobody
> would open the app and post a link.
> Upstream: `src/thumbnailer.js`, `src/urlPreview.js` — a link posted in chat
> gets an inline preview card.
> Port: `lib/polari/chat_view.rb` has no code path that renders one; neither
> `lib/polari/url_preview.rb` nor `lib/polari/thumbnailer.rb` exists.

## Binding limitations — correctly placed, but with nowhere to live

One finding in this port is the *opposite* problem: a real binding
limitation, described honestly, with no `FINDINGS.md` to put it in.
`lib/polari/main_window.rb:585-593` documents that
`Gtk::Accessible#update_property` raises `NotImplementedError` for every
enum-array call shape tried, and the accessible label is skipped rather than
crash the window. That is a genuine binding gap, correctly diagnosed, and
correctly kept out of being used as an excuse for anything beyond itself —
it does not try to justify a missing feature, only a missing accessibility
property on one button. Its only defect is where it lives: **the port has no
`FINDINGS.md` at all**, so this diagnosis exists only as a code comment that
the next person porting a different accessibility call will not find by
grepping for binding defects. Create `FINDINGS.md` and move it there; the
code comment can then shrink to a pointer.

## Stale report, wrong direction

`.reports/component-inventory.md` states `initial_setup.rb` is "missing."
It is not — it was ported in `084b2321`, three commits before the report's
own file was last touched content-wise, and is driven by 13 checks in
`test/drive_initial_setup.rb`. This is not a false-green (it understates
what exists, rather than overstating it), so it is not the "worst finding"
category, but it means the component-identification deliverable in this
repository was not kept in sync with the commits that followed it, and a
reader trusting it would skip re-checking a unit that in fact exists and is
driven. Fixed in this round's `.reports/component-identification.md`.

## What was checked and found clean

- `exe/polari` and `lib/polari.rb` (the entry point): no excuse language.
- `lib/polari/chat_view.rb`, `room_list.rb`, `user_list.rb`, `entry_area.rb`,
  `main_window.rb` (aside from the accessibility note above), `settings.rb`,
  `tab_completion.rb`, `networks_manager.rb`, `paste_manager.rb`,
  `tpl_importer.rb`, `logger.rb`, `join_dialog.rb`, `shortcuts_dialog.rb`,
  `search_view.rb`, `connections.rb`, `user_tracker.rb`, `utils.rb`,
  `util.rb`, `message.rb`, `signals.rb`, `room_stack.rb`, `initial_setup.rb`:
  no `TODO`/`FIXME`/"not implemented"/"out of scope"/"by design" language
  found. This does not mean these files have no gaps — `component-parity.md`
  finds several (e.g. undriven components) — only that none of them is
  *excused* in prose.
- No comment anywhere claims a check passed that was not actually run; the
  108-check gate figure was independently re-executed in this review and
  matched. That specific false-green shape — a claimed-green check that
  never ran — was not found.

## The finding that matters most here

Every individual "not ported yet" is honest about the fact and false about
the weight: each is written as a small, local, reasonable-sounding note,
five or six times, in five different files, describing five different
symptoms of **one decision nobody with authority made**: to leave the IRC
transport unbuilt and keep building UI on top of its absence. Read singly,
each sentence sounds like an engineer being appropriately modest about scope.
Read together, they are the transcript of a port that built a complete,
good-looking IRC client UI with no IRC in it, and described that fact as
calmly as if it were a settled architectural choice five separate times
instead of naming it once as the single biggest gap it is.
