# frozen_string_literal: true

# Drives the first-run assistant headlessly: builds it in place of the main
# window (a fresh config/data dir, as a first run would have it), picks a
# network the way a row activation in ConnectionsList would, and checks the
# pending account is dropped when the user backs out to the connections
# page. It stops short of a real window destroy — see test/drive_polari.rb's
# own close-request step, which emits the signal rather than closing for
# real for the same reason: disposing a GtkListBox with a header_func set
# (ConnectionsList's) while Ruby's GC is in a collection pass is a known
# ruby-gnome crash ("[BUG] object allocation during garbage collection
# phase"), not anything this port's code gets to choose.
#
# Run it from the repository root:
#
#   nix develop --command xvfb-run -a ruby test/drive_initial_setup.rb

require 'fileutils'
require 'tmpdir'

# A fresh pair of scratch directories: no accounts.json, no one-time-action
# marker, so Application#needs_initial_setup? is true and the assistant (not
# MainWindow) is what activate presents.
ENV['XDG_CONFIG_HOME'] = Dir.mktmpdir('polari-drive-config')
ENV['XDG_DATA_HOME'] = Dir.mktmpdir('polari-drive-data')

$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))

require 'polari'
require_relative 'gtk_driver'

SHOTS = File.expand_path('../tmp/shots-initial-setup', __dir__)
FileUtils.rm_rf(SHOTS)

# Turns the main loop over for `ms` milliseconds and comes back, the way
# test/drive_polari.rb's own pump does — a NavigationView page push needs an
# extra frame to realise before a screenshot of it finds a render node.
def pump(ms)
  (Process.clock_gettime(Process::CLOCK_MONOTONIC) + (ms / 1000.0)).then do |deadline|
    while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
      GLib::MainContext.default.iteration(false)
    end
  end
end

GtkDriver.drive(Polari::Application.new, shots: SHOTS) do |d, polari_app|
  d.window { polari_app.initial_setup_window }

  d.step('a first run presents the initial-setup window, not the main one') do
    d.check('the window is a Polari::InitialSetupWindow') do
      polari_app.initial_setup_window.is_a?(Polari::InitialSetupWindow)
    end
    d.check('it is the only toplevel') { Gtk::Window.list_toplevels.length == 1 }
    d.check('its title is Polari Setup') { polari_app.initial_setup_window.title == 'Polari Setup' }
    d.check('its icon is the application id') do
      polari_app.initial_setup_window.icon_name == 'org.gnome.Polari'
    end
    d.check('it starts on the connections or offline page, never rooms') do
      [Polari::InitialSetupWindow::PAGE_CONNECTION, Polari::InitialSetupWindow::PAGE_OFFLINE]
        .include?(polari_app.initial_setup_window.current_page)
    end
    d.shot('01-first-page')
  end

  d.step('picking a network (a ConnectionsList row activation) advances to the room page') do
    window = polari_app.initial_setup_window
    account = Polari::AccountsMonitor.default.create_account(
      display_name: 'Test Network',
      parameters:   { 'server' => 'irc.test.example', 'nick' => 'tester' },
    )

    # Stands in for the real row activation ConnectionsList#on_row_activated
    # fires on 'account-created' — see test/drive_polari.rb's FakeChannel
    # comment for why this port's drive scripts stand in for a UI gesture
    # with the handler it would trigger.
    window.send(:on_account_created, account)

    d.check('the room page is now showing') { window.current_page == Polari::InitialSetupWindow::PAGE_ROOM }
    d.check('the pending account is remembered') { window.current_account == account }
    d.check('Next starts insensitive (no room picked yet)') { !window.next_button.sensitive? }
    d.check("Back is labelled '_Back'") { window.prev_button.label == '_Back' }
    d.check("Next is labelled '_Done'") { window.next_button.label == '_Done' }
    pump(100)
    d.shot('02-room-page')
  end

  d.step('Back drops the pending account and returns to the connections page') do
    window = polari_app.initial_setup_window
    account = window.current_account

    window.prev_button.signal_emit('clicked')

    d.check('the connections page is showing again') do
      window.current_page == Polari::InitialSetupWindow::PAGE_CONNECTION
    end
    d.check('the window no longer remembers a pending account') { window.current_account.nil? }
    d.check('the half-made account was removed from the monitor') do
      Polari::AccountsMonitor.default.lookup_account(account.object_path).nil?
    end
    pump(100)
    d.shot('03-back-to-connections')
  end
end
