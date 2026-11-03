# frozen_string_literal: true

require 'adwaita'
require_relative 'accounts_monitor'
require_relative 'connections'
require_relative 'server_room_manager'

module Polari
  # JoinDialog is the dialog behind the sidebar's + button: pick a network and
  # the rooms to join, add one of the predefined networks, or describe a
  # custom one.
  #
  # Ported from src/joinDialog.js plus data/ui/join-room-dialog.ui: the
  # three-page AdwNavigationView (Join Chat Room, Add Network, Custom
  # Network), the connection combo that starts on the active room's network,
  # the Join button that stays insensitive until a room is picked, the
  # straight-to-Add-Network start when there are no accounts yet, and
  # disabling app.show-join-dialog while the dialog is up.
  class JoinDialog < Adwaita::Dialog
    def initialize(accounts_monitor: AccountsMonitor.default, window: nil)
      super()
      @accounts_monitor = accounts_monitor
      @window = window
      @accounts = {}

      self.title = 'Join Chat Room'
      self.content_width = 500
      self.content_height = 500
    end

    def build
      tap do |dialog|
        dialog.child = nav_view

        nav_view.tap do |view|
          view.add(main_page)
          view.add(connection_page)
          view.add(custom_page)
        end

        setup_main_page
        setup_connection_page
        setup_custom_page
        connect_accounts

        join_button.signal_connect('clicked') { join_rooms }
        nav_view.signal_connect('notify::visible-page') { on_page_changed }

        dialog.signal_connect('map') { set_join_action_enabled(false) }
        dialog.signal_connect('unmap') { set_join_action_enabled(true) }

        on_accounts_changed
        on_page_changed

        unless accounts?
          nav_view.push(connection_page)
        end
      end
    end

    def accounts? = @accounts.any?

    def nav_view = @nav_view ||= Adwaita::NavigationView.new

    def main_page
      @main_page ||= Adwaita::NavigationPage.new(main_toolbar, 'Join Chat Room')
    end

    def connection_page
      @connection_page ||= Adwaita::NavigationPage.new(connection_toolbar, 'Add Network')
    end

    def custom_page
      @custom_page ||= Adwaita::NavigationPage.new(custom_toolbar, 'Custom Network')
    end

    def main_toolbar = @main_toolbar ||= Adwaita::ToolbarView.new
    def connection_toolbar = @connection_toolbar ||= Adwaita::ToolbarView.new
    def custom_toolbar = @custom_toolbar ||= Adwaita::ToolbarView.new

    def join_button
      @join_button ||= dialog_button('_Join').tap do |button|
        button.add_css_class('suggested-action')
        button.sensitive = false
      end
    end

    def cancel_button = @cancel_button ||= close_button('_Cancel')
    def connection_cancel_button = @connection_cancel_button ||= close_button('_Cancel')
    def add_button = @add_button ||= dialog_button('_Add')

    def connection_combo
      @connection_combo ||= Gtk::ComboBoxText.new.tap do |combo|
        combo.hexpand = true
        combo.sensitive = false
      end
    end

    def connection_button
      @connection_button ||= Gtk::Button.new.tap do |button|
        button.use_underline = true
        button.child = Gtk::Box.new(:horizontal, 6).tap do |box|
          box.append(Gtk::Image.new.tap { |image| image.icon_name = 'list-add-symbolic' })
          box.append(Gtk::Label.new('_Add Network').tap { |label| label.use_underline = true })
        end
      end
    end

    def custom_network_button
      @custom_network_button ||= Gtk::Button.new(label: '_Custom Network').tap do |button|
        button.use_underline = true
      end
    end

    def filter_entry
      @filter_entry ||= Gtk::SearchEntry.new.tap do |entry|
        entry.hexpand = true
      end
    end

    def server_room_list
      @server_room_list ||= ServerRoomList.new(
        on_can_join_changed: method(:update_can_join),
        on_stop_search:      method(:close),
      )
    end

    def connections_list
      @connections_list ||= ConnectionsList.new(
        on_account_created:  method(:on_account_created),
        on_account_selected: method(:on_account_selected),
      )
    end

    def details
      @details ||= ConnectionDetails.new(on_account_created: method(:on_account_created))
    end

    private

      def dialog_button(label)
        Gtk::Button.new(label: label).tap do |button|
          button.receives_default = true
          button.use_underline = true
        end
      end

      def close_button(label)
        dialog_button(label).tap do |button|
          button.signal_connect('clicked') { close }
        end
      end

      def setup_main_page
        main_toolbar.tap do |view|
          view.add_top_bar(main_header)
          view.content = main_grid
        end

        main_header.tap do |bar|
          bar.show_start_title_buttons = false
          bar.show_end_title_buttons = false
          bar.pack_start(cancel_button)
          bar.pack_end(join_button)
        end

        main_grid.tap do |grid|
          grid.attach(connection_label, 0, 0, 1, 1)
          grid.attach(connection_combo, 1, 0, 1, 1)
          grid.attach(connection_button, 2, 0, 1, 1)
          grid.attach(server_room_list.build, 0, 1, 3, 1)
        end

        connection_combo.signal_connect('changed') { on_account_changed }
        connection_button.signal_connect('clicked') { nav_view.push(connection_page) }
      end

      def setup_connection_page
        connection_toolbar.tap do |view|
          view.add_top_bar(connection_header)
          view.content = connection_box
        end

        connection_header.tap do |bar|
          bar.show_start_title_buttons = false
          bar.show_end_title_buttons = false
          bar.pack_start(connection_cancel_button)
        end

        connection_box.tap do |box|
          box.append(filter_bar)
          box.append(connections_list.build)
          box.append(custom_network_button)
        end

        filter_bar.append(filter_entry)

        filter_entry.signal_connect('search-changed') { connections_list.set_filter(filter_entry.text) }
        filter_entry.signal_connect('stop-search') { on_filter_stop_search }
        filter_entry.signal_connect('activate') do
          unless filter_entry.text.empty?
            connections_list.activate_selected
          end
        end

        custom_network_button.signal_connect('clicked') { nav_view.push(custom_page) }
      end

      def setup_custom_page
        custom_toolbar.tap do |view|
          view.add_top_bar(custom_header)
          view.content = details.build
        end

        custom_header.tap do |bar|
          bar.show_start_title_buttons = false
          bar.show_end_title_buttons = false
          bar.pack_end(add_button)
        end

        add_button.signal_connect('clicked') do
          details.save
          nav_view.pop_to_page(main_page)
        end
      end

      def main_header = @main_header ||= Adwaita::HeaderBar.new
      def connection_header = @connection_header ||= Adwaita::HeaderBar.new
      def custom_header = @custom_header ||= Adwaita::HeaderBar.new

      def main_grid
        @main_grid ||= Gtk::Grid.new.tap do |grid|
          grid.row_spacing = 12
          grid.column_spacing = 12
          grid.margin_start = 18
          grid.margin_end = 18
          grid.margin_top = 12
          grid.margin_bottom = 18
        end
      end

      def connection_label
        @connection_label ||= Gtk::Label.new('C_onnection').tap do |label|
          label.use_underline = true
          label.halign = :end
        end
      end

      def connection_box
        @connection_box ||= Gtk::Box.new(:vertical, 12).tap do |box|
          box.margin_start = 18
          box.margin_end = 18
          box.margin_top = 12
          box.margin_bottom = 18
        end
      end

      def filter_bar
        @filter_bar ||= Gtk::Box.new(:horizontal, 6).tap do |box|
          box.add_css_class('polari-listbox-filterbar')
        end
      end

      def connect_accounts
        @accounts_monitor.visible_accounts.each do |account|
          @accounts[account.display_name] = account
        end

        @accounts_monitor.connect('account-added') do |_m, account|
          @accounts[account.display_name] = account
          on_accounts_changed
        end
        @accounts_monitor.connect('account-removed') do |_m, account|
          @accounts.delete(account.display_name)
          on_accounts_changed
        end
      end

      def on_accounts_changed
        connection_combo.remove_all

        names = @accounts.keys.sort
        names.each { |name| connection_combo.append(name, name) }
        connection_combo.sensitive = names.length > 1

        connection_combo.active = active_index(names)
        connection_page.can_pop = accounts?
      end

      # The combo starts on the network of the room the window is showing.
      def active_index(names)
        room = @window.respond_to?(:active_room) ? @window.active_room : nil

        if room
          [names.index(room.account.display_name).to_i, 0].max
        else
          0
        end
      end

      def on_account_changed
        selected_account.then do |account|
          if account
            server_room_list.account = account
          end
        end
        update_can_join
      end

      def selected_account = @accounts[connection_combo.active_text]

      def on_account_created(account)
        connection_combo.active_id = account.display_name
      end

      def on_account_selected
        nav_view.pop_to_page(main_page)
      end

      def on_filter_stop_search
        if filter_entry.text.length.positive?
          filter_entry.text = ''
        else
          nav_view.pop
        end
      end

      def join_rooms
        account = selected_account

        server_room_list.selected_rooms.each do |room|
          name = room.start_with?('#') ? room : "##{room}"
          Gio::Application.default.lookup_action('join-room').activate(
            GLib::Variant.new([account.object_path, name]),
          )
        end

        close
      end

      def update_can_join
        join_button.sensitive =
          nav_view.visible_page == main_page &&
          connection_combo.active > -1 &&
          server_room_list.can_join?
      end

      def on_page_changed
        if nav_view.visible_page == main_page
          server_room_list.focus_entry
        elsif nav_view.visible_page == custom_page
          self.default_widget = add_button
          details.reset
        end
        update_can_join
      end

      def set_join_action_enabled(enabled)
        Gio::Application.default.lookup_action('show-join-dialog').then do |action|
          if action
            action.enabled = enabled
          end
        end
      end
  end
end
