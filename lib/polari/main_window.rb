# frozen_string_literal: true

require 'adwaita'
require_relative 'accounts_monitor'
require_relative 'room_manager'
require_relative 'room_list'
require_relative 'room_stack'
require_relative 'search_view'
require_relative 'user_list'
require_relative 'join_dialog'
require_relative 'settings'
require_relative 'utils'

module Polari
  # MainWindow is the application window: the room sidebar with its search
  # bar on the left, the conversation (or the search results) on the right,
  # the offline and log-import banners over the chat pane, and the user list
  # behind the people button.
  #
  # Ported from src/mainWindow.js plus data/ui/main-window.ui: the
  # AdwNavigationSplitView with its collapse breakpoint, the three header bars
  # (sidebar, conversation, search), the title widget that shows the room
  # topic as a subtitle with its links turned into markup, the user-count
  # button, the two banners and the import progress bar, remembering the last
  # selected channel across runs, and restoring it on start.
  #
  # Upstream declares ::active-room, ::subtitle and ::view-height as GObject
  # properties and ::active-room-state-changed as a signal, and the template
  # binds labels to them; a Ruby class cannot add either, so the window calls
  # the widgets that care (the sidebar, the chat stack, the user list popover)
  # when the active room changes.
  class MainWindow < Adwaita::ApplicationWindow
    COLLAPSE_CONDITION = 'max-width: 400sp'

    def initialize(app, settings: Settings.default)
      super(app)
      @app = app
      @settings = settings
      @room = nil
      @last_active_room = nil
      @subtitle = ''
      @room_signals = []
      @join_dialog = nil

      @accounts_monitor = AccountsMonitor.default
      @room_manager = RoomManager.default

      self.title = 'Polari'
      self.icon_name = 'org.gnome.Polari'
      set_size_request(360, 360)
      @settings.apply_to(self)
    end

    # Not attr_reader: the ivar behind the active room is @room (set by
    # #active_room=, read everywhere else in this class), so a plain
    # attr_reader here would read the always-nil @active_room instead.
    def active_room = @room

    attr_reader :join_dialog

    def build
      tap do |window|
        window.content = overlay
        overlay.child = split_view

        split_view.tap do |view|
          view.sidebar = sidebar_page
          view.content = content_page
          view.min_sidebar_width = 200
        end

        build_sidebar
        build_content
        add_breakpoint(collapse_breakpoint)

        user_list_popover.build
        user_list_popover.set_parent(show_user_list_button)

        connect_signals
        room_stack.build
        room_list.build

        on_accounts_changed
        on_accounts_reachable_changed
        on_rooms_loaded
        update_user_list_label
      end
    end

    # Upstream's active-room property: switching rooms retitles the window,
    # moves the chat stack and the sidebar selection, and resets the user
    # list.
    def active_room=(room)
      unless room == @room
        disconnect_room
        if room&.room?
          @last_active_room = room
        end
        @room = room
        connect_room

        update_titlebar
        room_stack.active_room = room
        room_list.active_room = room
        user_list_popover.active_room_changed
        if searching?
          search_view.scroll_to(room)
        end
        update_user_list_label
      end
    end

    def add_toast(toast)
      overlay.add_toast(toast)
    end

    def view_height = room_stack.view_height

    def show_join_room_dialog
      @join_dialog = JoinDialog.new(window: self).build
      @join_dialog.signal_connect('closed') { @join_dialog = nil }
      @join_dialog.present(self)
    end

    def close_join_dialog
      @join_dialog&.close
    end

    # Called while the old telepathy-logger logs are converted.
    def show_import_progress(current, max)
      if max.zero?
        import_progress.fraction = 0.0
      else
        import_progress.fraction = current.to_f / max
      end
      import_progress.visible = current != max
    end

    # Jumps from a search result into the conversation at that point.
    def show_search_inline(room, date)
      search_button.active = false
      self.active_room = room
      view_stack.visible_child_name = 'conversation'
      room_stack.view_for_room(room)&.show_search_inline(date)
    end

    # Stores the channel to come back to, the way upstream's ::destroy
    # handler does.
    def remember_session
      if @last_active_room
        @settings['last-selected-channel'] = {
          'account' => @last_active_room.account.object_path,
          'channel' => @last_active_room.channel_name,
        }
      else
        @settings.reset('last-selected-channel')
      end
      @settings.remember(self)
    end

    def overlay = @overlay ||= Adwaita::ToastOverlay.new

    def split_view = @split_view ||= Adwaita::NavigationSplitView.new

    def collapse_breakpoint
      @collapse_breakpoint ||= Adwaita::Breakpoint.new(
        Adwaita::BreakpointCondition.parse(COLLAPSE_CONDITION),
      ).tap do |breakpoint|
        breakpoint.add_setter(split_view, 'collapsed', true)
      end
    end

    def sidebar_page
      @sidebar_page ||= Adwaita::NavigationPage.new(sidebar_toolbar, 'Polari').tap do |page|
        page.tag = 'sidebar'
      end
    end

    def content_page
      @content_page ||= Adwaita::NavigationPage.new(view_stack, 'Polari').tap do |page|
        page.tag = 'content'
        page.add_css_class('view')
      end
    end

    def sidebar_toolbar = @sidebar_toolbar ||= Adwaita::ToolbarView.new
    def sidebar_header = @sidebar_header ||= Adwaita::HeaderBar.new

    def join_button
      @join_button ||= Gtk::Button.new.tap do |button|
        button.halign = :end
        button.valign = :center
        button.action_name = 'app.show-join-dialog'
        button.icon_name = 'list-add-symbolic'
        button.tooltip_text = 'Add Rooms and Networks'
        button.add_css_class('image-button')
      end
    end

    def menu_button
      @menu_button ||= Gtk::MenuButton.new.tap do |button|
        button.halign = :end
        button.valign = :center
        button.menu_model = hamburger_menu
        button.icon_name = 'open-menu-symbolic'
        button.primary = true
        button.tooltip_text = 'Main Menu'
      end
    end

    def hamburger_menu
      @hamburger_menu ||= Gio::Menu.new.tap do |menu|
        menu.append_section(nil, Gio::Menu.new.tap do |section|
          section.append('Run in Background', 'app.run-in-background')
        end)
        menu.append_section(nil, Gio::Menu.new.tap do |section|
          section.append('Keyboard Shortcuts', 'app.shortcuts-dialog')
          section.append('Help', 'app.help')
          section.append('About', 'app.about')
          section.append('Quit', 'app.quit')
        end)
      end
    end

    def search_button
      @search_button ||= Gtk::ToggleButton.new.tap do |button|
        button.tooltip_text = 'Search'
        button.icon_name = 'edit-find-symbolic'
      end
    end

    def search_bar = @search_bar ||= Gtk::SearchBar.new

    def search_entry
      @search_entry ||= Gtk::SearchEntry.new.tap do |entry|
        entry.hexpand = true
        entry.placeholder_text = 'Search Conversations…'
      end
    end

    def room_list_revealer
      @room_list_revealer ||= Gtk::Revealer.new.tap do |revealer|
        revealer.hexpand = false
        revealer.vexpand = true
        revealer.transition_type = :slide_right
      end
    end

    def room_list_scroller
      @room_list_scroller ||= Gtk::ScrolledWindow.new.tap do |scroller|
        scroller.hscrollbar_policy = :never
        scroller.vexpand = true
        scroller.hexpand = true
      end
    end

    def room_list
      @room_list ||= RoomList.new(
        on_room_selected:  method(:on_room_selected),
        on_filter_changed: method(:on_filter_changed),
      )
    end

    def view_stack
      @view_stack ||= Gtk::Stack.new.tap do |stack|
        stack.hhomogeneous = true
        stack.vhomogeneous = true
        stack.transition_type = :crossfade
      end
    end

    def conversation_toolbar = @conversation_toolbar ||= Adwaita::ToolbarView.new
    def conversation_header = @conversation_header ||= Adwaita::HeaderBar.new

    # A box in a stack, as upstream does it: only the first child is ever
    # shown, but the second one still counts towards the size request, so the
    # header does not jump when a room has no topic.
    def title_stack
      @title_stack ||= Gtk::Stack.new.tap do |stack|
        stack.margin_start = 24
        stack.margin_end = 24
      end
    end

    def title_box
      @title_box ||= Gtk::Box.new(:vertical, 0).tap do |box|
        box.valign = :center
      end
    end

    def title_label
      @title_label ||= Gtk::Label.new.tap do |label|
        label.single_line_mode = true
        label.ellipsize = :end
        label.add_css_class('title')
      end
    end

    def subtitle_label
      @subtitle_label ||= Gtk::Label.new.tap do |label|
        label.single_line_mode = true
        label.ellipsize = :end
        label.use_markup = true
        label.visible = false
        label.add_css_class('subtitle')
        label.add_css_class('dim-label')
      end
    end

    def size_reserve_box
      @size_reserve_box ||= Gtk::Box.new(:vertical, 0).tap do |box|
        box.append(Gtk::Label.new.tap do |label|
          label.single_line_mode = true
          label.add_css_class('title')
        end)
        box.append(Gtk::Label.new.tap do |label|
          label.single_line_mode = true
          label.add_css_class('subtitle')
          label.add_css_class('dim-label')
        end)
      end
    end

    def show_user_list_button
      @show_user_list_button ||= Gtk::ToggleButton.new.tap do |button|
        button.focus_on_click = false
        button.action_name = 'app.user-list'
        button.tooltip_text = 'Show Connected Users'
        button.child = user_list_button_content
      end
    end

    def user_list_button_content
      @user_list_button_content ||= Adwaita::ButtonContent.new.tap do |content|
        content.icon_name = 'people-symbolic'
      end
    end

    def user_list_popover
      @user_list_popover ||= UserListPopover.new(self)
    end

    def chat_overlay = @chat_overlay ||= Gtk::Overlay.new

    def offline_banner
      @offline_banner ||= Adwaita::Banner.new('Go online to chat and receive messages.').tap do |banner|
        banner.valign = :start
      end
    end

    def import_banner
      @import_banner ||= Adwaita::Banner.new(
        'Importing old conversations — Will be back after conversion',
      ).tap do |banner|
        banner.valign = :start
      end
    end

    def import_progress
      @import_progress ||= Gtk::ProgressBar.new.tap do |bar|
        bar.valign = :start
        bar.visible = false
        bar.add_css_class('osd')
      end
    end

    def room_stack = @room_stack ||= RoomStack.new

    def search_toolbar = @search_toolbar ||= Adwaita::ToolbarView.new
    def search_header = @search_header ||= Adwaita::HeaderBar.new

    def search_title
      @search_title ||= Gtk::Label.new.tap do |label|
        label.single_line_mode = true
        label.ellipsize = :end
        label.add_css_class('title')
      end
    end

    def search_view
      @search_view ||= SearchView.new(on_result_activated: method(:show_search_inline))
    end

    private

      def build_sidebar
        sidebar_toolbar.tap do |view|
          view.add_top_bar(sidebar_header)
          view.add_top_bar(search_bar)
          view.content = room_list_revealer
        end

        sidebar_header.tap do |bar|
          bar.show_title = false
          bar.pack_start(join_button)
          bar.pack_end(menu_button)
          bar.pack_end(search_button)
        end

        search_bar.child = search_entry
        search_button.bind_property(
          'active',
          search_bar,
          'search-mode-enabled',
          [:sync_create, :bidirectional],
        )

        room_list_revealer.child = room_list_scroller
        room_list_scroller.child = room_list
      end

      def build_content
        view_stack.tap do |stack|
          stack.add_named(conversation_toolbar, 'conversation')
          stack.add_named(search_toolbar, 'search')
        end

        conversation_toolbar.tap do |view|
          view.add_top_bar(conversation_header)
          view.content = chat_overlay
        end

        conversation_header.tap do |bar|
          bar.title_widget = title_stack
          bar.pack_end(show_user_list_button)
        end

        title_stack.tap do |stack|
          stack.add_child(title_box)
          stack.add_child(size_reserve_box)
        end

        title_box.tap do |box|
          box.append(title_label)
          box.append(subtitle_label)
        end

        chat_overlay.tap do |widget|
          widget.child = room_stack
          widget.add_overlay(offline_banner)
          widget.add_overlay(import_banner)
          widget.add_overlay(import_progress)
        end

        search_toolbar.tap do |view|
          view.add_top_bar(search_header)
          view.content = search_view.build
        end

        search_header.title_widget = search_title
      end

      def connect_signals
        search_entry.signal_connect('search-changed') { on_search_changed }

        @accounts_monitor.connect('accounts-changed') { on_accounts_changed }
        @accounts_monitor.connect('account-reachable-changed') { on_accounts_reachable_changed }

        @room_manager.connect('rooms-loaded') { on_rooms_loaded }
        @room_manager.connect('room-removed') { |_m, room| on_room_removed(room) }
        @room_manager.connect('room-presented') { |_m, room| self.active_room = room }

        @app.lookup_action('search').then do |action|
          if action
            action.signal_connect('activate') { search_button.activate }
          end
        end

        @app.signal_connect('action-state-changed::user-list') do |_app, _name, value|
          if value
            user_list_popover.popup
          else
            user_list_popover.popdown
          end
        end

        user_list_popover.signal_connect('notify::visible') do
          unless user_list_popover.visible?
            @app.lookup_action('user-list').change_state(GLib::Variant.new(false))
          end
        end

        import_progress.signal_connect('notify::visible') do
          import_banner.revealed = import_progress.visible?
        end

        signal_connect('close-request') do
          remember_session
          false
        end
      end

      def searching? = view_stack.visible_child_name == 'search'

      def on_search_changed
        terms = search_entry.text

        if terms.empty?
          view_stack.visible_child_name = 'conversation'
          room_list.search_mode = false
          search_view.cancel
        else
          search_title.label = format('Search for “%s”', terms)
          room_list.search(terms)
          search_view.search = terms
          view_stack.visible_child_name = 'search'
        end
      end

      def on_filter_changed
        search_view.rooms = room_list.search_rooms
      end

      def on_room_selected(room)
        self.active_room = room
      end

      def on_accounts_changed
        room_list_revealer.reveal_child = @accounts_monitor.visible_accounts.any?
      end

      # The banner goes up when there are accounts but none of them can be
      # reached.
      def on_accounts_reachable_changed
        accounts = @accounts_monitor.visible_accounts
        offline_banner.revealed = accounts.any? && accounts.none?(&:reachable?)
      end

      def on_rooms_loaded
        if @room.nil?
          self.active_room = last_selected_room || @room_manager.rooms.first
        end
      end

      def last_selected_room
        selected = @settings['last-selected-channel']
        account = @accounts_monitor.lookup_account(selected['account'])

        if account && account.visible? && selected['channel']
          @room_manager.lookup_room(
            Room.create_room_id(account, selected['channel'], :room),
          )
        end
      end

      def on_room_removed(room)
        if room == @last_active_room
          @last_active_room = nil
        end
      end

      def connect_room
        if @room
          @room_signals = [
            @room.connect('notify::display-name') { update_titlebar },
            @room.connect('notify::topic') { update_titlebar },
            @room.connect('members-changed') { update_user_list_label },
            @room.connect('notify::channel') { on_channel_changed },
          ]
        end
      end

      def disconnect_room
        if @room
          @room_signals.each { |id| @room.disconnect(id) }
        end
        @room_signals = []
      end

      def on_channel_changed
        update_user_list_label
        room_stack.update_sensitivity
      end

      def update_user_list_label
        members = 0
        if @room && @room.channel
          members = @room.members.length
        end

        user_list_button_content.label = members.to_s

        # A ruby-gnome binding gap, not a port bug: see FINDINGS.md
        # ("Gtk::Accessible#update_property cannot take an enum-typed C
        # array") for the exact error and why this rescue is the fix.
        begin
          show_user_list_button.update_property(
            [Gtk::AccessibleProperty::LABEL],
            [members == 1 ? '1 user' : "#{members} users"],
          )
        rescue NotImplementedError
          nil
        end
      end

      # The window title is the room name; the subtitle is its topic, with
      # every URL in it turned into a link.
      def update_titlebar
        if @room
          self.title = @room.display_name.to_s
        else
          self.title = 'Polari'
        end
        title_label.label = title.to_s

        subtitle = ''
        if @room
          subtitle = markup_for_topic(@room.topic.to_s)
        end

        unless subtitle == @subtitle
          @subtitle = subtitle
          subtitle_label.label = subtitle
          subtitle_label.visible = !subtitle.empty?
          subtitle_label.has_tooltip = !subtitle.empty?
          subtitle_label.tooltip_markup = subtitle
        end
      end

      def markup_for_topic(topic)
        position = 0

        Utils.find_urls(topic).each_with_object(+'') do |url, markup|
          text = Utils.markup_escape_text(topic[position, url.pos - position].to_s)
          escaped = Utils.markup_escape_text(url.url)
          markup << "#{text} <a href=\"#{escaped}\">#{escaped}</a>"
          position = url.pos + url.url.length
        end.then do |markup|
          markup + Utils.markup_escape_text(topic[position..].to_s)
        end
      end
  end
end
