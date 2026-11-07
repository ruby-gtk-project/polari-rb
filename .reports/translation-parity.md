# Translation parity — Polari

| | |
|---|---|
| Upstream | `main` @ `dc5d9e34` |
| Port | `ruby` @ `b4f6097e` |
| Domain | `polari` (from `meson.project_name()`) |
| Upstream messages | 210 |
| Ported | 0 |
| Gaps | 210 |
| Extra (untranslated) | 0 |
| Upstream occurrences | 223 across 210 messages (8 reused) |
| Port occurrences | 0 |
| Upstream languages | 63 `.po` files, 11,544 translated, 260 untranslated, 32 fuzzy |
| Languages shipped by the port | **0** |
| Unresolved markers (upstream) | 3 — not individually censused by hand in this pass; see below |
| Build command | none — the port has no gettext target |

Generated with `.claude/skills/translation-parity/scripts/catalogue.rb`
against a worktree of `origin/main` (`dc5d9e34`) and the port's working tree:

```
upstream: messages=210 occurrences=223 reused=8 plural=11 with_context=18 unresolved=3
          languages: count=63 translated_strings=11544 untranslated_strings=260 fuzzy_strings=32
port:     messages=0  occurrences=0  reused=0 plural=0 with_context=0  unresolved=0
          languages: count=0
```

## Finding: this is not a partial gap, it is a total one

```
$ grep -rln "gettext\|require 'gettext'\|FastGettext\|_(" lib/ exe/
(no matches)
$ find . -maxdepth 2 -iname po
(nothing)
$ grep -n gettext polari-rb.gemspec Gemfile
(nothing)
```

- No `po/` directory anywhere on `ruby`.
- No gettext gem in the Gemfile or gemspec.
- No `_()`, `N_()`, `n_()`, or any translation marker anywhere in `lib/` or
  `exe/`.
- Every user-visible string in the port — every button label, every dialog
  title, every error message, every menu item — is a bare Ruby string
  literal.

Upstream's 210 messages, 63 languages and 11,544 already-translated strings
are not "mostly inherited with some gaps." They are **entirely absent**. The
port is English-only for every one of its users, including the ~59 of 63
languages where upstream ships 50%+ coverage (`eu`, `fr`, and others well
above 90%, per upstream's own `.po` files).

## The 210 are real, located messages — a sample, not a stub list

The catalogue is sorted by source; a representative slice (full set is in
`/tmp/up-cat.yaml` from this run, regenerable at any time):

| msgid | Kind | Upstream site |
|---|---|---|
| `Message` | single | `data/ui/connection-details.ui` |
| `_Save Password` | single | `data/ui/connection-details.ui` |
| `Add Network` | single | `data/ui/join-room-dialog.ui` |
| `%s removed.` | single | `src/application.js` |
| `_Undo` | single | `src/application.js` |
| `New Messages` | single | `src/roomList.js`(-equiv)/`data/ui/room-list-row.ui` |
| `%d User`/`%d Users` | plural | `data/ui/main-window.ui` |

None of these — not `_Undo`, not `Add Network`, not the plural user-count
string — appears byte-identical (or at all) as a marked string in the port,
because nothing in the port is marked. `lib/polari/application.rb`'s two
`Adw::Toast`s (noted in `component-inventory.md`: connection-removed-with-Undo,
link-open-failure) are built with plain English literals the port wrote
itself, not upstream's `_("%s removed.")` / `_("_Undo")`.

## 3 unresolved markers upstream — not yet censused by hand

`totals.unresolved: 3` in the upstream catalogue means three call sites use
a non-literal argument to a gettext marker and were not read individually in
this pass (per the skill, a non-zero `unresolved` means the catalogue is
incomplete by at least that many messages). This review did not locate and
hand-census those three sites — flagging rather than silently rounding the
210 up or down. **Open**: the true upstream message count is ≥ 210 + up to 3
more, and the port is missing all of them too either way.

## Languages

```
$ diff <(ls /tmp/polari-upstream/po/*.po | xargs -n1 basename) \
       <(ls po/*.po 2>/dev/null)
```

63 files on one side, nothing on the other — the port's `po/` does not
exist, so there is no `LINGUAS` comparison to run and no `.mo` build to
check. `0 of 63` languages reach a port user under any locale.

## Why this matters more than a typical ported-app translation gap

Polari's upstream strings are heavily reused: `_Cancel`/`_Save`-style buttons
and the plural `%d User(s)` string appear across the join dialog, connection
properties and the main window. A single untranslated `_Done` or `_Back` in
the initial-setup window (confirmed hand-written, not marked, in
`lib/polari/initial_setup.rb` — `Back`/`Done` are checked by label text in
`test/drive_initial_setup.rb:…` against bare English strings) is not one
missed string; it is that button, in every one of upstream's 63 languages,
reverting to English the instant a non-English user opens first-run setup.

## Rules check

- No reworded strings were found claiming to "improve" upstream's wording —
  the port did not copy-then-reword; it simply never copied. That is a
  smaller category of sin than rewording, but the practical effect (zero
  translation) is identical.
- No `#{}`-interpolated string is masquerading as translated, because no
  string is marked at all — there is nothing to check for that specific
  anti-pattern yet. It will need checking the day gettext is wired in,
  because the port already builds several count-bearing messages
  (`"#{members} users"` in `lib/polari/main_window.rb:594`,
  `"%s removed."`-equivalent toasts) the exact way the skill warns against:
  by interpolating before any marker could see the string. Fixing the
  translation gap by wrapping these in `_()` as-is would produce a
  catalogue that still cannot be translated, because the interpolated form
  is a different msgid on every call. Flagging this now so the eventual fix
  does not repeat the mistake the skill documents.

## Summary

```
0/210 messages · 0/223 occurrences · 0/63 languages · 0/11,544 strings
```

Parity is not partial. It is zero, in every column, and the port has no
`po/` directory for any translator to contribute to even if someone wanted
to start today.
