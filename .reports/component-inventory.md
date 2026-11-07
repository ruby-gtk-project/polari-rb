# Polari — upstream component inventory

Survey of `origin/main` (GNOME Polari, GJS + GtkBuilder `.ui`) against the
`ruby` branch's `lib/`. Produced with the `component-identification` skill.
No app code was written in this step.

Upstream totals: 25 `.js` source files, 16 `.ui` files, 1 stylesheet
(`data/css/style.css`, ~40 app-defined classes), 1 GSettings schema file
(2 schemas), 2 GResource manifests, 63 locales in `po/`, plus 6 C files in
`src/lib/` that hold the IRC data model (`PolariRoom`, `PolariMessage`) and
the Telepathy glue.

Port totals on `ruby` (re-surveyed 2026-11-07): 28 files under
`lib/polari/` plus `lib/polari.rb` and `lib/polari/rb/version.rb`, ~10,180
lines, and the `data/` assets (`style.css`, `networks.json`, `sparql/`,
`ontologies/`) are in place. **15 of the 18 user-facing units exist**; the
three gaps are `initial_setup.rb` (first-run assistant),
`url_preview.rb` (inline link preview) and `thumbnailer.rb` (the separate
WebKit thumbnailer binary) — unchanged since the 2026-11-02 survey. On the
non-UI side `tpl_importer.rb` (the old-log importer) was ported since,
backed by the `tsparql` gem (`require 'tsparql'`), and a headless drive
harness (`bin/drive` or equivalent — see the dev shell banner) was added.
`telepathy_client.rb`, `client_factory.rb` and the `po/` catalogue are
still missing; `grep -rn "telepathy_client\|client_factory" lib/` finds no
references anywhere in the port, so these are not stubbed, they simply do
not exist yet.

`lib/polari/signals.rb` has no upstream counterpart: it is a support file that
gives plain Ruby objects the signal API upstream gets from GObject. Keep it
out of parity counts.

## Join rule used

A component is the *set* of files: a GJS class and its `.ui` template are one
unit and map to one `lib/polari/*.rb`. `data/ui/main-window.ui` therefore
appears under both the application (it owns `menu hamburgerMenu`) and the main
window (it owns the `Gjs_MainWindow` template).

## Naming

Existing port code is namespaced `module Polari` under `lib/polari/`, so new
files follow `lib/polari/<snake_case>.rb`. Where one upstream file registers
several GObject classes they stay in that one Ruby file as separate classes,
matching the one-upstream-file-to-one-`lib`-file rule.

---

## src/application.js + data/ui/main-window.ui (`menu hamburgerMenu`) — the app object, its actions and its menu

→ `lib/polari/application.rb` — **exists** (409 lines)

| Widget | × | CSS | Signals / Actions | Notes |
|---|---:|---|---|---|
| `Gtk.Application` (upstream `Adw.Application`) | 1 | — | `startup`, `activate`, `dbus-register` | Adwaita::Application is broken in the Ruby bindings; use `Gtk::Application` |
| `Adw.Toast` | 2 | — | — | connection removed (with Undo), link-open failure |
| `Gio.Menu` (hamburger) | 1 | — | 5 items | `app.run-in-background` (stateful), `app.shortcuts`, `app.help`, `app.about`, `app.quit` |
| About dialog | 1 | — | `app.about` | `Adw.AboutDialog`/`AboutWindow` built in source |

Actions installed (31 + 9 generated), with accelerators:

| Action | Param | Accel |
|---|---|---|
| `app.show-join-dialog` | — | `<Primary>n` |
| `app.join-room` | `(ssb)` | — |
| `app.message-user` | `(sssb)` | — |
| `app.leave-room` | `(ss)` | — |
| `app.leave-current-room` | — | `<Primary>w` (starts disabled) |
| `app.reconnect-room` | `s` | — |
| `app.authenticate-account` | `(os)` | — |
| `app.connect-account` / `disconnect-account` / `reconnect-account` | `o` | — |
| `app.mute-nick` / `unmute-nick` | `(ss)` | — |
| `app.user-list` | stateful `b` | `F9`, `<Primary>u` (starts disabled) |
| `app.remove-connection` | `o` | — |
| `app.undo-remove-connection` | `o` | — |
| `app.edit-connection` | `o` | — |
| `app.save-identify-password` / `discard-identify-password` | `o` | — |
| `app.show-emoji-picker` | — | `<Primary>e` |
| `app.start-client` | — | — |
| `app.help` | — | `F1` |
| `app.about` | — | — |
| `app.quit` | — | `<Primary>q` |
| `app.search` | — | `<Primary>s` |
| `app.next-room` / `previous-room` | — | `<Primary>Page_Down`/`<Alt>Down`, `<Primary>Page_Up`/`<Alt>Up` |
| `app.first-room` / `last-room` | — | `<Primary>Home`, `<Primary>End` |
| `app.next-pending-room` / `previous-pending-room` | — | `<Alt><Shift>Down`/`<Primary><Shift>Page_Down`, and the Up pair |
| `app.nth-room` | `i` | `<Alt>1`…`<Alt>9` — nine accels installed in a loop |
| `app.run-in-background` | GSettings-backed | — |

Repeater: `app.nth-room(i)` accelerators, i = 1..9. Conditional:
`user-list` and `leave-current-room` are enabled only with a current room.

## src/mainWindow.js + data/ui/main-window.ui — the main window: sidebar, chat pane, search pane

→ `lib/polari/main_window.rb` — **exists** (620 lines)

| Widget | × | CSS | Signals | Notes |
|---|---:|---|---|---|
| `Adw.ApplicationWindow` | 1 | `test-instance`, `snapshot` (dynamic, dev/snapshot modes) | `notify::maximized`, size persistence | 360×360 minimum; size saved to GSettings |
| `Adw.Breakpoint` | 1 | — | — | collapses the split view on narrow widths |
| `Adw.ToastOverlay` | 1 | — | — | id `overlay` |
| `Adw.NavigationSplitView` | 1 | — | `notify::collapsed` | sidebar + content |
| `Adw.NavigationPage` | 2 | `view` (content page) | — | sidebar page, content page |
| `Adw.ToolbarView` | 3 | — | — | sidebar, chat, search |
| `Adw.HeaderBar` | 3 | — | — | sidebar, chat, `searchHeader` |
| `Gtk.Button` `joinButton` | 1 | `image-button` | `clicked` → `app.show-join-dialog` | `list-add-symbolic`, tooltip "Add Rooms and Networks", a11y label "Add rooms and networks" |
| `Gtk.MenuButton` | 1 | — | — | `open-menu-symbolic`, tooltip "Main Menu", model `hamburgerMenu` |
| `Gtk.ToggleButton` `searchButton` | 1 | — | bound to the search bar | `edit-find-symbolic`, tooltip "Search" |
| `Gtk.SearchBar` + `Gtk.SearchEntry` `searchEntry` | 1 + 1 | — | `search-changed` | placeholder "Search Conversations…" |
| `Gtk.Revealer` `roomListRevealer` | 1 | — | — | hides the room list when offline/empty |
| `Gtk.ScrolledWindow` | 1 | — | — | wraps the room list |
| `Gjs_RoomList` `roomList` | 1 | `polari-room-list`, `navigation-sidebar` | `row-selected` | composite — see room list unit |
| `Gtk.Stack` `viewStack` | 1 | — | — | two pages: chat, search |
| `Gtk.Stack` (title) | 1 | — | — | room title/subtitle vs. search title |
| `Gtk.Label` (titles) | 5 | `title`, `subtitle`, `dim-label` | property bindings on the window | room name, topic, search title |
| `Gtk.ToggleButton` `showUserListButton` + `Adw.ButtonContent` | 1 + 1 | — | `app.user-list` | `people-symbolic`, tooltip "Show Connected Users", user count as label |
| `Adw.Banner` `offlineBanner` | 1 | — | — | "Go online to chat and receive messages." |
| `Adw.Banner` (import) | 1 | — | — | "Importing old conversations — Will be back after conversion" |
| `Gtk.ProgressBar` `importProgress` | 1 | `osd` | — | log-import progress |
| `Gtk.Overlay` | 1 | — | — | banners + progress over the room stack |
| `Gjs_RoomStack` `roomStack` | 1 | — | — | composite |
| `Gjs_SearchView` `searchView` | 1 | — | — | composite |
| `Gjs_UserListPopover` `userListPopover` | 1 | `polari-user-list` | — | 250px wide, bottom position |

Conditional: both banners, the import progress bar, the room-list revealer.
Dynamic CSS: `test-instance` (dev profile), `snapshot` (screenshot mode).
Uses `ngettext` for the user-count accessible name.

## data/ui/shortcuts-dialog.ui — keyboard shortcuts window

→ `lib/polari/shortcuts_dialog.rb` — **exists** (71 lines)

| Widget | × | CSS | Signals | Notes |
|---|---:|---|---|---|
| `Adw.ShortcutsDialog` | 1 | — | `app.shortcuts` | standalone `.ui` with no backing source file |
| `Adw.ShortcutsSection` | 2 | — | — | "General", "Navigation" |
| `Adw.ShortcutsItem` | 16 | — | each names an `app.*` action | General: Join Room, Leave Room, Show Userlist, Toggle Search, Show Emoji Picker, Show Help, Open Menu, Quit, Keyboard Shortcuts. Navigation: Next/Previous Room, Next/Previous Room with Unread Messages, First Room, Last Room, First–Ninth Room |

All titles carry the `shortcut window` gettext context.

## src/roomList.js + data/ui/room-list-row.ui + data/ui/room-list-header.ui — the sidebar room list

→ `lib/polari/room_list.rb` — **exists** (1074 lines)

| Widget | × | CSS | Signals | Notes |
|---|---:|---|---|---|
| `Gtk.ListBox` (`RoomList`) | 1 | `polari-room-list`, `navigation-sidebar` | `row-selected`, `row-activated`, sort/header funcs | one row per room, grouped by account |
| `Gtk.ListBoxRow` (placeholder) | 1 | — | — | empty state when no rooms |
| `Gtk.ListBoxRow` (`RoomRow`) | repeater | `muted`, `inactive`, `has-open-popup` (all dynamic) | `Gtk.GestureClick` (right-click → popover), `Gtk.EventControllerKey` (Menu key) | one per joined room/conversation |
| `Gtk.Box` `box` | 1/row | — | — | |
| `Gtk.Image` `icon` | 1/row | — | — | room icon; `Gio.EmblemedIcon` + `emblem-unreadable` when muted |
| `Gtk.Label` `roomLabel` | 1/row | — | — | room display name |
| `Gtk.Stack` `eventStack` | 1/row | — | — | loading spinner vs. pending counter |
| `Gtk.Image` (loading) | 1/row | `polari-room-loading` | — | `content-loading-symbolic` |
| `Gtk.AspectFrame` + `Gtk.Label` `counter` | 1/row | `pending-messages-count` | — | unread count |
| `Gtk.PopoverMenu` (`RoomRowPopover`) | 1/row | — | `notify::visible` | items: Mute/Unmute (`app.mute-nick`/`app.unmute-nick`, 1:1 chats only), "Leave chatroom" or "End conversation" (`app.leave-room`) |
| `Gtk.Widget` (`RoomListHeader`, css name `row`) | repeater | `room-list-header`, `activatable`, `dim-label` | `Gtk.GestureClick` | one per account; `Gtk.GridLayout` |
| `Gtk.Label` `label` | 1/header | — | — | account/network name |
| `Gtk.Stack` `iconStack` | 1/header | — | — | 5 pages: offline (`network-offline-symbolic`), error, `Adw.Spinner` connecting, password (`dialog-password-symbolic`), menu (`pan-down-symbolic`) |
| `Gtk.Separator` | 1/header | — | — | |
| `Gtk.Popover` `connectionPopover` | 1/header | `menu` | — | account actions |
| `Gtk.Label` `popoverTitle` / `popoverStatus` | 2 | `heading`, `dim-label`, `caption` (all toggled by connection state) | — | |
| `Gtk.Entry` `popoverPassword` | 1 | — | `activate` | identify password |
| `Gtk.ModelButton` | 5 | — | `app.connect-account`, `app.reconnect-account`, `app.disconnect-account`, `app.remove-connection`, `app.edit-connection` | Connect, Reconnect, Disconnect, Remove, Properties |

Repeaters: one `RoomRow` per room, one `RoomListHeader` per account.
Dynamic CSS on rows (`muted`, `inactive`) and on the popover labels.

## src/roomStack.js — the chat pane: per-room views, info bars, empty state

→ `lib/polari/room_stack.rb` — **exists** (376 lines)

| Widget | × | CSS | Signals | Notes |
|---|---:|---|---|---|
| `Gtk.Stack` (`RoomStack`) | 1 | — | room added/removed | one page per room; `Gtk.SizeGroup` (vertical) across entry areas |
| `Gtk.Overlay` (`RoomView`) | repeater | — | — | one per room, named `RoomView <name>` |
| `Adw.ToolbarView` | 1/view | — | — | chat view + entry area |
| `Adw.StatusPage` (loading) | 1/view | — | — | `Adw.SpinnerPaintable` |
| `Gtk.InfoBar` (`MessageInfoBar`) | base | — | `response` | title + subtitle labels, `heading` CSS on the title |
| `SavePasswordConfirmationBar` | 1/1:1 view | — | `app.save-identify-password`, `app.discard-identify-password` | asks to remember the identify password |
| `ChannelErrorBar` | 1/view | — | `app.reconnect-room` | channel join/identify errors |
| `Gtk.Overlay` (`ChatPlaceholder`) | 1 | — | — | **empty state**: `Adw.StatusPage`, icon `org.gnome.Polari-symbolic`, title "Polari", description "Join a room using the + button." |
| `Gtk.Box` (input placeholder) | 1 | — | — | keeps the entry row height in the empty state |

## src/chatView.js — the message log

→ `lib/polari/chat_view.rb` — **exists** (1039 lines)

| Widget | × | CSS | Signals / Actions | Notes |
|---|---:|---|---|---|
| `Gtk.ScrolledWindow` (`ChatView`) | 1 | `polari-chat-view` | `Gio.SimpleActionGroup` `chatlog` | installs `chatlog.open-url`, `chatlog.copy-url` |
| `Gtk.TextView` (`TextView`) | 1 | — | — | subclass; nick column, wrapping |
| `Gtk.TextTag` | many | — | — | nick, timestamp, status, URL, highlight, header-arrow, group tags |
| `Gtk.TextTag` (`ButtonTag`, `HoverFilterTag`) | 2 classes | — | `clicked`, hover tracking | clickable nicks and links |
| `Gtk.Box` (`ExpandButtons`) | 1 | `linked` | `clicked` | two `Gtk.Button`s expanding a status-message group |
| `Gtk.Image` (status indicator) | repeater | `dim-label` | — | |
| `Gtk.PopoverMenu` (URL context menu) | on demand | — | — | items "Open Link", "Copy Link Address"; `has-arrow: false`, pointed at the click |
| controllers | 4 | — | — | `Gtk.EventControllerScroll`, `EventControllerKey`, `EventControllerMotion`, `GestureClick` (secondary) |
| `Gdk.RGBA` | 4 | — | — | active/inactive nick, hovered link, status-header hover |

Uses `ngettext` for collapsed status-message summaries. `MAX_NICK_CHARS = 8`.

## src/entryArea.js + data/ui/entry-area.ui + data/ui/nick-popover.ui — the message entry and paste confirmation

→ `lib/polari/entry_area.rb` — **exists** (569 lines)

| Widget | × | CSS | Signals | Notes |
|---|---:|---|---|---|
| `Gtk.Stack` (`EntryArea`) | 1 | `polari-entry-area`, `view` | — | two pages: entry, paste confirmation |
| `Gtk.ToggleButton` `nickButton` | 1 | `flat`, `polari-nick-button` | toggles the nick popover | tooltip "Change nickname" |
| `Gtk.Label` `nickLabel` | 1 | `polari-active-nick` (dynamic) | — | current nick |
| `Gtk.Entry` (`ChatEntry`) `chatEntry` | 1 | `error` (dynamic, on bad command) | `activate`, `changed`, paste controller | emoji chooser, drop target |
| `Gtk.Popover` (`NickPopover`) | 1 | — | `changeButton.clicked` | label "Change nickname:", `Gtk.Entry` `nickEntry` (`polari-nick-entry`), `Gtk.Button` `changeButton` "_Change" (`suggested-action`) |
| `Gtk.Box` `pasteBox` | 1 | `background`, `polari-paste-confirmation` | — | paste/upload confirmation page |
| `Adw.Bin` + `Adw.Spinner` `uploadSpinner` | 1 | — | — | upload in progress |
| `Gtk.Label` `uploadLabel` / `confirmLabel` | 2 | — | — | `ngettext` for "Paste n lines" / image |
| `Gtk.Revealer` + `Gtk.Box` | 1 | — | — | reveals the buttons |
| `Gtk.Button` `cancelButton` / `pasteButton` | 2 | `suggested-action` (paste) | `clicked` | "_Cancel", "_Paste" |
| `Gtk.EventControllerKey` | 2 | — | — | toplevel key handling, paste shortcut |

## src/userList.js + data/ui/user-list.ui + user-popover.ui + user-details.ui — the connected-users sidebar

→ `lib/polari/user_list.rb` — **exists** (798 lines)

| Widget | × | CSS | Signals | Notes |
|---|---:|---|---|---|
| `Gtk.Popover` (`UserListPopover`) | 1 | `polari-user-list` | — | 250px; `Gtk.Box`, `Gtk.Revealer`, `Gtk.SearchEntry` built in source |
| `Gtk.ScrolledWindow` (`UserList`) | 1 | — | — | template |
| `Gtk.Stack` `stack` | 1 | — | — | list vs. no-results |
| `Gtk.ListBox` `list` | 1 | — | `row-activated` | one row per user |
| `Adw.StatusPage` (no results) | 1 | `compact` | — | **empty state**: `edit-find-symbolic`, "No Results" |
| `Gtk.ListBoxRow` (`UserListRow`) | repeater | `expanded` (dynamic) | `row-activated` toggles the revealer | `Gtk.Box` ×2, `Gtk.Image` `_arrow`, `Gtk.Label`, `Gtk.Revealer` |
| `Gtk.Popover` (`UserPopover`) | 1 | — | — | per-user popover |
| `Gtk.Label` `nickLabel` / `statusLabel` | 2 | `polari-user-popover-nick`, `polari-user-popover-status`, `dim-label`, `polari-active-nick`/`polari-inactive-nick` (dynamic) | — | |
| `Gtk.ToggleButton` `notifyButton` | 1 | — | `toggled` | `polari-user-notify-symbolic`, notify when the user comes online |
| `Gtk.Box` (`UserDetails`) `userDetails` | 1 | — | — | template |
| `Gtk.Box` `spinnerBox` + `Adw.Spinner` + `Gtk.Label` | 1 | — | — | **loading state**: "Loading details" |
| `Gtk.Grid` `detailsGrid` | 1 | — | — | 3 rows |
| `Gtk.Image` | 3 | `dim-label` | — | `document-open-recent-symbolic`, `avatar-default-symbolic`, `polari-user-notify-symbolic` |
| `Gtk.Label` | 5 | `dim-label` | — | "Last Activity:", `lastLabel`, `fullnameLabel`, `notificationLabel` ("Will notify if user appears online.") |
| `Gtk.Separator` | 1 | — | — | |
| `Gtk.ModelButton` `messageButton` / `pastActivityButton` | 2 | — | `app.message-user`, past-activity search | |

## src/connections.js + data/ui/connection-details.ui + connection-properties.ui — network list, network editor, properties dialog

→ `lib/polari/connections.rb` — **exists** (616 lines)

| Widget | × | CSS | Signals | Notes |
|---|---:|---|---|---|
| `Gtk.ScrolledWindow` (`ConnectionsList`) | 1 | — | `row-activated` | |
| `Gtk.ListBox` `_list` | 1 | — | header func → `Gtk.Separator` | |
| `Gtk.Box` + `Gtk.Image` + `Gtk.Label` (placeholder) | 1 | `dim-label` | — | **empty state** for the network list |
| `Gtk.ListBoxRow` (`ConnectionRow`) | repeater | — | `activated` | `Gtk.Box`, name `Gtk.Label`, insensitive-description `Gtk.Label` |
| `Adw.PreferencesPage` (`ConnectionDetails`) | 1 | — | `notify::text` per row | the network editor |
| `Adw.PreferencesGroup` | 2 | — | — | server group, identity group |
| `Adw.EntryRow` `serverRow` | 1 | `error` (dynamic, on invalid input) | — | "_Server Address" |
| `Adw.EntryRow` `nameRow` | 1 | — | — | "Net_work Name" |
| `Adw.SwitchRow` `sslRow` | 1 | — | — | "Use secure c_onnection" |
| `Adw.EntryRow` `nickRow` | 1 | `error` (dynamic) | — | "_Nickname" |
| `Adw.EntryRow` `realnameRow` | 1 | — | — | "_Real Name" |
| `Adw.Dialog` (`ConnectionProperties`) | 1 | — | — | `Adw.ToolbarView` `view`, `Adw.HeaderBar` |
| `Gtk.Button` `cancelButton` / `applyButton` | 2 | `suggested-action` (apply) | `window.close`, apply | "_Cancel", "_Apply" |
| `Gtk.CenterBox` `errorBox` | 1 | `polari-error-information` | — | **error state**: `Gtk.Image` `dialog-error-symbolic` + `Gtk.Label` `errorLabel` |

## src/joinDialog.js + data/ui/join-room-dialog.ui — the join / add-network dialog

→ `lib/polari/join_dialog.rb` — **exists** (366 lines)

| Widget | × | CSS | Signals | Notes |
|---|---:|---|---|---|
| `Adw.Dialog` (`JoinDialog`) | 1 | — | `app.show-join-dialog` | 500×500, default widget `joinButton` |
| `Adw.NavigationView` `navView` | 1 | — | `navigation.push` / `navigation.pop` | three pages |
| `Adw.NavigationPage` `mainPage` | 1 | — | — | "Join Chat Room" |
| `Adw.NavigationPage` `connectionPage` | 1 | — | — | "Add Network" |
| `Adw.NavigationPage` `customPage` | 1 | — | — | "Custom Network" |
| `Adw.ToolbarView` / `Adw.HeaderBar` | 3 / 3 | — | — | one per page |
| `Gtk.Button` | 5 | `suggested-action` (join, add) | `window.close`, `navigation.push`, join | "_Cancel" ×2, "_Join" `joinButton`, "_Add" `addButton`, "_Custom Network" |
| `Gtk.Grid` | 1 | — | — | main page layout |
| `Gtk.Label` | 3 | — | — | "C_onnection", "_Add Network" |
| `Gtk.ComboBoxText` `connectionCombo` | 1 | — | `changed` | account picker |
| `Gtk.Button` `connectionButton` + `Gtk.ShortcutController` + `Gtk.Shortcut` | 1 | — | `navigation.push` | `list-add-symbolic` + label |
| `Gtk.SearchEntry` `filterEntry` | 1 | — | `search-changed` | filters the network list |
| `Gtk.Box` (filter frame) | 2 | `linked`, `frame`, `polari-listbox-filterbar` | — | |
| `Gjs_ConnectionsList` `connectionsList` | 1 | — | — | composite |
| `Gjs_ServerRoomList` `serverRoomList` | 1 | — | — | composite |
| `Gjs_ConnectionDetails` `details` | 1 | — | — | composite |

## src/serverRoomManager.js + data/ui/server-room-list.ui — the room list for one server

→ `lib/polari/server_room_manager.rb` — **exists** (500 lines)

| Widget | × | CSS | Signals | Notes |
|---|---:|---|---|---|
| `Gtk.Box` (`ServerRoomList`) | 1 | `linked`, `frame` | — | template |
| `Gtk.Box` (filter bar) | 1 | `polari-listbox-filterbar` | — | |
| `Gtk.SearchEntry` `filterEntry` | 1 | — | `search-changed` | placeholder "Enter room name to add" |
| `Adw.Bin` + `Adw.Spinner` `spinner` | 1 | — | — | **loading state** while fetching the room list |
| `Gtk.ScrolledWindow` | 1 | — | — | |
| `Gtk.TreeView` `list` | 1 | `polari-server-room-list` | `row-activated` | the Ruby port should use a `Gtk::ListView`/`ColumnView` here — `Gtk.TreeView` is deprecated |
| `Gtk.TreeViewColumn` | 3 | — | — | toggle, name, description |
| `Gtk.CellRendererToggle` `toggleRenderer` | 1 | — | `toggled` | selects a room to join |
| `Gtk.CellRendererText` | 2 | — | — | |
| `Gtk.ListStore` `store` + `Gtk.TreeModelFilter` `modelFilter` | 1 + 1 | — | — | models, not widgets |

## src/initialSetup.js + data/ui/initial-setup-window.ui — first-run setup assistant

→ `lib/polari/initial_setup.rb` — **missing**

| Widget | × | CSS | Signals | Notes |
|---|---:|---|---|---|
| `Gtk.Window` (`InitialSetupWindow`) | 1 | — | — | title "Polari Setup", icon `org.gnome.Polari` |
| `Gtk.HeaderBar` | 1 | — | — | |
| `Gtk.Button` `prevButton` / `nextButton` | 2 | `suggested-action` (dynamic on next) | `clicked` | back / forward |
| `Gtk.Stack` `contentStack` | 1 | — | — | three pages |
| `Adw.StatusPage` (offline) | 1 | — | — | **error state**: `network-offline-symbolic`, "Not connected", "Please connect to the internet to continue the setup." |
| `Adw.StatusPage` (welcome) | 1 | — | — | "Welcome to Polari", "Polari is an easy way to chat using IRC. Select a network to get started." |
| `Adw.Clamp` | 2 | — | — | |
| `Gjs_ConnectionsList` `connectionsList` | 1 | — | — | composite |
| `Gtk.Box` (rooms page) | 1 | `polari-setup-page` | — | |
| `Adw.StatusPage` (rooms) | 1 | — | — | "Welcome to Polari", "Select rooms you want to connect to. You can add more networks and rooms later, by clicking the + button." |
| `Gjs_ServerRoomList` `serverRoomList` | 1 | — | — | composite |

## src/searchView.js + data/ui/search-row.ui + search-section.ui — message search results

→ `lib/polari/search_view.rb` — **exists** (269 lines)

| Widget | × | CSS | Signals | Notes |
|---|---:|---|---|---|
| `Gtk.ScrolledWindow` (`SearchView`) | 1 | — | — | `Gtk.Box` (vertical) built in source |
| `Gtk.Box` (`SearchSection`) | repeater | — | — | one per room with hits |
| `Gtk.Label` `title` | 1/section | `heading` | — | room name |
| `Gtk.ListBox` `list` | 1/section | `boxed-list` | `row-activated` | |
| `Gtk.ListBoxRow` `loadMore` + `Gtk.Image` | 1/section | — | `activated` | `list-add` — pagination |
| `Gtk.ListBoxRow` (`SearchRow`) | repeater | — | `activated` | one per matching message group |
| `Gtk.Label` `date` | 1/row | `dim-label`, `caption` | — | |
| `Gtk.Grid` `messages` | 1/row | — | — | nick + message per line |
| `Gtk.Label` (nick / message) | repeater | `caption-heading`, `caption` | — | |

Backed by the SPARQL queries in `data/sparql/` (`search-messages.rq`,
`count-results.rq`, `get-context.rq`).

## src/ircParser.js — slash commands and their feedback popover

→ `lib/polari/irc_parser.rb` — **exists** (410 lines)

| Widget | × | CSS | Signals | Notes |
|---|---:|---|---|---|
| `Gtk.Popover` (`FeedbackPopover`) | 1 | — | — | command output / errors |
| `Gtk.Stack` | 1 | — | — | label vs. grid output |
| `Gtk.Label` `_feedbackLabel` | 1 | — | — | |
| `Gtk.Grid` `_feedbackGrid` | 1 | — | — | tabular output (e.g. `/help`, `/names`) |
| `Gtk.Label` (grid cells) | repeater | — | — | header row + one per item |
| entry error | — | `error` (dynamic on `_entry`) | — | unknown-command feedback |

`knownCommands` is the translatable command/help table — every entry is a
user-facing string.

## src/tabCompletion.js — nick tab completion popup

→ `lib/polari/tab_completion.rb` — **exists** (292 lines)

| Widget | × | CSS | Signals | Notes |
|---|---:|---|---|---|
| `Gtk.Popover` `_popup` | 1 | — | — | positioned at the caret via `Gdk.Rectangle` |
| `Gtk.ListBox` `_list` | 1 | — | — | single selection |
| `Gtk.ListBoxRow` + `Gtk.Label` | repeater | — | — | one per candidate nick |
| `Gtk.EventControllerKey` / `Gtk.EventControllerFocus` | 2 | — | — | Tab cycling, dismiss on focus-out |

## src/urlPreview.js — inline link preview

→ `lib/polari/url_preview.rb` — **missing**

| Widget | × | CSS | Signals | Notes |
|---|---:|---|---|---|
| `Gtk.Box` (`URLPreview`) | 1 | `url-preview`, `background` | — | |
| `Gtk.Image` `_image` | 1 | `dim-label` (removed once the thumbnail loads) | — | fallback `image-x-generic-symbolic` |
| `Gtk.Label` `_label` | 1 | `dim-label` | — | page title / URL |

## src/pasteManager.js — drag-and-drop and paste target

→ `lib/polari/paste_manager.rb` — **exists** (102 lines)

| Widget | × | CSS | Signals | Notes |
|---|---:|---|---|---|
| `Gtk.DropTargetAsync` | 1 | — | `drop`, `accept` | `DropTargetIface` is a `GObject.Interface` mixed into the entry area |
| `Gdk.ContentFormats` / `ContentFormatsBuilder` | — | — | — | not widgets |

## src/thumbnailer.js — the out-of-process thumbnailer (separate binary)

→ `lib/polari/thumbnailer.rb` — **missing**

| Widget | × | CSS | Signals | Notes |
|---|---:|---|---|---|
| `Gtk.Window` (`PreviewWindow`) | 1 | — | — | offscreen render target for link thumbnails |
| `Gtk.Application` (`App`) | 1 | — | — | its own `main()`; lower priority for the port |

Also embeds a WebKit view to render the page — a dependency the Ruby port may
not have; flag as a deferred/possibly-dropped unit.

## Non-UI units (needed for the UI to do anything)

| Upstream | → port file | Kind | Present |
|---|---|---|---|
| `src/main.js` | `exe/polari` (exists) + `lib/polari.rb` | entry point | partially |
| `src/utils.js` | `lib/polari/utils.rb` | helpers (URL/channel finding, `formatTimePassed`, `formatDateTime`, keyring, Adw.Toast on failed link opens) | yes |
| `src/accountsMonitor.js` | `lib/polari/accounts_monitor.rb` | Telepathy accounts, per-account `Gio.Settings` | yes |
| `src/roomManager.js` | `lib/polari/room_manager.rb` | room registry, `saved-channel-list` | yes |
| `src/networksManager.js` | `lib/polari/networks_manager.rb` | reads `data/networks.json` | yes |
| `src/telepathyClient.js` | `lib/polari/telepathy_client.rb` | the IRC transport; also builds `Gio.Notification`s | **no** |
| `src/userTracker.js` | `lib/polari/user_tracker.rb` | online/offline tracking; installs per-user `Gio.SimpleAction`s in a loop and raises `Gio.Notification`s | yes |
| `src/logger.js` | `lib/polari/logger.rb` | `LogWalker`, `LogImporter`, `LogFinder` over Tracker (via the `tsparql` gem) | yes |
| `src/lib/polari-room.c/.h` | `lib/polari/room.rb` | the room model | yes |
| `src/lib/polari-message.c/.h` | `lib/polari/message.rb` | the message model | yes |
| `src/lib/polari-util.c/.h` | `lib/polari/util.rb` | C helpers (+ `src/tests/test-util.c` has their tests) | yes |
| `src/lib/polari-client-factory.c/.h` | `lib/polari/client_factory.rb` | Telepathy client factory | **no** |
| `src/lib/polari-tpl-importer.c/.h` | `lib/polari/tpl_importer.rb` | old-log importer behind the import banner, Tracker-backed via `tsparql` | **yes** (ported since the 2026-11-02 survey) |
| `data/org.gnome.Polari.gschema.xml` | `lib/polari/settings.rb` | 2 schemas, 11 keys | yes |
| `data/css/style.css` | `data/style.css` loaded by a `Gtk::CssProvider` | stylesheet, ~40 app classes | yes |
| `data/networks.json` | `data/networks.json` | data asset | yes |
| `data/sparql/*.rq`, `data/ontologies/polari.ontology` | `data/sparql/`, `data/ontologies/` | search backend | yes |
| `po/` (63 locales, 31 POTFILES entries) | `po/` | translation catalogue | **no** |

## Notes for the port

- `Adwaita::Application` and `Adwaita::ApplicationWindow` are unreliable in the
  Ruby bindings; the existing stub already uses `Gtk::Application`, and the
  main window should follow the same split (`Gtk::ApplicationWindow` host,
  Adwaita widgets inside) if `Adwaita::ApplicationWindow` misbehaves.
- `Gtk.TreeView`/`Gtk.ListStore`/`Gtk.CellRenderer*` appear only in
  `server-room-list.ui`; the port should use `Gtk::ColumnView` with a
  `SignalListItemFactory`.
- `Gtk.ComboBoxText` (join dialog) and `Gtk.InfoBar` (room stack) are
  deprecated; `Gtk::DropDown` and `Adwaita::Banner`/`Adwaita::Toast` are the
  modern equivalents, but the inventory records upstream as it is.
- `Gtk.ModelButton` (room-list header popover, user details) has no modern
  replacement in a `Gtk::Popover`; plain flat `Gtk::Button`s in a box are the
  usual substitute.
- Upstream depends on Telepathy and Tracker. Neither has Ruby bindings in the
  fork's dev shell, so the transport and search layers are the two real
  blockers for full parity and need a decision before those units are planned.
