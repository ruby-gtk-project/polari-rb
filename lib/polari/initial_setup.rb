# frozen_string_literal: true

require 'adwaita'
require_relative 'accounts_monitor'
require_relative 'connections'
require_relative 'server_room_manager'
require_relative 'utils'

module Polari
  # InitialSetupWindow is the first-run assistant: pick a network, then pick
  # the rooms to join on it, with an offline page in between if there is no
  # network to reach either with.
  #
  # Ported from src/initialSetup.js plus data/ui/initial-setup-window.ui: the
  # header bar's Back/Cancel and Next/Done buttons that relabel themselves
  # (and the latter gains 'suggested-action') once the room page is showing,
  # the GtkStack switching between the connections page, the room page and
  # the offline hint, dropping the half-made account if the window closes
  # before Done, and joining every selected room (adding a leading '#' to
  # whatever the room list hands back bare) through app.join-room with
  # present: true, same as upstream's (ssb) action activation.
  class InitialSetupWindow < Adwaita::ApplicationWindow
    PAGE_CONNECTION = :connection
    PAGE_ROOM = :room
    PAGE_OFFLINE = :offline

    def initialize(app, accounts_monitor: AccountsMonitor.default)
      super(app)
      @app = app
      @accounts_monitor = accounts_monitor
      @current_account = nil

      self.title = 'Polari Setup'
      self.icon_name = 'org.gnome.Polari'
      self.default_width = 800
      self.default_height = 600
    end

    def build
      tap do |window|
        window.content = toolbar_view

        toolbar_view.tap do |view|
          view.add_top_bar(header_bar)
          view.content = content_stack
        end

        header_bar.tap do |bar|
          bar.show_start_title_buttons = false
          bar.show_end_title_buttons = false
          bar.pack_start(prev_button)
          bar.pack_end(next_button)
        end

        content_stack.tap do |stack|
          stack.add_named(offline_page, 'offline-hint')
          stack.add_named(connections_page, 'connections')
          stack.add_named(room_page, 'rooms')
        end

        next_button.signal_connect('clicked') { on_next_clicked }
        prev_button.signal_connect('clicked') { on_prev_clicked }
        window.signal_connect('close-request') { on_close_request }

        network_monitor.signal_connect('notify::network-available') { on_network_available_changed }
        on_network_available_changed

        set_default_widget(next_button)
      end
    end

    def current_page
      case content_stack.visible_child_name
      when 'rooms' then PAGE_ROOM
      when 'connections' then PAGE_CONNECTION
      else PAGE_OFFLINE
      end
    end

    attr_reader :current_account

    def next_button
      @next_button ||= Gtk::Button.new.tap { |button| button.valign = :center }
    end

    def prev_button
      @prev_button ||= Gtk::Button.new.tap { |button| button.valign = :center }
    end

    def connections_list
      @connections_list ||= ConnectionsList.new(
        favorites_only:      true,
        accounts_monitor:    @accounts_monitor,
        on_account_created:  method(:on_account_created),
        on_account_selected: nil,
      ).tap do |list|
        list.hscrollbar_policy = :never
        list.has_frame = true
      end
    end

    def server_room_list
      @server_room_list ||= ServerRoomList.new(on_can_join_changed: method(:update_next_sensitivity))
    end

    private

      def on_network_available_changed
        if network_monitor.network_available?
          set_page(@current_account ? PAGE_ROOM : PAGE_CONNECTION)
        else
          set_page(PAGE_OFFLINE)
        end
      end

      def set_page(page)
        content_stack.visible_child_name = page_name(page)

        last_page = page == PAGE_ROOM

        prev_button.label = last_page ? '_Back' : '_Cancel'
        next_button.label = last_page ? '_Done' : '_Next'
        prev_button.use_underline = true
        next_button.use_underline = true

        if last_page
          next_button.add_css_class('suggested-action')
        else
          next_button.remove_css_class('suggested-action')
        end

        update_next_sensitivity
      end

      def page_name(page)
        case page
        when PAGE_ROOM then 'rooms'
        when PAGE_CONNECTION then 'connections'
        else 'offline-hint'
        end
      end

      def update_next_sensitivity
        sensitive =
          if current_page == PAGE_OFFLINE
            false
          elsif current_page == PAGE_ROOM
            server_room_list.can_join?
          else
            true
          end

        next_button.sensitive = sensitive
      end

      def on_next_clicked
        if current_page == PAGE_CONNECTION
          connections_list.activate_selected
        else
          join_rooms
          @current_account = nil
          destroy
        end
      end

      def on_prev_clicked
        if current_page == PAGE_ROOM
          set_page(PAGE_CONNECTION)
          unset_account
        else
          destroy
        end
      end

      def on_close_request
        unset_account
        false
      end

      def unset_account
        if @current_account
          @accounts_monitor.remove_account(@current_account)
          @current_account = nil
        end
      end

      def on_account_created(account)
        set_page(PAGE_ROOM)
        @current_account = account
        server_room_list.account = account
      end

      def join_rooms
        hide

        account_path = @current_account.object_path
        server_room_list.selected_rooms.each do |room|
          name = room.start_with?('#') ? room : "##{room}"

          Gio::Application.default.lookup_action('join-room').activate(
            GLib::Variant.new([account_path, name]),
          )
        end
      end

      def network_monitor = @network_monitor ||= Gio::NetworkMonitor.default

      def toolbar_view = @toolbar_view ||= Adwaita::ToolbarView.new

      def header_bar = @header_bar ||= Adwaita::HeaderBar.new

      def content_stack
        @content_stack ||= Gtk::Stack.new.tap do |stack|
          stack.transition_type = :slide_left_right
          stack.vexpand = true
        end
      end

      def offline_page
        @offline_page ||= Adwaita::StatusPage.new.tap do |page|
          page.icon_name = 'network-offline-symbolic'
          page.title = 'Not connected'
          page.description = 'Please connect to the internet to continue the setup.'
        end
      end

      def connections_page
        @connections_page ||= Adwaita::StatusPage.new.tap do |page|
          page.title = 'Welcome to Polari'
          page.description = 'Polari is an easy way to chat using IRC. Select a network to get started.'
          page.child = Adwaita::Clamp.new.tap { |clamp| clamp.child = connections_list.build }
        end
      end

      def room_page
        @room_page ||= Gtk::Box.new(:vertical, 0).tap do |box|
          box.add_css_class('polari-setup-page')
          box.append(
            Adwaita::StatusPage.new.tap do |page|
              page.title = 'Welcome to Polari'
              page.description = 'Select rooms you want to connect to. ' \
                                  'You can add more networks and rooms later, by clicking the + button.'
            end,
          )
          box.append(Adwaita::Clamp.new.tap do |clamp|
            clamp.child = server_room_list.build.tap { |list| list.vexpand = true }
          end)
        end
      end

  end
end
