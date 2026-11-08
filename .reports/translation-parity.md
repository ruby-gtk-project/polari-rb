# Translation parity — Polari (round 3)

| | |
|---|---|
| Upstream | `main` @ `dc5d9e34` |
| Port | `ruby` @ `c9a99285` |
| Domain | `polari` |
| Upstream messages | 210 |
| Ported | 0 |
| Gaps | 210 |
| Upstream languages | 63 `.po` files |
| Languages shipped by the port | **0** |
| Build command for translations | none — no gettext target exists |

Re-verified independently in this round, from scratch, not copied forward:

```
$ find . -maxdepth 2 -iname po
(nothing)
$ grep -rln "gettext\|FastGettext\|_(" lib/ exe/
(no matches)
$ grep -n gettext polari-rb.gemspec Gemfile
(nothing)
$ git diff ae37f5b2..HEAD --stat -- po/ lib/ exe/ Gemfile polari-rb.gemspec
 lib/polari/accounts_monitor.rb    | 6 +-
 lib/polari/irc_parser.rb          | 3 +-
 lib/polari/main_window.rb         | 10 +-
 lib/polari/room.rb                | 6 +-
 lib/polari/server_room_manager.rb | 7 +-
```

Every one of this round's commits that touched `lib/` changed only comment
text (the stale "not ported yet" fixes and the FINDINGS.md pointer) — none
of them is a translatable-string change, confirmed by reading each diff
directly rather than trusting the stat summary. No `po/` directory, no
gettext dependency, no `_()` call anywhere, exactly as both prior rounds
found.

## This is still not a partial gap — it is a total one, unchanged

- No `po/` directory anywhere on `ruby`.
- No gettext/fast_gettext gem in `Gemfile` or `polari-rb.gemspec`.
- No `_()`, `N_()`, `ngettext()`, or any translation wrapper under `lib/`
  or `exe/`. Every user-facing string in the port remains a hardcoded
  English literal.
- Upstream ships 63 languages (11,544 translated strings); the port ships
  the infrastructure for exactly one language, unchanged.

Nothing in this round's work — flakiness fixes, stale-comment corrections,
FINDINGS.md, PORTING.md — touches this axis at all, and none of the three
reports this round's audit produced claims otherwise. This is the third
consecutive round where the finding is identical in substance: zero of
upstream's 210 messages survive, because there is nowhere for a surviving
message to live.

## What would need to exist for this to move off zero (unchanged)

1. A `po/` directory and a POTFILES-equivalent list of port files with
   translatable strings.
2. A gettext dependency in the Gemfile, and every user-facing string
   wrapped in `_()` (or equivalent), including plural and context-carrying
   forms.
3. At least one actually-translated non-English `.po` file verified
   against a running, non-English locale.

None of the three exists after three rounds of audit. This finding should
not be marked clean until all three are in place and independently
verified running, not merely present in source.
