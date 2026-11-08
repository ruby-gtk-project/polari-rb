# Test parity — Polari

| | |
|---|---|
| Upstream | `main` @ `dc5d9e34` |
| Port | `ruby` @ `ae37f5b2` |
| Upstream tests | 18 |
| Ported (named, bijective) | 0 |
| Gaps | 18 |
| RSpec suite (`spec/*_spec.rb`) | **0 files — does not exist** |
| Drive scripts run | `test/drive_polari.rb`, `test/drive_initial_setup.rb`, `test/drive_telepathy_client.rb` |

All three drive commands were actually re-executed in this review, several
times each, not assumed from the gate's report or from the prior round's
document.

## The gate's "0 failed" does not reproduce — say so plainly

```
run 1: nix develop --command xvfb-run -a ruby test/drive_polari.rb
       94 of 95 checks passed
       failed check: show-join-dialog is enabled
       DRIVE FAILED (1)
run 2: same command — 95 of 95 checks passed, DRIVE OK
run 3: same command — 95 of 95 checks passed, DRIVE OK
```

`test/drive_initial_setup.rb` (13/13, `DRIVE OK` every run) also logged a
non-fatal `RuntimeError: widget produced no render node (not realised
yet?)` while taking one screenshot — swallowed by the harness before it
could count as a failed check, so it never shows up in the pass count, but
it is evidence the suite is running closer to the edge of stable than
"123 passed, 0 failed" suggests.

`test/drive_telepathy_client.rb` was stable across two runs: 15/15 both
times, `DRIVE OK`. Totals: 95 + 13 + 15 = **123**, matching this round's
stated gate figure — the total is real. The "0 failed" is not reliably
real; see `component-parity.md` §2 and `accountability-ensurance.md` for
why a flaky check reported as a clean pass is this round's most serious
finding, worse than any of the gaps below.

## There is no RSpec suite at all

```
$ find spec -name '*_spec.rb'
(no matches)
```

`spec/spec_helper.rb` and `spec/README.md` describe a full `kettle-test`
harness (env stubbing, time travel, output capture, rake-task context) and
it loads cleanly, but **nothing uses it** — zero spec files exist. The
entire test surface of this port is the three `test/drive_*.rb` UI-driver
scripts; there is no unit-level suite that runs without a display at all,
despite the harness for one being fully wired up and unused. A harness that
loads but asserts nothing is a gap, not infrastructure in progress — it has
never been run with anything in it, so "the kettle-test suite" cannot be
claimed as even partial coverage.

## Upstream census

```
$ .claude/skills/test-parity/scripts/test-census.sh /tmp/polari-upstream
```

finds **18** test cases, all `g_test_add_func` in `src/tests/test-util.c`
(the only test file upstream has — no `test-room.c`, `test-message.c`;
`polari-room.c`/`polari-message.c` are untested upstream too):

| Group | Cases |
|---|---|
| `/util/base-nick/*` | `basic`, `trailing`, `numeric` (3) |
| `/util/match-nick/*` | `match`, `match2`, `nomatch`, `mixed-case`, `mixed-case2`, `numeric`, `numeric2`, `leading-junk`, `trailing-junk`, `away` (10) |
| `/util/match-identify/*` | `match`, `nomatch`, `case`, `login`, `no-user` (5) |

18 cases, one file; `meson.build`'s `tests/` target registers exactly this
one binary — cross-checked, no discrepancy.

## Port census

The port's 123 checks live in the three drive scripts above, driving the
live app through `GtkDriver`, not a unit-test framework, and none maps its
checks to upstream's 18 test names by name. The one place the port
acknowledges upstream's suite exists at all is still `test/drive_polari.rb`
around step 54 (nick-helper checks):

```ruby
d.check('nick42 is its own base nick') { Polari::Util.get_basenick('nick42') == 'nick42' }
d.check('nicky does not match nick') { !Polari::Util.match_nick('nicky is here', 'nick') }
d.check('nick does match on its own') { ... }
d.check("identify with no username reports an empty one") { ... }
d.check('IRC colour codes are stripped from topics') { ... }
```

Five checks against eighteen named upstream cases — unchanged since last
round; the transport port did not touch `util.rb` or its checks.

| Upstream case | Covered by the port's 5 checks? |
|---|---|
| `base-nick/basic`, `base-nick/trailing` | not individually |
| `base-nick/numeric` | not covered at all |
| `match-nick/match`, `match2`, `mixed-case`, `mixed-case2`, `numeric`, `numeric2`, `leading-junk`, `trailing-junk`, `away` | one generic `match` + one `nomatch`; the other 8 boundary cases are not individually asserted |
| `match-identify/match`, `nomatch`, `case`, `login`, `no-user` | one `no-user` case present; `match`, `nomatch`, `case`, `login` are not |

By the skill's bijective-name definition this is **0/18**, not partial
credit, unchanged from last round.

## Extra

- `test/drive_polari.rb` — 95 checks on the live window: connections, join
  dialog, room list, chat view, entry area, user list, settings
  persistence, toast undo, geometry restore.
- `test/drive_initial_setup.rb` — 13 checks on the first-run window.
- `test/drive_telepathy_client.rb` — 15 checks against a real IRC wire
  protocol on a loopback socket. New since last round, and the strongest
  test file in the port — this is the one place "extra" coverage is
  actually deeper than what upstream's C suite does (upstream has no
  integration test of the Telepathy transport at all).

None of the three corresponds to an upstream unit test — genuinely extra,
and valuable, but outside the parity count by the skill's own rule.

## What the gate does not tell you

The gate is a real, substantial UI/integration regression harness, newly
including a transport-level one. It still inherits none of upstream's
documented edge cases for nick/identify matching (0/18, unchanged), has no
unit-level spec suite despite one being fully set up and unused, and — new
this round — does not reproduce its own "0 failed" claim reliably. Three
different, independent reasons this port's test posture is weaker than
"123 checks passed" implies on its own.
