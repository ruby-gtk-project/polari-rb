# Test parity — Polari (round 3)

| | |
|---|---|
| Upstream | `main` @ `dc5d9e34` |
| Port | `ruby` @ `c9a99285` |
| Upstream tests | 18 |
| Ported (named, bijective) | 0 |
| Gaps | 18 |
| RSpec suite (`spec/*_spec.rb`) | **0 files — still does not exist** |
| Drive scripts run | `test/drive_polari.rb` (115), `test/drive_initial_setup.rb` (16), `test/drive_telepathy_client.rb` (17) = 148 |

All three drive commands were re-executed in this review (7 total runs of
`drive_polari.rb` alone across two batches), live against `c9a99285`.

## The gate's "0 failed" does not reproduce reliably — still

```
run (batch A, #3): errored step: typing into the entry area and pressing
                    Enter sends the text (NoMethodError: undefined method
                    'entry_area' for nil)
                    errored step: a slash command runs through the IRC
                    parser (same cause)
                    DRIVE FAILED (27)
all other 6 runs:   115 of 115 — DRIVE OK
```

This is the third round in a row this check has caught the gate's "0
failed" overstating the suite's actual reliability. Last round's flake
(`show-join-dialog is enabled`) was fixed this round (animations disabled,
`pump(100)` added after dialog-open calls) — that specific symptom did not
recur in any of the 7 runs here. But a different step now fails
intermittently for a related reason: `room_stack.view_for_room(@room)`
returns `nil` because the room's view is not guaranteed to be registered by
the time the script reaches that step. The fixes this round targeted a
symptom, not the general pattern (steps racing ahead of widget-tree state
under Xvfb), so the suite is flaky in a new way instead of not flaky.

**148, the total, is real** — 115 + 16 + 17 verified by direct arithmetic
on this round's own re-run counts. **0 failed is not a property of the
suite** — same category of finding as both prior rounds, with a new
concrete reproduction.

## There is still no RSpec suite at all

```
$ find spec -name '*_spec.rb'
(no matches)
```

Unchanged since both prior rounds. `spec/spec_helper.rb` still loads a full
`kettle-test` harness that nothing uses. Zero unit-level, no-display tests
exist; the entire test surface remains the three UI-driver scripts.

## Upstream census (unchanged — re-verified)

```
$ .claude/skills/test-parity/scripts/test-census.sh /tmp/polari-upstream-dc5d9e34
```

Still finds **18** test cases in `src/tests/test-util.c`, the only test
file upstream has:

| Group | Cases |
|---|---|
| `/util/base-nick/*` | `basic`, `trailing`, `numeric` (3) |
| `/util/match-nick/*` | `match`, `match2`, `nomatch`, `mixed-case`, `mixed-case2`, `numeric`, `numeric2`, `leading-junk`, `trailing-junk`, `away` (10) |
| `/util/match-identify/*` | `match`, `nomatch`, `case`, `login`, `no-user` (5) |

## Port census

The port's nick-helper checks in `test/drive_polari.rb` (around the
"Util's nick helpers match upstream's documented pinned cases" step) are
unchanged from both prior rounds — still exactly these five:

```ruby
d.check('nick42 is its own base nick') { ... }
d.check('nicky does not match nick') { ... }
d.check('nick does match on its own') { ... }
d.check("identify with no username reports an empty one") { ... }
d.check('IRC colour codes are stripped from topics') { ... }
```

Five checks against eighteen named upstream cases. This round's 20 new
checks in `drive_polari.rb` (95 → 115) are the nick-popover and user-list
expand/collapse checks (`component-parity.md` §4) — none of them touch
`util.rb` or add coverage toward the 18 named upstream cases. **Still
0/18** by the skill's bijective-name definition, unchanged across three
rounds.

| Upstream case | Covered by the port's 5 checks? |
|---|---|
| `base-nick/basic`, `base-nick/trailing` | not individually |
| `base-nick/numeric` | not covered at all |
| `match-nick/*` (10 cases) | one generic `match` + one `nomatch`; the other 8 boundary cases not individually asserted |
| `match-identify/*` (5 cases) | one `no-user` case present; `match`, `nomatch`, `case`, `login` are not |

## Extra

- `test/drive_polari.rb` — 115 checks, now including the nick-popover and
  user-list-expansion checks added this round.
- `test/drive_initial_setup.rb` — 16 checks (was 13; grew with this round's
  widening, stable 2/2 runs this review).
- `test/drive_telepathy_client.rb` — 17 checks (was 15), stable 2/2 runs.

None of the three corresponds to an upstream unit test by name — genuinely
extra and valuable (the telepathy drive script in particular covers ground
upstream's own C suite never touches), but outside the parity count by the
skill's own rule, same as both prior rounds.

## What the gate does not tell you

The suite grew (123 → 148 checks) and one real flake was fixed, but the
suite's reliability property — "0 failed" holds most of the time, not
always — did not change, only which step is the weak point. There is still
no unit-level spec suite despite one being fully wired and unused, and
there is still 0/18 coverage of upstream's documented nick/identify edge
cases. Clean verdict on test parity: no, for the same three reasons as
both prior rounds, with the flakiness finding now independently
reproduced a third time (different symptom each time).
