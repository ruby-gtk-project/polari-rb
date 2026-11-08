# Translation parity — Polari

| | |
|---|---|
| Upstream | `main` @ `dc5d9e34` |
| Port | `ruby` @ `ae37f5b2` |
| Domain | `polari` (from `meson.project_name()`) |
| Upstream messages | 210 |
| Ported | 0 |
| Gaps | 210 |
| Extra (untranslated) | 0 |
| Upstream occurrences | 223 across 210 messages (8 reused) |
| Port occurrences | 0 |
| Upstream languages | 63 `.po` files, 11,544 translated, 260 untranslated, 32 fuzzy |
| Languages shipped by the port | **0** |
| Build command | none — the port has no gettext target |

Re-verified in this round, independently of the prior report's numbers:
the commits since the last pass (`ba78af0a` porting the IRC transport,
`ae37f5b2` fixing the spec helper) touched `lib/polari/telepathy_client.rb`
and `spec/spec_helper.rb` only — neither adds, removes, or wraps a single
translatable string, and no `po/` directory has appeared. The finding below
is unchanged in substance from the last round and is re-confirmed, not
copied forward unchecked:

```
$ grep -c "_(" lib/polari/telepathy_client.rb
0
$ grep -rln "gettext\|require 'gettext'\|FastGettext\|_(" lib/ exe/
(no matches)
$ find . -maxdepth 2 -iname po
(nothing)
$ grep -n gettext polari-rb.gemspec Gemfile
(nothing)
$ git log --oneline <prior-report-commit>..HEAD -- po/ lib/ | grep -i 'i18n\|gettext\|translat'
(nothing)
```

## This is not a partial gap, it is a total one

- No `po/` directory anywhere on `ruby`.
- No gettext gem (`gettext`, `fast_gettext`, `gettext_i18n_rails`, or
  similar) in `Gemfile` or `polari-rb.gemspec`.
- No `_()`, `N_()`, `ngettext()`, or any translation-wrapper call anywhere
  under `lib/` or `exe/`. Every user-facing string in the port — window
  titles, button labels, tooltips, menu items, toast text, dialog copy — is
  a hardcoded English literal.
- Upstream ships 63 languages with real translator work behind them
  (11,544 translated strings across those locales); the port ships the
  infrastructure for exactly one language, with no mechanism to add a
  second.

This is as bad as a translation-parity finding gets: not a dropped msgid
here or there, not a fuzzy string left unreviewed, but the complete absence
of the i18n layer itself. Zero of upstream's 210 messages survived, because
there is nowhere for a surviving message to live.

## Upstream message shape (for scale)

- 210 distinct `msgid`s, 223 call-site occurrences (8 messages used twice —
  mostly shared UI strings like "Cancel"/"Done").
- 18 plural (`ngettext`) forms, 20 strings behind `N_()` (deferred/static),
  and strings carrying a `C_()`-style disambiguating context (the
  shortcuts-dialog titles all carry the `shortcut window` context, per
  `component-inventory.md`).
- 63 shipped `.po` files; the healthiest (e.g. major European languages)
  are fully translated, the newest/smallest locales carry fuzzy or
  untranslated strings — none of that granularity matters to the port's
  score, because the port's score is 0 regardless of upstream's own
  completeness per language.

## What would need to exist for this to move off zero

1. A `po/POTFILES.in`-equivalent list of port files with translatable
   strings, and a `po/` directory.
2. A gettext dependency in the Gemfile, and every user-facing string
   wrapped in `_()` (or the Ruby `gettext` gem's equivalent), including the
   plural and context-carrying ones.
3. At least one actually-translated non-English `.po` file to prove the
   mechanism works end to end, not just that strings are wrapped.

None of the three exists. This finding carries forward unchanged and should
not be marked clean until all three are in place and verified against a
running, non-English locale — not merely against the presence of `_()`
calls in source.
