# Findings

Binding-level limitations hit while porting polari, recorded here so later
rounds don't rediscover them from scratch. Each entry names the exact error,
where it is worked around, and why the workaround is the narrowest one that
still ports the real behaviour.

## `Gtk::Accessible#update_property` cannot take an enum-typed C array

**Where:** `lib/polari/main_window.rb`, `MainWindow#update_user_list_label`.

**What upstream does:** `src/mainWindow.js` calls
`show_user_list_button.update_property([Gtk.AccessibleProperty.LABEL], [...])`
to give the "show user list" toggle button an accessible label that reports
the current member count (e.g. "3 users").

**What happens in Ruby:** `Gtk::Accessible#update_property`'s C signature
takes a C array of `GtkAccessibleProperty` enum values as one of its
arguments. The ruby-gnome gobject-introspection loader has no marshalling for
an enum-typed C array and raises:

```
NotImplementedError: TODO: in Ruby -> GIArgument(array/C) [interface(enum)](GtkAccessibleProperty)
```

for every call shape tried, including scalar (non-array) arguments. This is a
gap in ruby-gnome's introspection loader, not a mistake in how the port calls
it — the same call, with the same argument shapes, is what upstream's GJS
binding sends over the same C function.

**Workaround:** the call is wrapped in `begin/rescue NotImplementedError` and
the accessible label update is skipped on failure; the visible label
(`user_list_button_content.label = members.to_s`) is unaffected, so the
button still shows the member count, just without the extra screen-reader
text upstream adds. This is the narrowest fix: it loses one accessibility
string rather than skipping the whole method or crashing the window.

**Re-check this** whenever ruby-gnome's gobject-introspection gem is
upgraded — if a future version adds array-of-enum marshalling, delete the
rescue and let the call through unconditionally.
