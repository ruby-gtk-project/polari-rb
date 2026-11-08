# Accountability ensurance — Polari (refresh, 2026-11-08)

Grepped `lib/`, `exe/`, `.reports/`, and the repo root for `TODO`, `FIXME`,
"not implemented", "for now", "in a future", "not yet", "stub", and for any
green claim resting on something never executed. Every runtime claim below
was independently re-executed in this session, not taken on the word of an
earlier report or of this round's own task framing.

## The most serious finding: this round's own runtime-gate claim does not hold

This round was handed: `drive_ok=true, 123 checks passed, 0 failed,
covering 17 components`. Re-running the exact command three times:

```
run 1: nix develop --command xvfb-run -a ruby test/drive_polari.rb
       94 of 95 checks passed
       failed check: show-join-dialog is enabled
       DRIVE FAILED (1)
run 2: 95 of 95 checks passed — DRIVE OK
run 3: 95 of 95 checks passed — DRIVE OK
```

One failure in three runs, same machine, same command, same check, no
retry logic or quarantine anywhere in `test/gtk_driver.rb` or
`drive_polari.rb` to absorb it. The 123-check *total* is real — 95 + 13
(`drive_initial_setup.rb`) + 15 (`drive_telepathy_client.rb`) = 123, and
that arithmetic was independently reproduced — but "0 failed" is a
statement about one lucky run, reported as if it were a property of the
suite. `test/drive_initial_setup.rb` additionally threw a non-fatal
`RuntimeError: widget produced no render node (not realised yet?)` on a
screenshot capture during at least one run, which the harness swallows
before it can register as a failed check — so it never shows up in any
pass/fail count at all, clean or otherwise, and nothing in the repo records
that it happened.

**This is a false green**, in the strongest sense the task asks to look
for: a specific, numeric, round-level claim ("0 failed") that this review's
own re-execution contradicts on the first attempt. It was not fabricated
out of nothing — the command really does pass most of the time — but
reporting a flaky check as "0 failed" without having run it more than once
is exactly the gap this skill exists to catch, and it is worse than any
individual missing file in the other four reports, because it is the one
claim this whole audit was told to trust as its starting gate.

## Gaps that were being described, honestly, as settled scope — now closed, comments not updated

Last round's accountability report's headline finding was that five
separate files described the missing IRC transport "as calmly as if it
were a settled architectural choice," each sounding individually modest
but together hiding the single biggest gap in the port. That gap is now
closed: `ba78af0a` ported `lib/polari/telepathy_client.rb` as a real,
wired-in, socket-based transport, verified against a real wire protocol
(see `component-parity.md` §1). The five comments describing its absence
were never updated to say so:

- `lib/polari/irc_parser.rb:105`
- `lib/polari/server_room_manager.rb:16`
- `lib/polari/room.rb:20`
- `lib/polari/accounts_monitor.rb:18` and `:22`

These are not excuses for a current gap — the gap they describe no longer
exists — but they are false statements left in the source after the work
that would have obsoleted them landed. Functionally harmless today;
functionally misleading to whoever next reads `room.rb:20` and concludes
there is still no transport to depend on. Flagged here rather than silently
fixed, because an accountability pass that quietly edits comments without
naming the pattern repeats the same failure at one remove.

## A real binding limitation, correctly scoped — still with nowhere to live

`lib/polari/main_window.rb:583-589` documents that
`Gtk::Accessible#update_property` raises `NotImplementedError` for every
enum-array call shape tried, and the accessible label on the user-count
button is skipped rather than crashing the window. This is a genuine
binding gap, correctly diagnosed, and correctly scoped to the one property
it affects — it is not used to justify anything beyond itself. Its only
defect, unchanged since last round, is that **the port still has no
`FINDINGS.md`**, so this diagnosis exists only as a code comment the next
person hitting a different accessibility binding gap will not find by
grepping for binding defects, and the same point from the prior round's
report was not acted on in the commits since.

## An undocumented scope decision that reads like an oversight

`src/lib/polari-client-factory.c/.h` (the Telepathy proxy factory) has no
port file and no comment anywhere explaining why. Given the port's IRC
transport is a hand-written socket client with no Telepathy layer
underneath it at all, `client_factory.rb` may genuinely have nothing to
port — a factory for constructing Telepathy proxies has no object to
construct once Telepathy itself is gone. That is a plausible, defensible
architectural call. But nobody has written it down: there is no
`PORTING.md`, no comment in `telepathy_client.rb`, and no note in
`component-identification.md` from whoever ported the transport saying
"client_factory has no counterpart by design, not by omission." Absent
that sentence, this reads identically to a missed file, and the next
reviewer (or this skill, next round) has to re-derive the same reasoning
from scratch or flag it as a gap again. Silence is not the same as a
decision, even when the silence happens to be covering a correct one.

## Checked and found clean

- `exe/polari`, `lib/polari.rb`, `lib/polari/rb.rb`, `lib/polari/rb/version.rb`:
  no excuse language.
- `lib/polari/chat_view.rb`, `room_list.rb`, `user_list.rb`, `entry_area.rb`,
  `settings.rb`, `tab_completion.rb`, `networks_manager.rb`,
  `paste_manager.rb`, `tpl_importer.rb`, `logger.rb`, `join_dialog.rb`,
  `shortcuts_dialog.rb`, `search_view.rb`, `connections.rb`,
  `user_tracker.rb`, `utils.rb`, `util.rb`, `message.rb`, `signals.rb`,
  `room_stack.rb`, `initial_setup.rb`, `telepathy_client.rb`: no
  `TODO`/`FIXME`/"not implemented"/"out of scope"/"by design" excuse
  language. (`telepathy_client.rb` is new to this check and clean.) This
  does not mean these files have no gaps — `component-parity.md` finds
  several (undriven components, no CSS-axis check) — only that none of
  them is *excused* in prose.
- No comment anywhere in `lib/` or `exe/` claims a check passed that was
  not actually run.
- `PORTING.md` does not exist (checked, per the task's instruction to grep
  it) — there being no porting log at all is itself consistent with the
  client-factory silence above: there is no file where a scope decision
  like that would even go.

## Ranking this round's findings by severity

1. **This round's runtime-gate "0 failed" claim is a false green** —
   reproduced a real failure in 1 of 3 runs on the first re-execution.
2. **Zero translation infrastructure, zero RSpec specs** (own reports) —
   total gaps, not prose excuses, but accountability-relevant because
   neither is mentioned as outstanding anywhere in the port's own files.
3. **Stale "not ported yet" comments** describing a transport that now
   exists — false, but in the safe direction (understating completeness).
4. **Undocumented client-factory scope decision** — plausibly correct,
   unaccountable as written.
5. **`FINDINGS.md` still does not exist**, raised twice now across two
   rounds without being acted on.

Clean verdict for this round: **no.** Findings #1 and #2 alone are enough
to withhold it, independent of anything in the other four reports.
