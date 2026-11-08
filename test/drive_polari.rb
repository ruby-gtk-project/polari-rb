# frozen_string_literal: true

# Drives the whole app headlessly: builds the main window, creates an
# account, walks every page of the join dialog, joins a room over a fake
# IRC channel, drives messages and the member list, exercises search, the
# user-list popover, the shortcuts and about dialogs, connection removal and
# its undo, the connection-properties editor, the accelerators the
# application installs, and the window-geometry round trip on close, then
# returns to the empty state exactly as it started.
#
# Why this file exists: a GTK app that loads is not a GTK app that works.
# `ruby -c` passes on code that builds an empty window, and the Ruby
# bindings differ from the C API in ways that only a run reveals — the
# first run of this script found that
# Gtk::Accessible#update_property cannot marshal a C array of
# GtkAccessibleProperty enums at all (TODO: in Ruby -> GIArgument(array/C)
# [interface(enum)](GtkAccessibleProperty)), which meant the port's main
# window had never been built successfully by anyone.
#
# Run it from the repository root:
#
#   nix develop --command xvfb-run -a ruby test/drive_polari.rb
#
# There is no Telepathy here (the port has none ported yet — see
# Application's own comment), so accounts and rooms are driven through the
# plain-Ruby models directly, and "the IRC transport" is a small FakeChannel
# below that implements only what Room, ChatView and UserTracker ask of a
# TpTextChannel: a signal interface, members, send_text and set_subject.

require 'fileutils'
require 'tmpdir'

# Scratch config and data directories, so a run never reads or writes the
# real ones — the data dir in particular is where the one-time-action
# marker (see Utils.needs_onetime_action?) and the imported chat log store
# live.
ENV['XDG_CONFIG_HOME'] = Dir.mktmpdir('polari-drive-config')
ENV['XDG_DATA_HOME'] = Dir.mktmpdir('polari-drive-data')

$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))

require 'polari'
require_relative 'gtk_driver'

# This driver exercises the main window, not the first-run assistant (see
# test/drive_initial_setup.rb for that), so mark first-run setup as already
# done the way a returning user's machine would have it.
Polari::Utils.needs_onetime_action?('initial-setup')

SHOTS = File.expand_path('../tmp/shots', __dir__)
FileUtils.rm_rf(SHOTS)

# Turns the main loop over for `ms` milliseconds and comes back, the way
# tally-rb's driver does — a resize to a split-view window with a content
# clamp takes more than one frame to settle, and default_width lags behind
# the requested size until it does.
def pump(ms)
  (Process.clock_gettime(Process::CLOCK_MONOTONIC) + (ms / 1000.0)).then do |deadline|
    while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
      GLib::MainContext.default.iteration(false)
    end
  end
end

# A stand-in for the TpTextChannel the real IRC transport would hand to
# Room#channel=. Room, ChatView and UserTracker only ever call the methods
# below (see lib/polari/room.rb's #connect_channel and #members, and
# lib/polari/user_tracker.rb's #track_initial_members), so this is the
# entire surface a fake has to cover.
class FakeMember
  include Polari::Signals

  attr_reader :alias

  def initialize(nick)
    @alias = nick
  end

  def to_s = @alias
end

class FakeChannel
  include Polari::Signals

  attr_reader :account, :identifier, :handle_type, :sent, :subjects
  attr_accessor :self_nick

  def initialize(account:, identifier:, handle_type: :room)
    @account = account
    @identifier = identifier
    @handle_type = handle_type
    @members = []
    @sent = []
    @subjects = []
    @self_nick = account.nickname
    @invalidated = false
  end

  def members = @members

  def target_contact = nil

  def subject = @subjects.last.to_s

  def set_subject(topic)
    @subjects << topic
    emit('notify::subject')
  end

  def send_text(text)
    @sent << text
  end

  def send_action(text)
    @sent << text
  end

  def add_members(new_members)
    added = new_members.map { |m| m.is_a?(FakeMember) ? m : FakeMember.new(m.to_s) }
    @members += added
    emit('group-contacts-changed', { added: added, removed: [] })
  end

  def remove_members(removed_members)
    @members -= removed_members
    emit('group-contacts-changed', { removed: removed_members, added: [] })
  end

  def message_sent(text)
    emit('message-sent', text)
  end

  def invalidate
    @invalidated = true
    emit('invalidated')
  end

  def invalidated? = @invalidated
end

GtkDriver.drive(Polari::Application.new, shots: SHOTS) do |d, polari_app|
  d.window { polari_app.window }

  d.step('the window builds and shows the empty state') do
    d.check('the window is a Polari::MainWindow') { polari_app.window.is_a?(Polari::MainWindow) }
    d.check('it is the only toplevel') { Gtk::Window.list_toplevels.length == 1 }
    d.check('its title is Polari') { polari_app.window.title == 'Polari' }
    d.check('its icon is the application id') { polari_app.window.icon_name == 'org.gnome.Polari' }
    d.check('the room list is hidden with no accounts') do
      !polari_app.window.room_list_revealer.reveal_child?
    end
    d.check('the join button is wired to the app action') do
      polari_app.window.join_button.action_name == 'app.show-join-dialog'
    end
    d.check('the conversation page is showing') do
      polari_app.window.view_stack.visible_child_name == 'conversation'
    end
    d.shot('01-empty')
  end

  d.step('the application installed upstream-equivalent accelerators') do
    accels = {
      'app.show-join-dialog'      => ['<Primary>n'],
      'app.leave-current-room'    => ['<Primary>w'],
      'app.user-list'             => %w[F9 <Primary>u],
      'app.show-emoji-picker'     => ['<Primary>e'],
      'app.help'                  => ['F1'],
      'app.shortcuts-dialog'      => ['<Primary>question'],
      'app.quit'                  => ['<Primary>q'],
      'app.search'                => ['<Primary>s'],
    }
    accels.each do |action, expected|
      d.check("#{action} is #{expected.first}") do
        polari_app.app.get_accels_for_action(action).map { |a| Gtk.accelerator_parse(a) } ==
          expected.map { |a| Gtk.accelerator_parse(a) }
      end
    end
    d.check('app.nth-room(3) is <Alt>3') do
      polari_app.app.get_accels_for_action('app.nth-room(3)').map { |a| Gtk.accelerator_parse(a) } ==
        ['<Alt>3'].map { |a| Gtk.accelerator_parse(a) }
    end
    d.check('every ACTIONS entry is a real action on the application') do
      Polari::Application::ACTIONS.all? { |entry| polari_app.app.lookup_action(entry[:name]) }
    end
  end

  d.step('creating an account reveals the sidebar') do
    Polari::AccountsMonitor.default.create_account(
      display_name: 'Test Network',
      parameters:   { 'server' => 'irc.example.org', 'account' => 'tester' },
      nickname:     'tester',
    )
  end

  d.step('the sidebar came up for the new account') do
    d.check('one account exists') { Polari::AccountsMonitor.default.accounts.length == 1 }
    d.check('its nickname came from create_account') do
      Polari::AccountsMonitor.default.accounts.first.nickname == 'tester'
    end
    d.check('the room list is revealed now') { polari_app.window.room_list_revealer.reveal_child? }
    d.shot('02-account-created')
  end

  ACCOUNT = -> { Polari::AccountsMonitor.default.accounts.first }

  d.step('app.show-join-dialog opens the join dialog on its main page') do
    polari_app.app.activate_action('show-join-dialog', nil)
  end

  d.step('the join dialog shows the one account and an insensitive Join') do
    polari_app.window.join_dialog.then do |dialog|
      d.check('a Polari::JoinDialog is up') { dialog.is_a?(Polari::JoinDialog) }
      d.check('it reports it has accounts') { dialog.accounts? }
      d.check('it starts on the main page') { dialog.nav_view.visible_page.equal?(dialog.main_page) }
      d.check('the connection combo lists the account') do
        dialog.connection_combo.active_text == 'Test Network'
      end
      d.check('Join starts out insensitive') { !dialog.join_button.sensitive? }
      # The dialog's open animation runs on the frame clock, not synchronously
      # with activating the action, same reason 05/12's shots pump first (see
      # this file's 'run' comment on turning animations off — that covers
      # AdwDialog's close animation, not the present/open one here).
      pump(100)
      d.shot('03-join-dialog-main')
    end
  end

  d.step('the connection button pushes the Add Network page') do
    polari_app.window.join_dialog.connection_button.signal_emit('clicked')
  end

  d.step('the Add Network page is up, offering the one predefined network group') do
    polari_app.window.join_dialog.then do |dialog|
      d.check('the nav view pushed the connection page') do
        dialog.nav_view.visible_page.equal?(dialog.connection_page)
      end
      d.check('Cancel can pop back out') { dialog.connection_page.can_pop? }
      d.shot('04-join-dialog-networks')
    end
  end

  d.step('the custom-network button pushes the Custom Network page') do
    polari_app.window.join_dialog.custom_network_button.signal_emit('clicked')
  end

  d.step('filling the custom-network form and pressing Add creates an account') do
    polari_app.window.join_dialog.then do |dialog|
      d.check('the custom page is up') { dialog.nav_view.visible_page.equal?(dialog.custom_page) }
      details = dialog.details
      details.server_row.text = 'irc.custom.example'
      details.name_row.text = 'Custom Net'
      details.nick_row.text = 'custom-nick'
      d.check('the form reports it can confirm now') { details.can_confirm? }
      pump(100)
      d.shot('05-join-dialog-custom', dialog)
      dialog.add_button.signal_emit('clicked')
      d.check('a second account now exists') { Polari::AccountsMonitor.default.accounts.length == 2 }
      d.check('it carries the form values') do
        created = Polari::AccountsMonitor.default.accounts.find { |a| a.display_name == 'Custom Net' }
        !created.nil? && created.nickname == 'custom-nick' &&
          created.parameters['server'] == 'irc.custom.example'
      end
      d.check('add_button popped back to the main page') do
        dialog.nav_view.visible_page.equal?(dialog.main_page)
      end
    end
  end

  d.step('closing the dialog restores app.show-join-dialog') do
    polari_app.window.join_dialog.cancel_button.signal_emit('clicked')
  end

  d.step('the dialog is gone and the action is enabled again') do
    d.check('no dialog is tracked any more') { polari_app.window.join_dialog.nil? }
    d.check('show-join-dialog is enabled') { polari_app.app.lookup_action('show-join-dialog').enabled? }
  end

  d.step('app.join-room creates and presents a room') do
    polari_app.app.lookup_action('join-room').activate(
      GLib::Variant.new([ACCOUNT.call.object_path, '#polari']),
    )
  end

  d.step('the room is active and the window retitled') do
    d.check('one room exists') { Polari::RoomManager.default.rooms.length == 1 }
    room = Polari::RoomManager.default.rooms.first
    d.check('it is a #polari room') { room.channel_name == '#polari' && room.room? }
    d.check('the window made it the active room') { polari_app.window.active_room.equal?(room) }
    d.check('the window title is the room') { polari_app.window.title == room.display_name }
    d.check('the saved-channel-list remembered it') do
      Polari::Settings.default['saved-channel-list'].any? { |c| c['channel'] == '#polari' }
    end
    d.shot('06-room-active')
  end

  d.step('attaching a fake channel connects the room to a live conversation') do
    @room = Polari::RoomManager.default.rooms.first
    @channel = FakeChannel.new(account: ACCOUNT.call, identifier: '#polari')
    @room.channel = @channel
  end

  d.step('the chat pane is sensitive now that the channel is live') do
    d.check('the room reports a live channel') { !@room.channel.nil? }
    view = polari_app.window.room_stack.view_for_room(@room)
    d.check('the room has a view in the stack') { !view.nil? }
    d.check('its entry area can be typed into') { view.entry_area.sensitive? }
  end

  d.step('a message arrives and is inserted into the chat log') do
    @channel.add_members([FakeMember.new('alice')])
    message = Polari::Message.new(text: 'hello from alice', sender: 'alice', time: Time.now.utc)
    polari_app.window.room_stack.view_for_room(@room).chat_view.message_received(message)
  end

  d.step('the chat view shows the message and the member list shows alice') do
    chat_view = polari_app.window.room_stack.view_for_room(@room).chat_view
    buffer_text = chat_view.buffer.text
    d.check('the message text is in the buffer') { buffer_text.include?('hello from alice') }
    d.check('the sender is in the buffer') { buffer_text.include?('alice') }
    d.check('the room has one member') { @room.members.length == 1 }
    d.check('the member is alice') { @room.members.first.alias == 'alice' }
    d.shot('07-message-received')
  end

  d.step('clicking alice\'s nick in the chat log opens her user popover') do
    chat_view = polari_app.window.room_stack.view_for_room(@room).chat_view
    # Stands in for the real click the chat log's gesture controller would
    # see (see test/drive_polari.rb's FakeChannel comment) — build_nick_popover
    # is the exact method show_nick_popover calls to construct what the click
    # opens.
    @nick_popover = chat_view.send(:build_nick_popover)
    @nick_popover.nickname = 'alice'
  end

  d.step('the nick popover carries alice\'s nickname') do
    d.check('a Polari::UserPopover was built') { @nick_popover.is_a?(Polari::UserPopover) }
    d.check('its nickname is alice') { @nick_popover.nickname == 'alice' }
    # Unparent it: a real click pops it down (the real show_nick_popover
    # caches and reuses one per tag instead of building a new one each
    # time), and a popover left parented to the text view with no
    # corresponding popup would otherwise sit around as a stray child for
    # every later layout pass this script drives.
    @nick_popover.unparent
  end

  d.step('typing into the entry area and pressing Enter sends the text') do
    view = polari_app.window.room_stack.view_for_room(@room)
    view.entry_area.chat_entry.text = 'hi there'
    view.entry_area.chat_entry.signal_emit('activate')
  end

  d.step('the fake channel received the message and the entry cleared') do
    d.check('the channel got the text') { @channel.sent.include?('hi there') }
    view = polari_app.window.room_stack.view_for_room(@room)
    d.check('the entry is empty again') { view.entry_area.chat_entry.text.empty? }
  end

  d.step('a slash command runs through the IRC parser') do
    view = polari_app.window.room_stack.view_for_room(@room)
    view.entry_area.irc_parser.process('/me waves')
  end

  d.step('/me sent an action, not a plain message') do
    d.check('the channel got the /me text') { @channel.sent.include?('waves') }
  end

  d.step('/topic sets the room subject through the channel') do
    view = polari_app.window.room_stack.view_for_room(@room)
    view.entry_area.irc_parser.process('/topic Welcome to the test channel')
  end

  d.step('the fake channel recorded the new subject') do
    d.check('set_subject was called with the text') do
      @channel.subjects.include?('Welcome to the test channel')
    end
  end

  d.step('typing a partial nick and pressing Tab completes it') do
    view = polari_app.window.room_stack.view_for_room(@room)
    view.entry_area.chat_entry.text = 'ali'
    view.entry_area.chat_entry.position = view.entry_area.chat_entry.text.length
    # Stands in for the real keypress TabCompletion's key controller would
    # see — see test/drive_polari.rb's FakeChannel comment for why this
    # port's drive scripts stand in for a UI gesture with the handler it
    # would trigger.
    view.entry_area.completion.send(:on_key_pressed, Gdk::Keyval::KEY_Tab)
  end

  d.step('the nick was completed from the one member in the room') do
    view = polari_app.window.room_stack.view_for_room(@room)
    d.check('the entry now reads the completed nick') { view.entry_area.chat_entry.text == 'alice: ' }
    view.entry_area.chat_entry.text = ''
  end

  d.step('pasting multiple lines of text opens the paste confirmation page') do
    view = polari_app.window.room_stack.view_for_room(@room)
    view.entry_area.paste_text("line one\nline two", 2)
  end

  d.step('the entry area switched to its paste-confirmation page') do
    view = polari_app.window.room_stack.view_for_room(@room)
    d.check('confirmation_visible? reports true') { view.entry_area.confirmation_visible? }
    d.check('the confirm label mentions the line count') { view.entry_area.confirm_label.label.include?('2') }
    d.check('Cancel and Paste are both sensitive') do
      view.entry_area.cancel_button.sensitive? && view.entry_area.paste_button.sensitive?
    end
    d.shot('07b-paste-confirmation')
  end

  d.step('Cancel dismisses the paste confirmation without uploading anything') do
    view = polari_app.window.room_stack.view_for_room(@room)
    view.entry_area.cancel_button.signal_emit('clicked')
  end

  d.step('the entry area is back on its default page and nothing was sent') do
    view = polari_app.window.room_stack.view_for_room(@room)
    d.check('confirmation_visible? reports false') { !view.entry_area.confirmation_visible? }
    d.check('the fake channel received nothing from the cancelled paste') do
      !@channel.sent.any? { |text| text.include?('line one') }
    end
  end

  d.step('opening the user list shows the one member') do
    polari_app.app.activate_action('user-list', nil)
  end

  d.step('the user-list popover is visible with alice in it') do
    popover = polari_app.window.user_list_popover
    d.check('the popover reports visible') { popover.visible? }
    d.shot('08-user-list')
  end

  d.step('activating alice\'s row expands her inline user details') do
    user_list = polari_app.window.user_list_popover.instance_variable_get(:@user_list)
    row = user_list.list.children.first
    d.check('a row for alice is in the list') { !row.nil? && row.user.alias == 'alice' }
    user_list.list.signal_emit('row-activated', row)
  end

  d.step('the row is expanded and the details revealer opened') do
    user_list = polari_app.window.user_list_popover.instance_variable_get(:@user_list)
    row = user_list.list.children.first
    d.check('the row reports expanded') { row.expand }
    d.shot('08b-user-details-expanded')
  end

  d.step('activating the row again collapses the details') do
    user_list = polari_app.window.user_list_popover.instance_variable_get(:@user_list)
    row = user_list.list.children.first
    user_list.list.signal_emit('row-activated', row)
    d.check('the row reports collapsed') { !row.expand }
  end

  d.step('closing the user list again') do
    polari_app.app.activate_action('user-list', nil)
  end

  d.step('the popover is gone') do
    d.check('the user-list action is off') { !polari_app.app.lookup_action('user-list').state }
  end

  d.step('the search bar filters the sidebar and swaps the content page') do
    polari_app.window.search_button.active = true
    polari_app.window.search_entry.text = 'polari'
  end

  d.step('search mode is showing the search page') do
    d.check('search mode is enabled') { polari_app.window.search_bar.search_mode_enabled? }
    d.check('the view stack switched to search') do
      polari_app.window.view_stack.visible_child_name == 'search'
    end
    d.shot('09-search')
  end

  d.step('clearing the search entry returns to the conversation') do
    polari_app.window.search_entry.text = ''
  end

  d.step('the conversation page is back') do
    d.check('the view stack is back on conversation') do
      polari_app.window.view_stack.visible_child_name == 'conversation'
    end
    polari_app.window.search_button.active = false
  end

  d.step('app.shortcuts-dialog opens the shortcuts dialog') do
    polari_app.app.activate_action('shortcuts-dialog', nil)
  end

  d.step('the shortcuts dialog carries both of upstream\'s sections') do
    polari_app.window.visible_dialog.then do |dialog|
      d.check('a Polari::ShortcutsDialog is showing') { dialog.is_a?(Polari::ShortcutsDialog) }
      d.check('its title is set') { dialog.title == 'Keyboard Shortcuts' }
      pump(100)
      d.shot('10-shortcuts')
      dialog.close
    end
  end

  d.step('app.about opens the about dialog') do
    polari_app.app.activate_action('about', nil)
  end

  d.step('the about dialog carries the port\'s identity') do
    polari_app.window.visible_dialog.then do |dialog|
      d.check('an Adwaita::AboutDialog is showing') { dialog.is_a?(Adwaita::AboutDialog) }
      d.check('its application id is org.gnome.Polari') { dialog.application_icon == 'org.gnome.Polari' }
      d.check('its version is the gem version') { dialog.version == Polari::Rb::VERSION }
      d.check('it carries every upstream developer') do
        dialog.developers.to_a == Polari::Application::DEVELOPERS
      end
      pump(100)
      d.shot('11-about')
      dialog.close
    end
  end

  d.step('app.edit-connection opens the connection-properties editor') do
    polari_app.app.lookup_action('edit-connection').activate(GLib::Variant.new(ACCOUNT.call.object_path))
  end

  d.step('the properties dialog is pre-filled from the account') do
    polari_app.window.visible_dialog.then do |dialog|
      d.check('a Polari::ConnectionProperties is showing') { dialog.is_a?(Polari::ConnectionProperties) }
      details = dialog.details
      d.check('the server field has the account\'s server') { details.server_row.text == 'irc.example.org' }
      d.check('the nick field has the account\'s nick') { details.nick_row.text == 'tester' }
      d.check('Apply starts insensitive (nothing changed yet)') { !dialog.apply_button.sensitive? }
      details.nick_row.text = 'tester2'
      d.check('Apply is sensitive once something changes') { dialog.apply_button.sensitive? }
      pump(100)
      d.shot('12-connection-properties', dialog)
      dialog.cancel_button.signal_emit('clicked')
    end
  end

  d.step('the properties dialog did not apply the unconfirmed edit') do
    d.check('the account keeps its original nickname') { ACCOUNT.call.nickname == 'tester' }
  end

  d.step('app.remove-connection hides the account behind an undo toast') do
    polari_app.app.lookup_action('remove-connection').activate(GLib::Variant.new(ACCOUNT.call.object_path))
  end

  d.step('the account is disabled and hidden, pending the toast') do
    d.check('the account is disabled') { !ACCOUNT.call.enabled? }
    d.check('the account is hidden') { !ACCOUNT.call.visible? }
    d.check('it is still in the monitor (not removed yet)') do
      Polari::AccountsMonitor.default.lookup_account(ACCOUNT.call.object_path) == ACCOUNT.call
    end
  end

  d.step('app.undo-remove-connection restores it') do
    polari_app.app.lookup_action('undo-remove-connection').activate(
      GLib::Variant.new(ACCOUNT.call.object_path),
    )
  end

  d.step('the account is enabled and visible again') do
    d.check('the account is enabled again') { ACCOUNT.call.enabled? }
    d.check('the account is visible again') { ACCOUNT.call.visible? }
  end

  # Removing the account above (then undoing it) cleared the active room:
  # removing its only row from the :browse-mode sidebar list clears the
  # list's selection, which bounces through on_room_selected(nil) same as a
  # real click would, and restoring the account's visibility only restores
  # its saved rooms non-presented (present: false — see
  # RoomManager#restore_rooms), the way upstream's account-shown handling
  # does, so nothing re-selects the room in the UI. Presenting it again is
  # what a real session does after reconnecting.
  d.step('presenting the room again selects it, and leave-current-room is enabled') do
    polari_app.app.lookup_action('join-room').activate(
      GLib::Variant.new([ACCOUNT.call.object_path, '#polari']),
    )
    d.check('the active room came back') { !polari_app.window.active_room.nil? }
    d.check('leave-current-room re-enabled itself') do
      polari_app.app.lookup_action('leave-current-room').enabled?
    end
  end

  d.step('app.leave-current-room leaves the active room') do
    polari_app.app.lookup_action('leave-current-room').activate(nil)
  end

  d.step('the room and its saved channel are both gone') do
    d.check('no rooms remain') { Polari::RoomManager.default.rooms.empty? }
    d.check('the saved-channel-list forgot it') do
      Polari::Settings.default['saved-channel-list'].none? { |c| c['channel'] == '#polari' }
    end
    d.check('leave-current-room disabled itself (no active room)') do
      !polari_app.app.lookup_action('leave-current-room').enabled?
    end
  end

  # 600x400, not some arbitrary size: the dev shell's Xvfb server is only
  # 640x480 (test/gtk_driver.rb's companion skill assumed GTK4's offscreen
  # backend, which this machine's GTK4 does not have — see this file's
  # header comment), and a size the display cannot actually honour would
  # silently clamp here, proving nothing about the port.
  d.step('window geometry is remembered across a close-request') do
    polari_app.window.set_default_size(600, 400)
  end

  d.step('close-request wrote the new geometry to settings') do
    pump(500)
    d.check('the handler does not veto the close') { !polari_app.window.signal_emit('close-request') }
    d.check('the width was remembered') { Polari::Settings.default['window-width'] == 600 }
    d.check('the height was remembered') { Polari::Settings.default['window-height'] == 400 }
    d.check('the window is still around (no real close happened)') { polari_app.window.visible? }
  end

  d.step('Util\'s nick helpers match upstream\'s documented pinned cases') do
    d.check('nick42 is its own base nick') { Polari::Util.get_basenick('nick42') == 'nick42' }
    d.check('nicky does not match nick') { !Polari::Util.match_nick('nicky is here', 'nick') }
    d.check('nick does match on its own') { Polari::Util.match_nick('nick: hello', 'nick') }
    d.check('identify with no username reports an empty one') do
      Polari::Util.match_identify_message('identify secret') == ['identify', '', 'secret']
    end
    d.check('IRC colour codes are stripped from topics') do
      Polari::Util.strip_color_codes("\x0304red\x03 text") == 'red text'
    end
  end

  d.step('removing every account brings the empty state back') do
    Polari::AccountsMonitor.default.accounts.dup.each do |account|
      Polari::AccountsMonitor.default.remove_account(account)
    end
  end

  d.step('the sidebar is empty again, exactly as it started') do
    d.check('no accounts remain') { Polari::AccountsMonitor.default.accounts.empty? }
    d.check('the room list is hidden again') { !polari_app.window.room_list_revealer.reveal_child? }
    d.check('no rooms remain') { Polari::RoomManager.default.rooms.empty? }
    d.shot('13-empty-again')
  end
end
