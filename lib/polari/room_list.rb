# frozen_string_literal: true

require 'adwaita'
require_relative 'accounts_monitor'
require_relative 'room_manager'
require_relative 'user_tracker'
require_relative 'logger'

module Polari
  # ConnectionPopover is what a network header in the sidebar opens: the
  # network's name and connection state, a password entry when the server
  # asked for one, and the connect/reconnect/disconnect/remove/properties
  # actions for the account.
  #
  # Ported from the connectionPopover object in data/ui/room-list-header.ui
  # and the parts of RoomListHeader in src/roomList.js that fill it.
  class ConnectionPopover < Gtk::Popover
    def initialize(account)
      super()
      @account = account

      self.name = "ConnectionPopover #{account.display_name}"
      add_css_class('menu')
    end

    def build
      tap do |popover|
        popover.child = box
        popover.default_widget = password_entry

        box.tap do |vbox|
          vbox.append(title_label)
          vbox.append(status_label)
          vbox.append(password_entry)
          vbox.append(separator)
          vbox.append(connect_button)
          vbox.append(reconnect_button)
          vbox.append(disconnect_button)
          vbox.append(remove_button)
          vbox.append(properties_button)
        end

        install_account_actions
        connect_signals
      end
    end

    attr_reader :title_label, :status_label, :password_entry

    def box
      @box ||= Gtk::Box.new(:vertical, 0).tap do |vbox|
        vbox.margin_start = 12
        vbox.margin_end = 12
        vbox.margin_top = 12
        vbox.margin_bottom = 12
      end
    end

    def title_label
      @title_label ||= Gtk::Label.new.tap do |label|
        label.wrap = true
        label.max_width_chars = 30
        label.width_chars = 15
        label.xalign = 0
        label.margin_start = 6
        label.margin_end = 6
      end
    end

    def status_label
      @status_label ||= Gtk::Label.new.tap do |label|
        label.wrap = true
        label.max_width_chars = 30
        label.xalign = 0
        label.margin_start = 6
        label.margin_end = 6
      end
    end

    def password_entry
      @password_entry ||= Gtk::Entry.new.tap do |entry|
        entry.visibility = false
        entry.activates_default = true
        entry.margin_top = 6
        entry.margin_start = 6
        entry.margin_end = 6
      end
    end

    def separator
      @separator ||= Gtk::Separator.new(:horizontal).tap do |widget|
        widget.margin_top = 6
        widget.margin_bottom = 6
      end
    end

    def connect_button = @connect_button ||= menu_button('Connect')
    def reconnect_button = @reconnect_button ||= menu_button('Reconnect')
    def disconnect_button = @disconnect_button ||= menu_button('Disconnect')
    def remove_button = @remove_button ||= menu_button('Remove')
    def properties_button = @properties_button ||= menu_button('Properties')

    private

      def menu_button(label)
        Gtk::Button.new(label: label).tap do |button|
          button.halign = :fill
          button.add_css_class('flat')
        end
      end

      def install_account_actions
        target = GLib::Variant.new(@account.object_path)

        {
          connect_button    => 'app.connect-account',
          disconnect_button => 'app.disconnect-account',
          reconnect_button  => 'app.reconnect-account',
          remove_button     => 'app.remove-connection',
          properties_button => 'app.edit-connection',
        }.each do |button, action|
          button.action_name = action
          button.set_action_target_value(target)
        end
      end

      def connect_signals
        signal_connect('closed') do
          password_entry.text = ''
        end

        password_entry.signal_connect('activate') do
          Gio::Application.default.lookup_action('authenticate-account').activate(
            GLib::Variant.new([@account.object_path, password_entry.text]),
          )
          popdown
        end
      end
  end

  # RoomListHeader is the sidebar's per-network header: the account name, an
  # icon telling its connection state, and the connection popover.
  #
  # Ported from the RoomListHeader class in src/roomList.js plus
  # data/ui/room-list-header.ui, including the state-to-icon mapping and the
  # wording of every status and error line. Upstream derives from Gtk.Widget
  # with a grid layout and an ::activate signal; a Ruby subclass cannot
  # implement a widget's measure and allocate, so this is a Gtk::Box carrying
  # the same style classes.
  class RoomListHeader < Gtk::Box
    def initialize(account)
      super(:vertical, 0)
      @account = account
      @spinner_activation_time = nil

      self.name = "RoomListHeader #{account.display_name}"
      self.focusable = true
      self.margin_top = 1
      add_css_class('room-list-header')
      add_css_class('activatable')
      add_css_class('dim-label')
    end

    def build
      tap do |header|
        header.append(line)
        header.append(separator)

        line.tap do |box|
          box.append(label)
          box.append(icon_stack)
        end

        icon_stack.tap do |stack|
          stack.add_named(state_image('network-offline-symbolic'), 'disconnected')
          stack.add_named(state_image('dialog-error-symbolic'), 'error')
          stack.add_named(spinner, 'connecting')
          stack.add_named(state_image('dialog-password-symbolic'), 'auth')
          stack.add_named(state_image('pan-down-symbolic'), 'default')
        end

        popover.build
        popover.set_parent(header)
        header.add_controller(click_gesture)

        @account.connect('notify::display-name') { on_display_name_changed }
        @account.connect('notify::connection-status') { on_connection_status_changed }
        @account.connect('notify::requested-presence-type') { on_requested_presence_changed }

        on_display_name_changed
        on_requested_presence_changed
      end
    end

    def popover = @popover ||= ConnectionPopover.new(@account)

    def line = @line ||= Gtk::Box.new(:horizontal, 6)

    def label
      @label ||= Gtk::Label.new.tap do |widget|
        widget.xalign = 0
        widget.hexpand = true
        widget.max_width_chars = 15
        widget.ellipsize = :end
      end
    end

    def icon_stack
      @icon_stack ||= Gtk::Stack.new.tap do |stack|
        stack.transition_type = :crossfade
        stack.valign = :center
      end
    end

    def spinner = @spinner ||= Adwaita::Spinner.new
    def separator = @separator ||= Gtk::Separator.new(:horizontal)

    def click_gesture
      @click_gesture ||= Gtk::GestureClick.new.tap do |gesture|
        gesture.propagation_phase = :capture
        gesture.button = 0
        gesture.signal_connect('released') { on_released(gesture) }
      end
    end

    private

      def state_image(icon_name)
        Gtk::Image.new.tap { |image| image.icon_name = icon_name }
      end

      def on_released(gesture)
        button = gesture.current_button

        if [Gdk::BUTTON_PRIMARY, Gdk::BUTTON_SECONDARY].include?(button)
          gesture.state = Gtk::EventSequenceState::CLAIMED
          popover.popup
        end
      end

      def on_display_name_changed
        label.label = @account.display_name.to_s
        on_connection_status_changed
      end

      # An account the user asked to be offline reads as disconnected, no
      # matter what the connection last reported.
      def connection_status
        if @account.requested_presence_type == Account::PRESENCE_OFFLINE
          Account::STATUS_DISCONNECTED
        else
          @account.connection_status
        end
      end

      def on_connection_status_changed
        status = connection_status
        error = error?(status)
        auth = error && @account.connection_error == Account::ERROR_AUTHENTICATION_FAILED

        icon_stack.visible_child_name = icon_page(status, error, auth)
        popover.title_label.visible = !auth

        if error
          show_error_state
        else
          show_status_state
        end
      end

      def error?(status)
        status == Account::STATUS_DISCONNECTED &&
          @account.connection_status_reason != Account::REASON_REQUESTED
      end

      def icon_page(status, error, auth)
        if status == Account::STATUS_CONNECTING
          'connecting'
        elsif error
          auth ? 'auth' : 'error'
        elsif status == Account::STATUS_DISCONNECTED
          'disconnected'
        else
          'default'
        end
      end

      def show_status_state
        popover.status_label.add_css_class('dim-label')
        popover.status_label.add_css_class('caption')
        popover.title_label.remove_css_class('heading')

        popover.title_label.label = popover_title
        popover.status_label.label = status_label_text
      end

      def show_error_state
        popover.status_label.remove_css_class('dim-label')
        popover.status_label.remove_css_class('caption')
        popover.title_label.add_css_class('heading')

        popover.title_label.label = 'Connection Problem'
        popover.status_label.label = error_label_text
      end

      # "Libera (irc.libera.chat)", unless the two are the same.
      def popover_title
        name = @account.display_name.to_s
        server = @account.parameters['server'].to_s

        if name == server
          name
        else
          format('%s (%s)', name, server)
        end
      end

      def status_label_text
        case connection_status
        when Account::STATUS_CONNECTED then 'Connected'
        when Account::STATUS_CONNECTING then 'Connecting…'
        when Account::STATUS_DISCONNECTED then 'Offline'
        else 'Unknown'
        end
      end

      def error_label_text
        name = @account.display_name.to_s

        case @account.connection_error
        when Account::ERROR_CERT_UNTRUSTED
          format('Could not connect to %s in a safe way.', name)
        when Account::ERROR_AUTHENTICATION_FAILED
          format('%s requires a password.', name)
        when Account::ERROR_CONNECTION_FAILED
          format('Could not connect to %s. The server is busy.', name)
        else
          format('Could not connect to %s.', name)
        end
      end

      def on_requested_presence_changed
        offline = @account.requested_presence_type == Account::PRESENCE_OFFLINE

        popover.connect_button.visible = offline
        popover.disconnect_button.visible = !offline
        popover.reconnect_button.visible = !offline
        on_connection_status_changed
      end
  end

  # RoomRowPopover is the context menu of a sidebar row: mute/unmute for a
  # private conversation, and leaving the room or ending the conversation.
  #
  # Ported from the RoomRowPopover class in src/roomList.js.
  class RoomRowPopover < Gtk::PopoverMenu
    def initialize(row, user_tracker)
      super(Gio::Menu.new)
      @row = row
      @user_tracker = user_tracker

      self.position = :bottom
    end

    def build
      tap do |popover|
        popover.set_parent(@row)
        popover.menu_model = menu

        unless @row.room.room?
          menu.append_item(mute_item)
        end
        menu.append_item(leave_item)

        popover.signal_connect('notify::visible') { on_visible_changed }
      end
    end

    def menu = @menu ||= Gio::Menu.new

    private

      def leave_item
        label = @row.room.room? ? 'Leave chatroom' : 'End conversation'

        Gio::MenuItem.new(label, nil).tap do |item|
          item.set_action_and_target_value(
            'app.leave-room',
            GLib::Variant.new([@row.room.id, '']),
          )
        end
      end

      def mute_item
        @mute_item ||= Gio::MenuItem.new(nil, nil)
      end

      def mute_target
        GLib::Variant.new([@row.room.account.object_path, @row.room.channel_name])
      end

      def on_visible_changed
        if visible?
          add_css_class('has-open-popup')
          unless @row.room.room?
            update_mute_item
          end
        else
          remove_css_class('has-open-popup')
        end
      end

      def update_mute_item
        menu.remove(0)

        if @row.muted?
          mute_item.label = 'Unmute'
          mute_item.set_action_and_target_value('app.unmute-nick', mute_target)
        else
          mute_item.label = 'Mute'
          mute_item.set_action_and_target_value('app.mute-nick', mute_target)
        end

        menu.insert_item(0, mute_item)
      end
  end

  # RoomRow is one room in the sidebar: its name, the unread-highlight
  # counter, and the loading indicator while the room is being joined.
  #
  # Ported from the RoomRow class in src/roomList.js plus
  # data/ui/room-list-row.ui, including the three-second delay before a room
  # that is still joining shows its spinner, the muted emblem, the "inactive"
  # style class for a room with nothing unread, and the counter doubling as a
  # search-match count while the sidebar is filtered.
  class RoomRow < Gtk::ListBoxRow
    CONNECTING_TIMEOUT = 3

    def initialize(room, user_tracker)
      super()
      @room = room
      @user_tracker = user_tracker
      @matches = 0
      @search_mode = false
      @popover = nil
      @connecting_timeout = nil

      self.name = "RoomRow #{room.display_name}"
      self.margin_bottom = 4
      self.focus_on_click = false
      self.action_name = 'navigation.push'
      set_action_target_value(GLib::Variant.new('content'))
    end

    attr_reader :room

    def account = @room.account

    def muted? = @user_tracker.muted?(@room.channel_name)

    # A room with unread messages keeps the "inactive" class off.
    def pending? = !has_css_class('inactive')

    def build
      tap do |row|
        row.child = box

        box.tap do |line|
          line.append(icon)
          line.append(room_label)
          line.append(event_stack)
          line.add_controller(click_gesture)
        end

        event_stack.tap do |stack|
          stack.add_named(loading_image, 'connecting')
          stack.add_named(counter_frame, 'messages')
        end

        row.add_controller(key_controller)

        icon.visible = !@room.icon.nil?
        @room.connect('notify::display-name') { room_label.label = @room.display_name.to_s }
        @room.connect('notify::channel') { on_channel_changed }
        room_label.label = @room.display_name.to_s

        if @room.room?
          account.connect('notify::connection-status') { on_connection_status_changed }
          on_connection_status_changed
        else
          @user_tracker.connect("muted-changed::#{@room.channel_name}") { on_muted_changed }
          on_muted_changed
        end

        update_counter
        on_channel_changed
        event_stack.visible_child_name = 'messages'
      end
    end

    # Called when the row becomes the selected one: a room without a channel
    # has nothing to acknowledge, so its counter is just refreshed.
    def selected
      if @room.channel.nil?
        update_counter
      end
    end

    def search_mode=(enabled)
      @search_mode = enabled
      update_counter
    end

    def matches=(matches)
      @matches = matches
      self.search_mode = true
    end

    def matches? = @search_mode && @matches.positive?

    def box
      @box ||= Gtk::Box.new(:horizontal, 6).tap do |line|
        line.margin_start = 8
        line.margin_end = 8
        line.margin_top = 2
        line.margin_bottom = 2
      end
    end

    def icon
      @icon ||= Gtk::Image.new.tap do |image|
        image.valign = :center
        image.icon_size = :normal
        image.gicon = @room.icon
      end
    end

    def room_label
      @room_label ||= Gtk::Label.new.tap do |label|
        label.halign = :start
        label.valign = :center
        label.hexpand = true
        label.ellipsize = :end
      end
    end

    def event_stack
      @event_stack ||= Gtk::Stack.new.tap do |stack|
        stack.transition_type = :crossfade
      end
    end

    def loading_image
      @loading_image ||= Gtk::Image.new.tap do |image|
        image.valign = :center
        image.icon_size = :normal
        image.icon_name = 'content-loading-symbolic'
        image.add_css_class('polari-room-loading')
      end
    end

    def counter_frame
      @counter_frame ||= Gtk::AspectFrame.new(0.5, 0.5, 1.0, false).tap do |frame|
        frame.child = counter
      end
    end

    def counter
      @counter ||= Gtk::Label.new.tap do |label|
        label.width_chars = 3
        label.add_css_class('pending-messages-count')
      end
    end

    def click_gesture
      @click_gesture ||= Gtk::GestureClick.new.tap do |gesture|
        gesture.button = Gdk::BUTTON_SECONDARY
        gesture.signal_connect('released') do
          gesture.state = Gtk::EventSequenceState::CLAIMED
          show_popover
        end
      end
    end

    def key_controller
      @key_controller ||= Gtk::EventControllerKey.new.tap do |controller|
        controller.signal_connect('key-pressed') do |_c, keyval, _code, state|
          on_key_pressed(keyval, state)
        end
      end
    end

    private

      def on_key_pressed(keyval, state)
        shift = !(state.to_i & Gdk::ModifierType::SHIFT_MASK.to_i).zero?

        if keyval == Gdk::Keyval::KEY_Menu || (keyval == Gdk::Keyval::KEY_F10 && shift)
          show_popover
          true
        else
          false
        end
      end

      def show_popover
        @popover ||= RoomRowPopover.new(self, @user_tracker).build
        @popover.popup
      end

      def muted_icon
        @muted_icon ||= Gio::EmblemedIcon.new(@room.icon).tap do |emblemed|
          emblemed.add_emblem(Gio::Emblem.new(Gio::ThemedIcon.new('emblem-unreadable')))
        end
      end

      def on_muted_changed
        if muted?
          icon.gicon = muted_icon
          add_css_class('muted')
        else
          icon.gicon = @room.icon
          remove_css_class('muted')
        end
        update_counter
      end

      def num_pending
        if @room.channel.respond_to?(:pending_messages)
          pending = @room.channel.pending_messages
          [pending.length, highlight_count(pending)]
        else
          [0, 0]
        end
      end

      def highlight_count(pending)
        if muted?
          0
        else
          pending.count { |message| @room.should_highlight_message?(message.sender, message.text) }
        end
      end

      def update_counter
        if @search_mode
          update_search_counter
        else
          update_pending_counter
        end
      end

      def update_search_counter
        counter.label = @matches > 99 ? '99+' : @matches.to_s
        counter.opacity = @matches.positive? ? 1.0 : 0.0
      end

      def update_pending_counter
        pending, highlights = num_pending

        counter.label = highlights.to_s
        counter.opacity = highlights.positive? ? 1.0 : 0.0

        if pending.zero?
          add_css_class('inactive')
        else
          remove_css_class('inactive')
        end
      end

      # A room that is taking its time to join gets a spinner, but only after
      # three seconds, so a quick join does not flicker.
      def on_connection_status_changed
        status = @room.room? && connection_status

        if status == Account::STATUS_CONNECTED && @room.channel.nil?
          start_connecting_timeout
        else
          clear_connecting_timeout
          event_stack.visible_child_name = 'messages'
        end
      end

      def connection_status
        if account.requested_presence_type == Account::PRESENCE_OFFLINE
          Account::STATUS_DISCONNECTED
        else
          account.connection_status
        end
      end

      def start_connecting_timeout
        clear_connecting_timeout
        @connecting_timeout = GLib::Timeout.add_seconds(CONNECTING_TIMEOUT) do
          @connecting_timeout = nil
          if @room.channel.nil?
            event_stack.visible_child_name = 'connecting'
          end
          false
        end
      end

      def clear_connecting_timeout
        if @connecting_timeout
          GLib::Source.remove(@connecting_timeout)
        end
        @connecting_timeout = nil
      end

      def on_channel_changed
        if @room.channel
          clear_connecting_timeout
          event_stack.visible_child_name = 'messages'
        end
        update_counter
      end
  end

  # RoomList is the sidebar: the rooms of every visible account, grouped
  # under their network's header, with a hidden placeholder row keeping the
  # header of an account that has no rooms yet.
  #
  # Ported from the RoomList class in src/roomList.js: the header, sort and
  # filter functions, the next/previous/nth-room actions, the search mode
  # that turns the counters into match counts and hides the rooms without
  # matches, and moving the selection off a row that is being removed.
  #
  # Upstream reaches the window through ::notify::active-room from
  # vfunc_realize; a Ruby subclass has no vfunc_realize, so the window calls
  # active_room= and reads #selected_room, and the selection callback is
  # passed in.
  class RoomList < Gtk::ListBox
    def initialize(
      accounts_monitor: AccountsMonitor.default,
      room_manager: RoomManager.default,
      user_status_monitor: UserStatusMonitor.default,
      on_room_selected: nil,
      on_filter_changed: nil
    )
      super()
      @accounts_monitor = accounts_monitor
      @room_manager = room_manager
      @user_status_monitor = user_status_monitor
      @on_room_selected = on_room_selected
      @on_filter_changed = on_filter_changed
      @placeholders = {}
      @room_rows = {}
      @search_mode = false
      @selecting = false

      self.selection_mode = :browse
      add_css_class('polari-room-list')
      add_css_class('navigation-sidebar')
    end

    def build
      tap do |list|
        list.set_header_func { |row, before| update_header(row, before) }
        list.set_sort_func { |row1, row2| sort_rows(row1, row2) }
        list.set_filter_func { |row| filter_row(row) }
        list.signal_connect('row-selected') { |_l, row| on_row_selected(row) }

        connect_accounts
        connect_rooms
        install_actions
      end
    end

    def log_finder = @log_finder ||= LogFinder.new(@room_manager)

    def selected_room
      selected_row.then { |row| row.respond_to?(:room) ? row.room : nil }
    end

    # Selects the row of the window's active room without bouncing the
    # selection back at the window.
    def active_room=(room)
      @room_rows[room&.id].then do |row|
        if row
          @selecting = true
          row.can_focus = false
          select_row(row)
          row.can_focus = true
          @selecting = false
        end
      end
    end

    def search_mode=(enabled)
      unless enabled == @search_mode
        @search_mode = enabled
        @room_rows.each_value { |row| row.search_mode = enabled }
        invalidate_filter
        invalidate_sort

        unless enabled
          log_finder.cancel
        end
        @on_filter_changed&.call
      end
    end

    # Counts the matches of every room and shows only the rooms that have
    # any.
    def search(terms)
      self.search_mode = true
      results = log_finder.count_results(terms)

      @room_manager.rooms.each do |room|
        @room_rows[room.id].then do |row|
          if row
            row.matches = results[room] || 0
          end
        end
      end

      invalidate_filter
      @on_filter_changed&.call
    end

    # The rooms the search view should show sections for.
    def search_rooms
      if @search_mode
        @room_manager.rooms.select do |room|
          @room_rows[room.id].then { |row| row && filter_row(row) }
        end
      else
        []
      end
    end

    private

      def connect_accounts
        @accounts_monitor.connect('account-added') { |_m, account| account_added(account) }
        @accounts_monitor.connect('account-removed') { |_m, account| account_removed(account) }
        @accounts_monitor.connect('account-shown') do |_m, account|
          update_placeholder_visibility(account)
        end
        @accounts_monitor.connect('account-hidden') do |_m, account|
          update_placeholder_visibility(account)
        end

        @accounts_monitor.prepare do
          @accounts_monitor.accounts.each { |account| account_added(account) }
        end
      end

      def connect_rooms
        @room_manager.connect('room-added') { |_m, room| room_added(room) }
        @room_manager.connect('room-removed') { |_m, room| room_removed(room) }
        @room_manager.rooms.each { |room| room_added(room) }
      end

      def install_actions
        app = Gio::Application.default

        {
          'next-room'          => -> { move_selection(:down) },
          'previous-room'      => -> { move_selection(:up) },
          'first-room'         => -> { select_room_at_index(0) },
          'last-room'          => -> { select_room_at_index(@room_manager.room_count - 1) },
          'next-pending-room'  => -> { move_to_pending(:down) },
          'previous-pending-room' => -> { move_to_pending(:up) },
        }.each do |name, handler|
          app.lookup_action(name).then do |action|
            if action
              action.signal_connect('activate') { handler.call }
            end
          end
        end

        app.lookup_action('nth-room').then do |action|
          if action
            action.signal_connect('activate') do |_a, param|
              select_room_at_index(param.to_i - 1)
            end
          end
        end
      end

      def room_rows = children.select { |row| row.is_a?(RoomRow) }

      def room_row_at_index(index)
        rows = room_rows
        if index >= 0 && index < rows.length
          rows[index]
        end
      end

      def select_room_at_index(index)
        room_row_at_index(index).then do |row|
          if row
            select_row(row)
          end
        end
      end

      def move_selection(direction)
        move_selection_full(direction) { true }
      end

      def move_to_pending(direction)
        move_selection_full(direction) { |row| row.pending? && !row.muted? }
      end

      def move_selection_full(direction, &test)
        current = selected_row

        if current.is_a?(RoomRow)
          rows = room_rows
          increment = direction == :up ? -1 : 1
          index = rows.index(current).to_i
          candidate = nil

          loop do
            index += increment
            candidate = room_row_at_index(index)
            if candidate.nil? || test.call(candidate)
              break
            end
          end

          if candidate
            select_row(candidate)
          end
        end
      end

      def account_added(account)
        unless @placeholders.key?(account)
          Gtk::ListBoxRow.new.tap do |placeholder|
            placeholder.selectable = false
            placeholder.activatable = false
            placeholder.visible = false
            @placeholders[account] = placeholder
            append(placeholder)
            placeholder.signal_connect('notify::visible') { invalidate_sort }
          end
          update_placeholder_visibility(account)
        end
      end

      def account_removed(account)
        @placeholders.delete(account).then do |placeholder|
          if placeholder
            remove(placeholder)
          end
        end
      end

      def room_added(room)
        unless @room_rows.key?(room.id)
          tracker = @user_status_monitor.user_tracker_for_account(room.account)

          RoomRow.new(room, tracker).build.tap do |row|
            append(row)
            @room_rows[room.id] = row
            account_added(room.account)
            @placeholders[room.account]&.visible = false
          end
        end
      end

      def room_removed(room)
        @room_rows[room.id].then do |row|
          if row
            move_selection_from_row(row)
            remove(row)
            @room_rows.delete(room.id)
            update_placeholder_visibility(room.account)
          end
        end
      end

      # When the selected room goes away, the selection moves to its
      # neighbour rather than disappearing.
      def move_selection_from_row(row)
        if selected_row == row
          index = room_rows.index(row).to_i
          move_selection(index.zero? ? :down : :up)
        end
      end

      def update_placeholder_visibility(account)
        @placeholders[account].then do |placeholder|
          if placeholder
            has_rooms = @room_rows.each_value.any? { |row| row.account == account }
            placeholder.visible = account.visible? && !has_rooms
          end
        end
      end

      def on_row_selected(row)
        unless @selecting
          @on_room_selected&.call(row.respond_to?(:room) ? row.room : nil)
        end

        if row.respond_to?(:selected)
          row.selected
        end
      end

      def row_account(row)
        if row.respond_to?(:account)
          row.account
        else
          @placeholders.key(row)
        end
      end

      # A header is created for the first row of each account, and removed
      # from the rows that follow it.
      def update_header(row, before)
        account = row_account(row)
        before_account = before.nil? ? nil : row_account(before)

        if before_account == account
          row.header = nil
        elsif row.header.nil?
          row.header = RoomListHeader.new(account).build
        end
      end

      # Accounts with rooms come first, then by display name; inside an
      # account, rooms come before private conversations.
      def sort_rows(row1, row2)
        account1 = row_account(row1)
        account2 = row_account(row2)

        if account1 != account2
          sort_accounts(account1, account2)
        else
          sort_rooms(row1, row2)
        end
      end

      def sort_accounts(account1, account2)
        has_rooms1 = !@placeholders[account1]&.visible?
        has_rooms2 = !@placeholders[account2]&.visible?

        if has_rooms1 != has_rooms2
          has_rooms1 ? -1 : 1
        elsif account1.display_name != account2.display_name
          account1.display_name.to_s <=> account2.display_name.to_s
        else
          account1.path_suffix <=> account2.path_suffix
        end
      end

      def sort_rooms(row1, row2)
        room1 = row1.respond_to?(:room) ? row1.room : nil
        room2 = row2.respond_to?(:room) ? row2.room : nil

        if room1.nil?
          -1
        elsif room2.nil?
          1
        elsif room1.room? != room2.room?
          room1.room? ? -1 : 1
        else
          room1.display_name.to_s <=> room2.display_name.to_s
        end
      end

      def filter_row(row)
        if !@search_mode || !row.respond_to?(:room)
          true
        else
          row.matches?
        end
      end
  end
end
