# Test parity — Polari

| | |
|---|---|
| Upstream | `main` @ `dc5d9e34` |
| Port | `ruby` @ `b4f6097e` |
| Upstream tests | 18 |
| Ported (named, bijective) | 0 |
| Gaps | 18 |
| Test command run | `nix develop --command xvfb-run -a ruby test/drive_polari.rb` and `...test/drive_initial_setup.rb` |

Both commands were actually re-executed in this review (not assumed from the
gate's report): `95 of 95 checks passed` / `DRIVE OK` and
`13 of 13 checks passed` / `DRIVE OK`, 108 total — confirming the runtime
gate's number is real, not a stale or fabricated claim. That is the one
clean result in this document: **the gate itself did not lie.**

But "108 checks pass" and "test parity" are different claims, and the census
below is against the second.

## Upstream census

```
$ .claude/skills/test-parity/scripts/test-census.sh /tmp/polari-upstream
```

finds **18** test cases, all `g_test_add_func` in `src/tests/test-util.c`
(the only test file upstream has — there is no `src/tests/test-room.c`,
`test-message.c`, etc.; `polari-room.c`/`polari-message.c` are untested
upstream too):

| Group | Cases |
|---|---|
| `/util/base-nick/*` | `basic`, `trailing`, `numeric` (3) |
| `/util/match-nick/*` | `match`, `match2`, `nomatch`, `mixed-case`, `mixed-case2`, `numeric`, `numeric2`, `leading-junk`, `trailing-junk`, `away` (10) |
| `/util/match-identify/*` | `match`, `nomatch`, `case`, `login`, `no-user` (5) |

18 cases, one file, `meson.build`'s `tests/` target registers exactly this
one binary — cross-checked, no discrepancy.

## Port census

The port's 108 checks live in `test/drive_polari.rb` (95) and
`test/drive_initial_setup.rb` (13), both driving the live app through
`GtkDriver`, not a unit-test framework, and neither file maps its checks to
upstream's 18 test names. The one place the port acknowledges upstream's
suite exists at all:

```ruby
# test/drive_polari.rb:563-571 (step 54)
d.check('nick42 is its own base nick') { Polari::Util.get_basenick('nick42') == 'nick42' }
d.check('nicky does not match nick') { !Polari::Util.match_nick('nicky is here', 'nick') }
d.check('nick does match on its own') { ... }
d.check("identify with no username reports an empty one") { ... }
d.check('IRC colour codes are stripped from topics') { ... }
```

Five checks, under one step headed "Util's nick helpers match upstream's
documented pinned cases." That is five assertions against eighteen named
upstream cases:

| Upstream case | Covered by the port's 5 checks? |
|---|---|
| `base-nick/basic`, `base-nick/trailing` | not individually — one generic basenick check, not these two literal inputs (`"nick"` → `"nick"`, `"nick_"` → `"nick"`) |
| `base-nick/numeric` | not covered — no numeric-suffix basenick case in the port at all |
| `match-nick/match`, `match2`, `mixed-case`, `mixed-case2`, `numeric`, `numeric2`, `leading-junk`, `trailing-junk`, `away` | one `match` case and one `nomatch` case present; the other 8 distinct boundary cases (case-insensitivity, numeric suffixes, junk around the nick, the away-message variant) are not individually asserted |
| `match-identify/match`, `nomatch`, `case`, `login`, `no-user` | one `no-user` case present (`identify with no username...`); `match`, `nomatch`, `case`, `login` are not |

None of the 18 upstream test names has a 1:1 named counterpart anywhere in
the port. The port's 5 ad-hoc checks happen to overlap the *kind* of thing
2-3 of the 18 pin, by coincidence of also testing nick matching, but the
skill's definition of `ported` requires a named port test that pins the same
property — not "the port also has something that touches nicks." By that
definition this is **0/18**, not partial credit.

## Ledger

| # | Upstream test | Purpose | Port test | State |
|---|---|---|---|---|
| 1 | `/util/base-nick/basic` | plain nick with no trailing junk is its own base | — | **gap** |
| 2 | `/util/base-nick/trailing` | trailing `_`/digits stripped to find the base nick | — | **gap** |
| 3 | `/util/base-nick/numeric` | a nick that is itself numeric-suffixed strips correctly | — | **gap** |
| 4 | `/util/match-nick/match` | exact nick match in a message | `drive_polari.rb:570` (overlaps, unnamed) | **gap** (no bijective name) |
| 5 | `/util/match-nick/match2` | second match fixture | — | **gap** |
| 6 | `/util/match-nick/nomatch` | substring that is not the nick does not match | `drive_polari.rb:566` (overlaps, unnamed) | **gap** (no bijective name) |
| 7 | `/util/match-nick/mixed-case` | case-insensitive match | — | **gap** |
| 8 | `/util/match-nick/mixed-case2` | second case-insensitive fixture | — | **gap** |
| 9 | `/util/match-nick/numeric` | nick with numeric suffix matches | — | **gap** |
| 10 | `/util/match-nick/numeric2` | second numeric fixture | — | **gap** |
| 11 | `/util/match-nick/leading-junk` | punctuation before the nick does not block a match | — | **gap** |
| 12 | `/util/match-nick/trailing-junk` | punctuation after the nick does not block a match | — | **gap** |
| 13 | `/util/match-nick/away` | nick mentioned inside an away message still matches | — | **gap** |
| 14 | `/util/match-identify/match` | identify-string matches the given login | — | **gap** |
| 15 | `/util/match-identify/nomatch` | identify-string does not match a different login | — | **gap** |
| 16 | `/util/match-identify/case` | identify match is case-insensitive | — | **gap** |
| 17 | `/util/match-identify/login` | login portion extracted correctly | — | **gap** |
| 18 | `/util/match-identify/no-user` | empty/missing username reports empty, not a crash | `drive_polari.rb:569` (overlaps, unnamed) | **gap** (no bijective name) |

Every row above carries "behaviour still owed": the specific boundary case
(numeric suffix, mixed case, leading/trailing punctuation, the away-message
variant, the four distinct identify-match shapes) that upstream pinned and
that the port's generic nick-handling could silently regress without any
check catching it, because none of these specific inputs is asserted
anywhere in the port.

## Extra

- `test/drive_polari.rb` — 95 checks driving the live window: connections,
  join dialog, room list, chat view, entry area, user list, settings
  persistence, toast undo, geometry restore. None of these corresponds to an
  upstream unit test (upstream has none for these areas) — genuinely extra,
  and valuable, but outside the parity count by the skill's own rule.
- `test/drive_initial_setup.rb` — 13 checks on the first-run window. Same:
  no upstream test exists for this to have parity with.

## What the 108-check gate does not tell you

The gate is a real, substantial regression harness for the *UI*. It inherits
**none** of upstream's documented edge cases for nick/identify matching,
because it was written from scratch rather than from upstream's test file.
`test-parity` and the runtime gate are different claims; this port passes
the second and fails the first, 0/18.
