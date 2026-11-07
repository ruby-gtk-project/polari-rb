# frozen_string_literal: true

require 'set'
require 'gtk4'
require 'adwaita'
require_relative 'rb/version'
require_relative 'settings'
require_relative 'utils'
require_relative 'accounts_monitor'
require_relative 'networks_manager'
require_relative 'room_manager'
require_relative 'user_tracker'
require_relative 'server_room_manager'
require_relative 'paste_manager'
require_relative 'main_window'
require_relative 'initial_setup'
require_relative 'shortcuts_dialog'
require_relative 'connections'
require_relative 'tpl_importer'
require_relative 'telepathy_client'

module Polari
  # Application is the entry point: it installs the actions and their
  # accelerators, loads the stylesheet, and puts up the main window.
  #
  # Ported from src/application.js. The actions, their names and their
  # accelerators are upstream's, with one deliberate difference: upstream's
  # multi-argument actions take tuple variants ((ssb), (sssb), (ss), (os)),
  # and the Ruby GLib bindings cannot build a tuple variant — an array of
  # mixed types collapses into a string array — so those actions take string
  # arrays ('as') of the same arity instead, and the boolean "present" flag of
  # join-room/message-user becomes the separate query-user action (QUERY
  # presents the conversation, MSG does not).
  #
  # Starts the IRC transport (telepathy_client.rb's TelepathyClient, this
  # port's whole replacement for registering a Tp.BaseClient) alongside the
  # other singletons on_startup already builds, so an enabled account
  # actually connects rather than just notifying "connecting" forever.
  class Application
    APPLICATION_ID = 'org.gnome.Polari'

    # The one instance exe/polari builds, so telepathy_client.rb's transport
    # — which has no GObject property to bind the running Application
    # through — can still reach the main window to deliver a message.
    def self.current = @current

    class << self
      attr_writer :current
    end

    # Name, parameter type and accelerators of every action, as
    # vfunc_startup's actionEntries lists them.
    ACTIONS = [
      { name: 'show-join-dialog', accels: ['<Primary>n'] },
      { name: 'join-room', parameter: 'as' },
      { name: 'message-user', parameter: 'as' },
      { name: 'query-user', parameter: 'as' },
      { name: 'leave-room', parameter: 'as' },
      { name: 'leave-current-room', accels: ['<Primary>w'] },
      { name: 'reconnect-room', parameter: 's' },
      { name: 'authenticate-account', parameter: 'as' },
      { name: 'connect-account', parameter: 's' },
      { name: 'disconnect-account', parameter: 's' },
      { name: 'reconnect-account', parameter: 's' },
      { name: 'mute-nick', parameter: 'as' },
      { name: 'unmute-nick', parameter: 'as' },
      { name: 'user-list', state: false, accels: %w[F9 <Primary>u] },
      { name: 'remove-connection', parameter: 's' },
      { name: 'undo-remove-connection', parameter: 's' },
      { name: 'edit-connection', parameter: 's' },
      { name: 'save-identify-password', parameter: 's' },
      { name: 'discard-identify-password', parameter: 's' },
      { name: 'show-emoji-picker', accels: ['<Primary>e'] },
      { name: 'help', accels: ['F1'] },
      { name: 'about' },
      { name: 'shortcuts-dialog', accels: ['<Primary>question'] },
      { name: 'quit', accels: ['<Primary>q'] },
      { name: 'search', accels: ['<Primary>s'] },
      { name: 'next-room', accels: ['<Primary>Page_Down', '<Alt>Down'] },
      { name: 'previous-room', accels: ['<Primary>Page_Up', '<Alt>Up'] },
      { name: 'first-room', accels: ['<Primary>Home'] },
      { name: 'last-room', accels: ['<Primary>End'] },
      { name: 'nth-room', parameter: 'i' },
      { name: 'next-pending-room', accels: ['<Alt><Shift>Down', '<Primary><Shift>Page_Down'] },
      { name: 'previous-pending-room', accels: ['<Alt><Shift>Up', '<Primary><Shift>Page_Up'] },
      { name: 'run-in-background', state: false },
    ].freeze

    DEVELOPERS = [
      'Florian Müllner <fmuellner@gnome.org>',
      'William Jon McCann <william.jon.mccann@gmail.com>',
      'Carlos Soriano <carlos.soriano89@gmail.com>',
      'Giovanni Campagna <gcampagna@src.gnome.org>',
      'Carlos Garnacho <carlosg@gnome.org>',
      'Bastian Ilsø <bastianilso@gnome.org>',
      'Kunaal Jain <kunaalus@gmail.com>',
      'Isabella Ribeiro <belinhacbr@gmail.com>',
      'Rares Visalom <rares.visalom@gmail.com>',
      'Danny Mølgaard <moelgaard.dmp@gmail.com>',
      'Georges Basile Stavracas Neto <georges.stavracas@gmail.com>',
    ].freeze

    def build
      self.class.current = self

      app.tap do
        app.signal_connect('startup') { on_startup }
        app.signal_connect('activate') { on_activate }
      end
    end

    def run(argv = []) = app.run(argv)

    # Adwaita::Application is broken in the Ruby bindings; the application
    # object comes from Gtk and only the window is Adwaita.
    def app = @app ||= Gtk::Application.new(APPLICATION_ID, :default_flags)

    def settings = @settings ||= Settings.default
    def accounts_monitor = @accounts_monitor ||= AccountsMonitor.default
    def room_manager = @room_manager ||= RoomManager.default
    def networks_manager = @networks_manager ||= NetworksManager.default
    def user_status_monitor = @user_status_monitor ||= UserStatusMonitor.default
    def server_room_manager = @server_room_manager ||= ServerRoomManager.default
    def paste_manager = @paste_manager ||= PasteManager.new
    def telepathy_client = @telepathy_client ||= TelepathyClient.new(accounts_monitor: accounts_monitor, room_manager: room_manager)

    def window = @window ||= MainWindow.new(app, settings: settings).build

    def initial_setup_window = @initial_setup_window ||= InitialSetupWindow.new(app).build

    def css_provider
      @css_provider ||= Gtk::CssProvider.new.tap do |provider|
        provider.load(path: File.expand_path('../../data/style.css', __dir__))
      end
    end

    # Upstream's "small wrapper to mark user-requested nick changes".
    def set_account_nick(account, nick)
      account.nickname = nick
      accounts_monitor.save
    end

    # Whether the room the user is looking at is the focused one, which is
    # what decides if an incoming message is acknowledged right away.
    def room_focused?(room)
      app.active_window.then do |active|
        active.respond_to?(:active_room) && active.active? && active.active_room == room
      end
    end

    private

      def on_startup
        install_actions
        install_accels
        load_stylesheet

        accounts_monitor
        room_manager
        networks_manager
        user_status_monitor
        server_room_manager
        paste_manager
        telepathy_client.start
      end

      def on_activate
        if app.active_window.nil?
          if needs_initial_setup?
            initial_setup_window.present
          else
            window.present
            update_leave_action
            watch_leave_action
          end
          maybe_import_logs
        else
          app.active_window.present
        end
      end

      # _needsInitialSetup(): a forced first run, or no rooms saved from a
      # previous one and the one-time marker not set yet.
      def needs_initial_setup?
        if ENV.delete('POLARI_FORCE_INITIAL_SETUP')
          return true
        end

        Utils.needs_onetime_action?('initial-setup') && settings['saved-channel-list'].empty?
      end

      # Upstream keeps app.leave-current-room's enabled state bound to
      # window:active-room with a property notify
      # (vfunc_window_added in src/application.js); a Ruby MainWindow has no
      # such GObject property to bind to (see MainWindow's own comment on
      # why), so this re-checks it on every event that can change which room
      # is active.
      def watch_leave_action
        room_manager.connect('room-presented') { update_leave_action }
        room_manager.connect('room-removed') { update_leave_action }
      end

      # _maybeImportLogs(): telepathy-logger's own chat logs, imported once
      # into the Tracker/TinySPARQL store — skipped once that store exists,
      # the same "did we already do this" check upstream makes against
      # chatlogs.v1 existing, against this port's chatlogs.v2.
      def maybe_import_logs
        store_path = File.join(Utils.polari_data_dir, 'chatlogs.v2')

        unless Dir.exist?(store_path)
          Thread.new do
            TplImporter.new.import_all
          rescue StandardError => e
            warn "Failed to import telepathy-logger logs: #{e.message}"
          end
        end
      end

      def install_actions
        ACTIONS.each { |entry| app.add_action(build_action(entry)) }
        connect_action_handlers
      end

      def build_action(entry)
        if entry.key?(:state)
          Gio::SimpleAction.new(entry[:name], nil, GLib::Variant.new(entry[:state]))
        elsif entry[:parameter]
          Gio::SimpleAction.new(entry[:name], GLib::VariantType.new(entry[:parameter]))
        else
          Gio::SimpleAction.new(entry[:name])
        end
      end

      def install_accels
        ACTIONS.each do |entry|
          if entry[:accels]
            app.set_accels_for_action("app.#{entry[:name]}", entry[:accels])
          end
        end

        (1..9).each do |index|
          app.set_accels_for_action("app.nth-room(#{index})", ["<Alt>#{index}"])
        end
      end

      def load_stylesheet
        Gtk::StyleContext.add_provider_for_display(
          Gdk::Display.default,
          css_provider,
          Gtk::StyleProvider::PRIORITY_APPLICATION,
        )
      end

      def connect_action_handlers
        on_action('show-join-dialog') { window.show_join_room_dialog }
        on_action('leave-current-room') { leave_current_room }
        on_action('user-list') { |action| toggle_action(action) }
        on_action('run-in-background') { |action| toggle_run_in_background(action) }
        on_action('help') { Utils.open_url('help:polari') }
        on_action('about') { show_about_dialog }
        on_action('shortcuts-dialog') { show_shortcuts_dialog }
        on_action('quit') { quit }

        connect_room_actions
        connect_account_actions
      end

      def on_action(name, &handler)
        app.lookup_action(name).signal_connect('activate') do |action, parameter|
          handler.call(action, parameter)
        end
      end

      # Upstream's actions declare their GVariant type ('as', 's', ...), and
      # the Ruby GLib bindings hand the activate signal's handler the
      # already-unwrapped native value for that type (an Array for 'as', a
      # String for 's') rather than a GLib::Variant still carrying a #value
      # — there is no #value to call here.
      def connect_room_actions
        on_action('join-room') do |_a, parameter|
          account_path, channel = parameter
          room_manager.join_room(account_path, channel, present: true)
        end

        on_action('message-user') do |_a, parameter|
          account_path, nick, message = parameter
          send_private_message(account_path, nick, message)
        end

        on_action('query-user') do |_a, parameter|
          account_path, nick = parameter
          room_manager.message_user(account_path, nick, present: true)
        end

        on_action('leave-room') do |_a, parameter|
          id, = parameter
          room_manager.leave_room(id)
        end

        on_action('reconnect-room') do |_a, parameter|
          reconnect_room(parameter)
        end
      end

      def connect_account_actions
        on_action('connect-account') do |_a, parameter|
          request_presence(parameter, Account::PRESENCE_AVAILABLE)
        end
        on_action('disconnect-account') do |_a, parameter|
          request_presence(parameter, Account::PRESENCE_OFFLINE)
        end
        on_action('reconnect-account') do |_a, parameter|
          request_presence(parameter, Account::PRESENCE_AVAILABLE)
        end
        on_action('remove-connection') do |_a, parameter|
          remove_connection(parameter)
        end
        on_action('undo-remove-connection') do |_a, parameter|
          undo_remove_connection(parameter)
        end
        on_action('edit-connection') do |_a, parameter|
          edit_connection(parameter)
        end
        on_action('save-identify-password') do |_a, parameter|
          save_identify_password(parameter)
        end
        on_action('discard-identify-password') do |_a, parameter|
          discard_identify_password(parameter)
        end
        on_action('authenticate-account') do |_a, parameter|
          account_path, password = parameter
          authenticate_account(account_path, password)
        end
      end

      def lookup_account(path) = accounts_monitor.lookup_account(path)

      def leave_current_room
        window.active_room.then do |room|
          if room
            app.lookup_action('leave-room').activate(GLib::Variant.new([room.id, '']))
          end
        end
      end

      def update_leave_action
        app.lookup_action('leave-current-room').enabled = !window.active_room.nil?
      end

      # Gio::Action#state hands back the already-unwrapped native value (a
      # plain true/false here), not a GLib::Variant still carrying a #value.
      def toggle_action(action)
        action.change_state(GLib::Variant.new(!action.state))
      end

      def toggle_run_in_background(action)
        toggle_action(action)
        settings['run-in-background'] = action.state
      end

      def send_private_message(account_path, nick, message)
        room_manager.message_user(account_path, nick, present: false).then do |room|
          if room && room.channel.respond_to?(:send_text) && !message.to_s.empty?
            room.channel.send_text(message)
          end
        end
      end

      def reconnect_room(id)
        room_manager.lookup_room(id).then do |room|
          if room
            room.channel_error = ''
            request_presence(room.account.object_path, Account::PRESENCE_AVAILABLE)
          end
        end
      end

      def request_presence(account_path, presence)
        lookup_account(account_path).then do |account|
          if account
            account.request_presence(presence)
          end
        end
      end

      def authenticate_account(account_path, password)
        lookup_account(account_path).then do |account|
          if account
            Utils.store_account_password(account, password)
            account.request_presence(Account::PRESENCE_AVAILABLE)
          end
        end
      end

      def save_identify_password(account_path)
        lookup_account(account_path).then do |account|
          if account
            account.settings['identify-username'] = account.nickname.to_s
          end
        end
      end

      def discard_identify_password(account_path)
        lookup_account(account_path).then do |account|
          if account
            Utils.clear_identify_password(account)
          end
        end
      end

      # Removing a connection hides it first and offers an Undo toast; the
      # account is only dropped once the toast is gone.
      def remove_connection(account_path)
        lookup_account(account_path).then do |account|
          if account
            removed_accounts.add(account)
            account.enabled = false
            account.visible = false
            window.add_toast(remove_toast(account, account_path))
          end
        end
      end

      def remove_toast(account, account_path)
        Adwaita::Toast.new(format('%s removed.', account.display_name)).tap do |toast|
          toast.button_label = 'Undo'
          toast.action_name = 'app.undo-remove-connection'
          toast.set_action_target_value(GLib::Variant.new(account_path))
          toast.signal_connect('dismissed') { finish_removal(account) }
        end
      end

      def finish_removal(account)
        if removed_accounts.delete(account)
          accounts_monitor.remove_account(account)
          Utils.clear_account_password(account)
          Utils.clear_identify_password(account)
        end
      end

      def undo_remove_connection(account_path)
        lookup_account(account_path).then do |account|
          if account
            removed_accounts.delete(account)
            account.enabled = true
            account.visible = true
          end
        end
      end

      def removed_accounts = @removed_accounts ||= Set.new

      def edit_connection(account_path)
        lookup_account(account_path).then do |account|
          if account
            ConnectionProperties.new(account).build.present(window)
          end
        end
      end

      def show_shortcuts_dialog
        ShortcutsDialog.new.build.present(window)
      end

      def show_about_dialog
        Adwaita::AboutDialog.new.tap do |dialog|
          dialog.application_name = 'Polari'
          dialog.application_icon = 'org.gnome.Polari'
          dialog.version = Polari::Rb::VERSION
          dialog.developer_name = 'The GNOME Project'
          dialog.developers = DEVELOPERS
          dialog.license_type = Gtk::License::GPL_2_0
          dialog.present(window)
        end
      end

      def quit
        app.windows.reverse_each(&:destroy)
        app.quit
      end
  end
end
