# frozen_string_literal: true

require 'adwaita'
require_relative 'util'
require_relative 'utils'
require_relative 'user_tracker'

module Polari
  # UserDetails is the expandable part of a user row and of the user
  # popover: the spinner while the contact's details are loading, then a grid
  # with last activity, full name and the notification note, and the button
  # that starts a private conversation.
  #
  # Ported from the UserDetails class in src/userList.js plus
  # data/ui/user-details.ui. The details themselves come from the contact
  # object the IRC transport provides (its #alias and #contact_info); with no
  # transport there is no contact, which is the same case upstream handles by
  # showing the notification label instead of the activity line.
  class UserDetails < Gtk::Box
    def initialize(user: nil)
      super(:vertical, 2)
      @user = user
      @nickname = nil
      @expanded = false
      @notifications_enabled = false
      @initial_details_loaded = false

      self.margin_start = 9
      self.margin_end = 9
      self.margin_top = 9
      self.margin_bottom = 9
      self.hexpand = true
    end

    def build
      tap do |box|
        box.append(spinner_box)
        box.append(details_grid)
        box.append(separator)
        box.append(message_button)

        message_button.signal_connect('clicked') { on_message_button_clicked }

        details_grid.tap do |grid|
          grid.attach(activity_icon, 0, 0, 1, 1)
          grid.attach(activity_label, 0, 0, 1, 1)
          grid.attach(last_label, 1, 0, 1, 1)
          grid.attach(avatar_icon, 0, 1, 1, 1)
          grid.attach(fullname_label, 0, 1, 2, 1)
          grid.attach(notification_icon, 0, 2, 1, 1)
          grid.attach(notification_label, 0, 2, 2, 1)
        end

        details_grid.visible = false
        update_button_visibility
        update_labels_visibility
      end
    end

    def user = @user

    def user=(user)
      unless user == @user
        @user = user

        if @expanded
          expand
        end
        update_button_visibility
        update_labels_visibility
      end
    end

    def nickname=(nickname)
      @nickname = nickname

      if fullname_label.label.to_s.empty?
        fullname_label.label = nickname.to_s
      end
      update_button_visibility
    end

    def expanded = @expanded

    def expanded=(value)
      unless value == @expanded
        @expanded = value
        if value
          expand
        end
      end
    end

    def notifications_enabled=(value)
      @notifications_enabled = value
      notification_label.opacity = value ? 1.0 : 0.0
      notification_icon.opacity = notification_label.opacity
    end

    def spinner_box
      @spinner_box ||= Gtk::Box.new(:horizontal, 6).tap do |box|
        box.margin_start = 12
        box.margin_end = 12
        box.margin_top = 12
        box.margin_bottom = 12
        box.hexpand = true
        box.halign = :center
        box.append(Adwaita::Spinner.new)
        box.append(Gtk::Label.new('Loading details'))
      end
    end

    def details_grid
      @details_grid ||= Gtk::Grid.new.tap do |grid|
        grid.row_spacing = 6
        grid.column_spacing = 6
        grid.margin_end = 18
        grid.hexpand = true
      end
    end

    def activity_icon = @activity_icon ||= dim_image('document-open-recent-symbolic')
    def avatar_icon = @avatar_icon ||= dim_image('avatar-default-symbolic')
    def notification_icon = @notification_icon ||= dim_image('polari-user-notify-symbolic')

    def activity_label
      @activity_label ||= Gtk::Label.new('Last Activity:').tap do |label|
        label.valign = :start
        label.halign = :start
        label.margin_start = 20
        label.add_css_class('dim-label')
      end
    end

    def last_label
      @last_label ||= Gtk::Label.new.tap do |label|
        label.valign = :end
        label.wrap = true
        label.hexpand = true
        label.halign = :start
        label.visible = false
        label.add_css_class('dim-label')
      end
    end

    def fullname_label
      @fullname_label ||= Gtk::Label.new.tap do |label|
        label.ellipsize = :end
        label.halign = :start
        label.margin_start = 20
        label.hexpand = true
        label.max_width_chars = 25
        label.add_css_class('dim-label')
      end
    end

    def notification_label
      @notification_label ||= Gtk::Label.new('Will notify if user appears online.').tap do |label|
        label.ellipsize = :end
        label.halign = :start
        label.margin_start = 20
        label.hexpand = true
        label.add_css_class('dim-label')
      end
    end

    def separator
      @separator ||= Gtk::Separator.new(:horizontal).tap do |widget|
        widget.margin_top = 7
      end
    end

    def message_button
      @message_button ||= Gtk::Button.new(label: 'Start Conversation').tap do |button|
        button.halign = :fill
        button.hexpand = true
        button.visible = false
        button.add_css_class('flat')
      end
    end

    private

      def dim_image(icon_name)
        Gtk::Image.new.tap do |image|
          image.icon_name = icon_name
          image.halign = :start
          image.add_css_class('dim-label')
        end
      end

      def expand
        details_grid.visible = @initial_details_loaded
        spinner_box.visible = !@initial_details_loaded

        if @user
          on_contact_info_ready
        else
          reveal_details
        end
      end

      def on_contact_info_ready
        @initial_details_loaded = true
        info = @user.respond_to?(:contact_info) ? @user.contact_info : {}

        fullname_label.label = info['fn'] || @user.alias.to_s

        info['x-idle-time'].then do |last|
          if last
            last_label.label = Utils.format_time_passed(last)
            last_label.visible = true
          else
            last_label.visible = false
          end
        end

        reveal_details
      end

      def reveal_details
        spinner_box.visible = false
        details_grid.visible = true
      end

      def update_labels_visibility
        notification_label.visible = @user.nil?
        activity_label.visible = !@user.nil?
        activity_icon.visible = last_label.visible?
        notification_icon.visible = notification_label.visible?
      end

      def on_message_button_clicked
        account = @user.account
        Gio::Application.default
                        .lookup_action('query-user')
                        .activate(GLib::Variant.new([account.object_path, @user.alias]))
      end

      # The button is pointless for ourselves, and impossible without a
      # contact.
      def update_button_visibility
        if @user.nil?
          message_button.sensitive = false
        else
          message_button.sensitive = true
          message_button.visible = !own_contact?
        end
      end

      def own_contact?
        @user.respond_to?(:self?) && @user.self?
      end
  end

  # UserPopover is what a nick in the chat log opens: the nick, its online
  # status, the bell that asks to be told when the user comes back, and the
  # details below.
  #
  # Ported from the UserPopover class in src/userList.js plus
  # data/ui/user-popover.ui.
  class UserPopover < Gtk::Popover
    def initialize(room:, user_tracker:)
      super()
      @room = room
      @user_tracker = user_tracker
      @nickname = nil
      @basenick = nil
      @room_status_handler = nil
      @status_handler = nil
      @contacts_handler = nil

      self.hexpand = false
      set_size_request(280, -1)
    end

    attr_reader :nickname

    def build
      tap do |popover|
        popover.child = box

        box.tap do |vbox|
          vbox.append(header_box)
          vbox.append(user_details.build)

          header_box.tap do |hbox|
            hbox.append(label_box)
            hbox.append(notify_button)

            label_box.tap do |labels|
              labels.append(nick_label)
              labels.append(status_label)
            end
          end
        end

        notify_button.bind_property('sensitive', notify_button, 'visible', :sync_create)
        popover.signal_connect('notify::visible') do
          user_details.expanded = popover.visible?
        end
        notify_button.signal_connect('toggled') do
          user_details.notifications_enabled = notify_button.active?
        end
      end
    end

    def nickname=(nickname)
      if !nickname.nil? && nickname != @nickname
        @nickname = nickname
        nick_label.label = nickname
        user_details.nickname = nickname
        notify_button.action_name = @user_tracker.notify_action_name(nickname)

        set_basenick(Util.get_basenick(nickname))
      end
    end

    def box = @box ||= Gtk::Box.new(:vertical, 0)

    def header_box
      @header_box ||= Gtk::Box.new(:horizontal, 0).tap do |hbox|
        hbox.halign = :fill
        hbox.margin_start = 9
        hbox.margin_end = 9
        hbox.margin_top = 9
        hbox.margin_bottom = 9
      end
    end

    def label_box
      @label_box ||= Gtk::Box.new(:vertical, 0).tap do |vbox|
        vbox.halign = :fill
      end
    end

    def nick_label
      @nick_label ||= Gtk::Label.new.tap do |label|
        label.halign = :start
        label.ellipsize = :end
        label.max_width_chars = 17
        label.add_css_class('polari-user-popover-nick')
      end
    end

    def status_label
      @status_label ||= Gtk::Label.new.tap do |label|
        label.halign = :start
        label.use_markup = true
        label.add_css_class('polari-user-popover-status')
        label.add_css_class('dim-label')
      end
    end

    def notify_button
      @notify_button ||= Gtk::ToggleButton.new.tap do |button|
        button.hexpand = true
        button.halign = :end
        button.valign = :center
        button.icon_name = 'polari-user-notify-symbolic'
      end
    end

    def user_details
      @user_details ||= UserDetails.new
    end

    private

      def set_basenick(basenick)
        unless basenick == @basenick
          @basenick = basenick

          rewatch_room_status
          rewatch_global_status

          on_status_changed
          user_details.user = @user_tracker.lookup_contact(@nickname)
        end
      end

      def rewatch_room_status
        if @room_status_handler
          @user_tracker.unwatch_room_status(@room, @room_status_handler)
        end
        @room_status_handler = @user_tracker.watch_room_status(@room, @basenick) do
          on_status_changed
        end
      end

      def rewatch_global_status
        [@status_handler, @contacts_handler].compact.each do |id|
          @user_tracker.disconnect(id)
        end

        @status_handler = @user_tracker.connect("status-changed::#{@basenick}") do
          on_status_changed
        end
        @contacts_handler = @user_tracker.connect("contacts-changed::#{@basenick}") do
          user_details.user = @user_tracker.lookup_contact(@nickname)
        end
      end

      def on_status_changed
        status = @user_tracker.nick_status(@nickname)
        room_status = @user_tracker.nick_room_status(@nickname, @room)

        status_label.label = status_text(status, room_status)
        update_nick_style(status)
      end

      def status_text(status, room_status)
        if status != room_status
          'Available in another room.'
        elsif status == UserTracker::STATUS_AVAILABLE
          'Online'
        else
          'Offline'
        end
      end

      def update_nick_style(status)
        if status == UserTracker::STATUS_AVAILABLE
          nick_label.remove_css_class('polari-inactive-nick')
          nick_label.add_css_class('polari-active-nick')
        else
          nick_label.remove_css_class('polari-active-nick')
          nick_label.add_css_class('polari-inactive-nick')
        end
      end
  end

  # UserListRow is one user in the user list: the nick, with the matched part
  # of the filter in bold, an arrow that appears on hover, and the details
  # that slide out when the row is activated.
  #
  # Ported from the UserListRow class in src/userList.js.
  class UserListRow < Gtk::ListBoxRow
    MAX_USERS_WIDTH_CHARS = 17

    def initialize(user)
      super()
      @user = user
      @filter = ''
      self.name = "UserListRow #{user.alias}"
    end

    attr_reader :user
    attr_reader :filter

    def build
      tap do |row|
        row.child = vbox

        vbox.tap do |box|
          box.append(hbox)
          box.append(revealer)

          hbox.tap do |line|
            line.append(label)
            line.append(arrow)
          end
        end

        row.signal_connect('unmap') { revealer.reveal_child = false }
        row.signal_connect('state-flags-changed') { update_arrow_visibility }
        revealer.signal_connect('notify::reveal-child') { on_expanded_changed }

        update_label
      end
    end

    def filter=(value)
      @filter = value.to_s
      update_label
    end

    def expand = revealer.reveal_child?

    def expand=(value)
      if value
        ensure_details
      end
      revealer.reveal_child = value
    end

    def should_show? = @user.alias.to_s.downcase.include?(@filter.downcase)

    def vbox = @vbox ||= Gtk::Box.new(:vertical, 0)

    def hbox
      @hbox ||= Gtk::Box.new(:horizontal, 4).tap do |box|
        box.margin_start = 4
        box.margin_end = 12
        box.margin_top = 4
        box.margin_bottom = 4
      end
    end

    def arrow
      @arrow ||= Gtk::Image.new.tap do |image|
        image.icon_name = 'pan-end-symbolic'
        image.visible = false
      end
    end

    def label
      @label ||= Gtk::Label.new.tap do |widget|
        widget.halign = :start
        widget.hexpand = true
        widget.use_markup = true
        widget.ellipsize = :end
        widget.max_width_chars = MAX_USERS_WIDTH_CHARS
      end
    end

    def revealer
      @revealer ||= Gtk::Revealer.new.tap do |widget|
        widget.reveal_child = false
      end
    end

    private

      # Upstream binds the revealer's reveal-child to the details' expanded
      # property; "expanded" is a plain Ruby accessor here rather than a
      # GObject property, so the notification drives it instead.
      def ensure_details
        if revealer.child.nil?
          UserDetails.new(user: @user).build.tap do |details|
            revealer.child = details
            revealer.signal_connect('notify::reveal-child') do
              details.expanded = revealer.reveal_child?
            end
          end
        end
      end

      def update_label
        escaped = Regexp.escape(@filter)
        label.label =
          if escaped.empty?
            @user.alias.to_s
          else
            @user.alias.to_s.sub(/(#{escaped})/i) { "<b>#{Regexp.last_match(1)}</b>" }
          end
      end

      def update_arrow_visibility
        flags = state_flags
        arrow.visible = expand ||
                        flags.prelight? ||
                        flags.focused?
      end

      def on_expanded_changed
        if revealer.reveal_child?
          add_css_class('expanded')
          arrow.icon_name = 'pan-down-symbolic'
        else
          remove_css_class('expanded')
          arrow.icon_name = 'pan-end-symbolic'
          update_arrow_visibility
        end
      end
  end

  # UserList is the scrolled list of a room's members, with the "No Results"
  # page for when the filter matches nothing.
  #
  # Ported from the UserList class in src/userList.js plus
  # data/ui/user-list.ui.
  class UserList < Gtk::ScrolledWindow
    def initialize(room)
      super()
      @room = room
      @rows = {}
      @filter = ''
      @active_row = nil
      @room_signals = []

      self.hexpand = true
      self.has_frame = true
      self.hscrollbar_policy = :never
      self.propagate_natural_height = true
      self.propagate_natural_width = true
    end

    def num_rows = @rows.size

    def build
      tap do
        self.child = stack

        stack.tap do |pages|
          pages.add_named(list, 'list')
          pages.add_named(placeholder, 'placeholder')
        end

        list.tap do |box|
          box.set_filter_func { |row| filter_row(row) }
          box.set_sort_func { |row1, row2| row1.user.alias.to_s <=> row2.user.alias.to_s }
          box.signal_connect('row-activated') { |_box, row| on_row_activated(row) }
        end

        connect_room
        on_channel_changed
      end
    end

    def set_filter(filter)
      @filter = filter.to_s
      list.invalidate_filter
      sync_visible_page
    end

    def stack
      @stack ||= Gtk::Stack.new.tap do |widget|
        widget.vhomogeneous = false
      end
    end

    def list
      @list ||= Gtk::ListBox.new.tap do |box|
        box.selection_mode = :none
        box.vexpand = true
      end
    end

    def placeholder
      @placeholder ||= Adwaita::StatusPage.new.tap do |page|
        page.icon_name = 'edit-find-symbolic'
        page.title = 'No Results'
        page.add_css_class('compact')
      end
    end

    private

      def connect_room
        @room_signals = [
          @room.connect('notify::channel') { on_channel_changed },
          @room.connect('member-joined') { |_r, member| add_member(member) },
          @room.connect('member-left') { |_r, member| remove_member(member) },
          @room.connect('member-disconnected') { |_r, member| remove_member(member) },
          @room.connect('member-kicked') { |_r, member| remove_member(member) },
          @room.connect('member-banned') { |_r, member| remove_member(member) },
          @room.connect('member-renamed') do |_r, old_member, new_member|
            remove_member(old_member)
            add_member(new_member)
          end,
        ]
      end

      def on_channel_changed
        list.children.each { |row| list.remove(row) }
        @rows.clear

        @room.members.each { |member| add_member(member) }
        sync_visible_page
      end

      def add_member(member)
        @rows[member] = UserListRow.new(member).build
        list.append(@rows[member])
        sync_visible_page
      end

      def remove_member(member)
        @rows[member].then do |row|
          if row
            list.remove(row)
            @rows.delete(member)
          end
        end
        sync_visible_page
      end

      def on_row_activated(row)
        if @active_row && @active_row != row
          @active_row.expand = false
        end
        @active_row = row
        @active_row.expand = !@active_row.expand
      end

      def filter_row(row)
        row.filter = @filter
        row.should_show?
      end

      def sync_visible_page
        has_visible_rows = list.children.any?(&:child_visible?)
        stack.visible_child_name = has_visible_rows ? 'list' : 'placeholder'
      end
  end

  # UserListPopover is the popover the header bar's people button opens: a
  # search entry that appears once there are enough users, and the user list
  # of the active room, sized to the chat view.
  #
  # Ported from the UserListPopover class in src/userList.js.
  class UserListPopover < Gtk::Popover
    FILTER_ENTRY_THRESHOLD = 8

    def initialize(window)
      super()
      @window = window
      @user_list = nil

      self.position = :bottom
      set_size_request(250, -1)
      add_css_class('polari-user-list')
    end

    def build
      tap do |popover|
        popover.child = box

        box.tap do |vbox|
          vbox.append(revealer)
          revealer.child = entry
        end

        entry.signal_connect('search-changed') { update_filter }
        entry.signal_connect('stop-search') { on_stop_search }

        popover.signal_connect('closed') { entry.text = '' }
        popover.signal_connect('map') do
          revealer.transition_duration = 0
          ensure_user_list
          update_content_height
        end
        revealer.signal_connect('notify::child-revealed') do
          revealer.transition_duration = 250
        end
      end
    end

    # Called by the window when the active room or the view height changes.
    def active_room_changed
      entry.text = ''

      if @user_list
        box.remove(@user_list)
      end
      @user_list = nil
    end

    def update_content_height
      if @user_list && mapped?
        popover_height, = measure(:vertical, -1)
        user_list_height, = @user_list.measure(:vertical, -1)
        chrome_height = popover_height - user_list_height
        @user_list.max_content_height = @window.view_height - chrome_height
      end
    end

    def box = @box ||= Gtk::Box.new(:vertical, 6)
    def revealer = @revealer ||= Gtk::Revealer.new
    def entry = @entry ||= Gtk::SearchEntry.new

    private

      def ensure_user_list
        room = @window.active_room

        if @user_list.nil? && room && room.room?
          @user_list = UserList.new(room).build
          box.append(@user_list)

          @user_list.vadjustment.signal_connect('changed') { update_entry_visibility }
          update_entry_visibility
        end
      end

      def update_entry_visibility
        if @user_list
          revealer.reveal_child =
            !entry.text.empty? || @user_list.num_rows > FILTER_ENTRY_THRESHOLD
        end
      end

      def update_filter
        if @user_list
          @user_list.set_filter(entry.text)
        end
      end

      def on_stop_search
        if entry.text.length.positive?
          entry.text = ''
        else
          popdown
        end
      end
  end
end
