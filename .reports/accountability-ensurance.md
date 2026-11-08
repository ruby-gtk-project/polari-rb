# Accountability ensurance — Polari (round 3, refresh 2026-11-08)

Grepped `lib/`, `exe/`, `.reports/`, `PORTING.md`, and `FINDINGS.md` for
`TODO`, `FIXME`, "not implemented", "for now", "in a future", "not yet",
"stub", and for any green claim resting on something never executed.
Every runtime claim below was independently re-executed in this session —
7 total runs of `test/drive_polari.rb` across two batches, 2 runs each of
the other two drive scripts — not taken on the word of this round's task
framing or of either prior round's report.

## The most serious finding, again: this round's runtime-gate claim does not hold, under a new symptom

This round was handed: `drive_ok=true, 148 checks passed, 0 failed,
covering 24 components`. The 148 total is real (115 + 16 + 17, verified by
direct re-run). Re-running `test/drive_polari.rb` seven times across two
batches:

```
6 of 7 runs: 115 of 115 checks passed — DRIVE OK
1 of 7 runs: errored step: typing into the entry area and pressing Enter
             sends the text (NoMethodError: undefined method 'entry_area'
             for nil)
             errored step: a slash command runs through the IRC parser
             (same cause)
             DRIVE FAILED (27)
```

Cause: `room_stack.view_for_room(@room)` returned `nil` — the room's view
was not yet registered in `@views` when the step ran. This is a *different*
flake from the one the last round's commits fixed (`show-join-dialog is
enabled`, caused by `AdwDialog`'s close animation outlasting one driver
tick). That fix — disabling GTK animations and adding `pump(100)` after
dialog-open calls — worked: the join-dialog flake did not recur in any of
these 7 runs. But it treated the specific symptom it was built to catch,
not the general pattern underneath both flakes (the drive script advancing
past a step before GTK/the app has finished mutating widget state under
Xvfb's timing). The result: the suite went from one known flaky check to a
different flaky check, and the round's own gate report says "0 failed"
either way.

**This is the third consecutive round this exact category of finding has
been raised** — round 1: "no transport, every component is a facade" (a
different kind of finding, since resolved); round 2 and round 3: "the
gate's 0-failed claim does not reproduce, under reproduction in this
review." The fact that the specific failing step changes each round while
the structural property (intermittent failure, reported as 0 failed because
it was run once) persists is itself the accountability-relevant pattern:
each round's fix closes the exact case that round's audit caught, without
addressing why the suite produces a new flaky case each time. Until the
harness has retry/quarantine logic or the steps wait on an explicit signal
rather than a fixed tick count, "0 failed" will keep meaning "zero failed
on the one run that got reported," not "the suite is deterministic."

## Gaps closed since the last round — verified, not assumed

- **Stale "not ported yet" comments** (5 locations, 4 files) — read each
  one directly; all five now correctly describe the transport as ported.
  This closes a finding raised in both prior rounds.
- **Swallowed screenshot failures** — `gtk_driver.rb`'s `shot` method now
  adds a failed check on a rescued exception instead of printing and
  continuing. Read the diff directly; the change is real. Did not
  independently trigger a screenshot failure in this round's runs to prove
  the new code path fires in practice, so this is confirmed as a correct
  fix to the code, not confirmed as exercised — a smaller, narrower
  caveat than the main finding above, noted for completeness.
- **Undocumented client-factory scope decision** — `PORTING.md` now exists
  and states the reasoning for leaving `client_factory.rb` unported in
  full, specific, falsifiable detail (no `TpAccountManager`/
  `TpSimpleClientFactory` machinery exists in the socket-transport
  architecture for a factory to intercept). This is exactly the kind of
  accountable scope decision both prior rounds asked for. Closed.
- **No `FINDINGS.md`** — now exists, documents the one known binding
  limitation (`Gtk::Accessible#update_property`'s enum-array marshalling
  gap) in detail, and `main_window.rb`'s inline comment now points to it
  instead of repeating the explanation inline. Closed, after being raised
  twice without action.

## Checked and found clean (re-verified, not carried forward blindly)

```
$ grep -rniE "todo|fixme|not implemented|for now|in a future|not yet|stub" lib/ exe/
(no matches)
```

No port file under `lib/` or `exe/` contains excuse language. This does
not mean these files have no gaps — `component-parity.md` finds several
(seven zero-coverage files, two missing upstream files, no CSS-axis check)
— only that none of them is *excused* in prose. Same as both prior rounds.

- `PORTING.md` and `FINDINGS.md` both now exist and were read in full; both
  contain real, specific technical content, not placeholder text.
- No comment anywhere in `lib/` or `exe/` claims a check passed that was
  not actually run.

## What was not fixed, and is not excused anywhere either

The seven files with zero drive-script coverage
(`search_view.rb`, `networks_manager.rb`, `paste_manager.rb`,
`server_room_manager.rb`, `tab_completion.rb`, `tpl_importer.rb`,
`logger.rb`) are not mentioned in `PORTING.md`, `FINDINGS.md`, or any code
comment as a known, accepted gap — they are simply absent from every drive
script, unchanged across three rounds, and nothing in the repo says so.
This is a smaller version of the same accountability pattern as the
client-factory finding from the last round: silence is not a decision.
Unlike the client-factory case, nobody has yet written down whether these
seven are deliberately out of scope for this round's harness or genuinely
unverified — so, per the task's framing, treat them as gaps, not as an
implicit decision.

The translation layer (`translation-parity.md`) remains a total, unexcused
gap — not mentioned as outstanding work anywhere in `PORTING.md`,
`FINDINGS.md`, or any commit message in this round's range.

## Ranking this round's findings by severity

1. **This round's runtime-gate "0 failed" claim is still a false green**,
   independently reproduced a third time running, under a new symptom this
   time — the fix applied did not generalize to the pattern.
2. **Zero translation infrastructure, zero RSpec specs** — unchanged,
   total gaps, not prose excuses, not mentioned as outstanding anywhere.
3. **7 files with zero check coverage, undocumented as a scope decision**
   — smaller version of a pattern the project has otherwise gotten right
   this round (client factory, binding gap) but not applied here yet.

Closed and verified this round: stale comments, FINDINGS.md, PORTING.md,
the specific screenshot-swallowing bug, the specific join-dialog flake.
Real, substantive work, confirmed by direct re-execution and direct
reading of the diffs — not dismissed by this report.

Clean verdict for this round: **no.** Finding #1 alone is enough to
withhold it, independent of anything in the other four reports, for the
third round running — on a different concrete symptom each time, which is
itself evidence the underlying flakiness has not actually been addressed
at its root.
