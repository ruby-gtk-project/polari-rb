# frozen_string_literal: true

require 'adwaita'
require_relative 'signals'
require_relative 'accounts_monitor'
require_relative 'room_manager'
require_relative 'utils'

module Polari
  # ServerRoomManager keeps one room list per connected account: the channels
  # the server reported, and whether the listing is still running.
  #
  # Ported from the ServerRoomManager class in src/serverRoomManager.js.
  # Upstream builds a Tp.RoomList for every account that reaches CONNECTED
  # and collects its ::got-room infos. The listing has to come from the IRC
  # transport (src/telepathyClient.js, not ported yet); this manager asks the
  # account's connection for it, keeps the collected infos, and reports
  # loading the way upstream does — so an account with no connection has no
  # rooms to offer, which is exactly what upstream reports before a listing
  # arrives.
  #
  # A room info is an object answering to #name and #members_count.
  class ServerRoomManager
    include Signals

    def self.default = @default ||= new

    def self.reset = @default = nil

    def initialize(accounts_monitor: AccountsMonitor.default)
      @room_lists = {}
      @accounts_monitor = accounts_monitor

      @accounts_monitor.connect('account-status-changed') do |_m, account|
        on_account_status_changed(account)
      end
      @accounts_monitor.connect('account-removed') { |_m, account| on_account_removed(account) }
      @accounts_monitor.prepare do
        @accounts_monitor.visible_accounts.each { |account| on_account_status_changed(account) }
      end
    end

    def room_infos(account)
      @room_lists[account].then do |entry|
        if entry.nil? || entry[:listing]
          []
        else
          entry[:rooms].dup
        end
      end
    end

    def loading?(account)
      @room_lists[account].then do |entry|
        if entry.nil?
          account && account.connection_status == Account::STATUS_CONNECTING
        else
          entry[:listing]
        end
      end
    end

    private

      def on_account_status_changed(account)
        if account.connection_status == Account::STATUS_CONNECTING
          emit('loading-changed', account)
        end

        if account.connection_status == Account::STATUS_CONNECTED
          start_listing(account)
        end
      end

      def start_listing(account)
        if !@room_lists.key?(account) && account.connection.respond_to?(:list_rooms)
          @room_lists[account] = { rooms: [], listing: true }

          account.connection.list_rooms do |room_info|
            on_got_room(account, room_info)
          end
          finish_listing(account)
        end
      end

      def on_got_room(account, room_info)
        @room_lists[account].then do |entry|
          if entry
            entry[:rooms].push(room_info)
          end
        end
      end

      def finish_listing(account)
        @room_lists[account][:listing] = false
        emit('loading-changed', account)
      end

      def on_account_removed(account)
        @room_lists.delete(account)
      end
  end

  # ServerRoomList is the room picker of the join dialog: a filter entry
  # doubling as "enter room name to add", a spinner while the server list is
  # coming in, and a tree view of rooms with a checkbox and a user count.
  #
  # Ported from the ServerRoomList class in src/serverRoomManager.js plus
  # data/ui/server-room-list.ui, including the custom-room row that carries
  # whatever the user typed (and empties itself when an exact match shows up
  # in the list), the already-joined rooms shown checked and insensitive, and
  # filling the list in idle batches so the dialog stays responsive.
  class ServerRoomList < Gtk::Box
    COLUMN_CHECKED = 0
    COLUMN_NAME = 1
    COLUMN_COUNT = 2
    COLUMN_SENSITIVE = 3

    # Max time spent in idle, and the shorter budget while filtering.
    MS_PER_IDLE = 10
    MS_PER_FILTER_IDLE = 5

    def initialize(
      manager: ServerRoomManager.default,
      room_manager: RoomManager.default,
      on_can_join_changed: nil,
      on_stop_search: nil
    )
      super(:vertical, 0)
      @manager = manager
      @room_manager = room_manager
      @on_can_join_changed = on_can_join_changed
      @on_stop_search = on_stop_search
      @account = nil
      @pending_infos = []
      @filter_terms = []
      @idle_id = nil

      add_css_class('linked')
      add_css_class('frame')
    end

    def build
      tap do |widget|
        widget.append(filter_bar)
        widget.append(scroller)

        filter_bar.tap do |bar|
          bar.append(filter_entry)
          bar.append(spinner_bin)
        end

        scroller.child = list

        store.tap do |model|
          @custom_room_item = model.append
          model.set_value(@custom_room_item, COLUMN_COUNT, '+')
          model.set_value(@custom_room_item, COLUMN_SENSITIVE, true)
          model.set_value(@custom_room_item, COLUMN_NAME, '')
        end

        model_filter.set_visible_func { |model, iter| visible_row?(model, iter) }
        list.model = model_filter
        list.append_column(room_column)
        model_filter.refilter

        connect_signals
        check_spinner
      end
    end

    def can_join?
      each_room_iter.any? do |iter|
        store.get_value(iter, COLUMN_SENSITIVE) && store.get_value(iter, COLUMN_CHECKED)
      end
    end

    def selected_rooms
      each_room_iter.filter_map do |iter|
        if store.get_value(iter, COLUMN_SENSITIVE) && store.get_value(iter, COLUMN_CHECKED)
          store.get_value(iter, COLUMN_NAME)
        end
      end
    end

    def account=(account)
      unless account == @account
        @account = account
        @pending_infos = []
        clear_list
        filter_entry.text = ''
        on_loading_changed(account)
      end
    end

    def focus_entry
      filter_entry.grab_focus
    end

    def store
      @store ||= Gtk::ListStore.new(TrueClass, String, String, TrueClass)
    end

    def model_filter = @model_filter ||= Gtk::TreeModelFilter.new(store)

    def filter_bar
      @filter_bar ||= Gtk::Box.new(:horizontal, 0).tap do |bar|
        bar.add_css_class('polari-listbox-filterbar')
      end
    end

    def filter_entry
      @filter_entry ||= Gtk::SearchEntry.new.tap do |entry|
        entry.hexpand = true
        entry.margin_start = 60
        entry.margin_top = 6
        entry.margin_bottom = 6
        entry.activates_default = true
        entry.placeholder_text = 'Enter room name to add'
      end
    end

    def spinner_bin
      @spinner_bin ||= Adwaita::Bin.new.tap do |bin|
        bin.width_request = 60
        bin.child = spinner
      end
    end

    def spinner
      @spinner ||= Adwaita::Spinner.new.tap do |widget|
        widget.halign = :center
        widget.valign = :center
      end
    end

    def scroller
      @scroller ||= Gtk::ScrolledWindow.new.tap do |widget|
        widget.vexpand = true
        widget.hscrollbar_policy = :never
      end
    end

    def list
      @list ||= Gtk::TreeView.new.tap do |view|
        view.activate_on_single_click = true
        view.headers_visible = false
        view.enable_grid_lines = :horizontal
        view.add_css_class('polari-server-room-list')
      end
    end

    def toggle_renderer = @toggle_renderer ||= Gtk::CellRendererToggle.new

    def room_column
      @room_column ||= Gtk::TreeViewColumn.new.tap do |column|
        column.sizing = :fixed

        column.pack_start(toggle_renderer, false)
        column.add_attribute(toggle_renderer, 'active', COLUMN_CHECKED)
        column.add_attribute(toggle_renderer, 'sensitive', COLUMN_SENSITIVE)

        column.pack_start(name_renderer, true)
        column.add_attribute(name_renderer, 'text', COLUMN_NAME)
        column.add_attribute(name_renderer, 'sensitive', COLUMN_SENSITIVE)

        column.pack_start(count_renderer, false)
        column.add_attribute(count_renderer, 'text', COLUMN_COUNT)
        column.add_attribute(count_renderer, 'sensitive', COLUMN_SENSITIVE)
      end
    end

    def name_renderer
      @name_renderer ||= Gtk::CellRendererText.new.tap do |renderer|
        renderer.ellipsize = :end
      end
    end

    # Fixed-height mode means renderers do not grow with their content, and
    # the biggest rooms have a few thousand users, so five digits it is.
    def count_renderer
      @count_renderer ||= Gtk::CellRendererText.new.tap do |renderer|
        renderer.xalign = 1.0
        renderer.width_chars = 5
      end
    end

    private

      def connect_signals
        filter_entry.signal_connect('changed') do
          update_custom_room_name
          update_selection
        end
        filter_entry.signal_connect('search-changed') { on_search_changed }
        filter_entry.signal_connect('stop-search') { on_stop_search }
        filter_entry.signal_connect('activate') { on_entry_activated }

        list.signal_connect('row-activated') { |_v, path, _column| toggle_checked(path) }
        toggle_renderer.signal_connect('toggled') { |_cell, path| toggle_checked(path) }

        @manager.connect('loading-changed') { |_m, account| on_loading_changed(account) }
      end

      def on_search_changed
        if Utils.update_terms(@filter_terms, filter_entry.text)
          model_filter.refilter
          update_selection
        end
      end

      def on_stop_search
        if filter_entry.text.length.positive?
          filter_entry.text = ''
        else
          @on_stop_search&.call
        end
      end

      def on_entry_activated
        unless filter_entry.text.strip.empty?
          list.selection.selected.then do |iter|
            if iter
              toggle_checked(model_filter.get_path(iter))
            end
          end
        end
      end

      def each_room_iter
        [].tap do |iters|
          iter = store.iter_first
          while iter
            iters << iter.dup
            iter = store.iter_next(iter) ? iter : nil
          end
        end
      end

      def custom_room_item?(iter)
        store.get_path(iter).to_s == store.get_path(@custom_room_item).to_s
      end

      def visible_row?(model, iter)
        name = model.get_value(iter, COLUMN_NAME).to_s

        if name.empty?
          false
        elsif custom_room_item?(iter)
          true
        else
          @filter_terms.all? { |term| name.include?(term) }
        end
      end

      # What the user typed becomes the custom room row, unless it has
      # whitespace or the list already holds that exact room.
      def update_custom_room_name
        typed = filter_entry.text.strip
        name = typed.match?(/\s/) ? '' : typed

        if !name.empty? && exact_match?(name)
          name = ''
        end

        store.set_value(@custom_room_item, COLUMN_NAME, name)
      end

      def exact_match?(name)
        each_room_iter.any? do |iter|
          !custom_room_item?(iter) &&
            base_equal?(name, store.get_value(iter, COLUMN_NAME).to_s)
        end
      end

      def base_equal?(name1, name2) = name1.to_s.downcase == name2.to_s.downcase

      def update_selection
        unless filter_entry.text.strip.empty?
          model_filter.iter_first.then do |iter|
            if iter
              list.selection.select_iter(iter)
              list.scroll_to_cell(model_filter.get_path(iter), nil, true, 0.0, 0.0)
            end
          end
        end
      end

      # Everything above the custom room row is the server's list, and goes
      # away when the account changes or a new listing starts.
      def clear_list
        iter = store.iter_first

        if iter && !custom_room_item?(iter)
          store.move_before(@custom_room_item, iter)
          while store.remove(iter)
            nil
          end
        end
      end

      def on_loading_changed(account)
        if account == @account
          check_spinner
          clear_list
          clear_idle

          if account
            start_filling(account)
          end
        end
      end

      def start_filling(account)
        @pending_infos = sorted_room_infos(account)
        check_spinner

        @idle_id = GLib::Idle.add do
          if fill_batch
            true
          else
            @idle_id = nil
            check_spinner
            false
          end
        end
      end

      # Rooms come in by popularity, then by name.
      def sorted_room_infos(account)
        @manager.room_infos(account).sort do |info1, info2|
          if info1.members_count == info2.members_count
            info1.name <=> info2.name
          else
            info2.members_count <=> info1.members_count
          end
        end
      end

      def fill_batch
        start_time = monotonic_microseconds
        max_time = @filter_terms.empty? ? MS_PER_IDLE : MS_PER_FILTER_IDLE

        while @pending_infos.any?
          add_room_info(@pending_infos.shift)

          if monotonic_microseconds - start_time > 1000 * max_time
            break
          end
        end

        @pending_infos.any?
      end

      def add_room_info(room_info)
        name = room_info.name.to_s.delete_prefix('#')
        custom_name = store.get_value(@custom_room_item, COLUMN_NAME).to_s

        if base_equal?(name, custom_name)
          store.set_value(@custom_room_item, COLUMN_NAME, '')
        end

        joined = @room_manager.lookup_room_by_name(room_info.name, @account)

        store.insert_before(@custom_room_item).tap do |iter|
          store.set_value(iter, COLUMN_CHECKED, !joined.nil?)
          store.set_value(iter, COLUMN_NAME, name)
          store.set_value(iter, COLUMN_COUNT, room_info.members_count.to_s)
          store.set_value(iter, COLUMN_SENSITIVE, joined.nil?)
        end
      end

      def check_spinner
        spinner.visible = @pending_infos.any? || (!@account.nil? && @manager.loading?(@account))
      end

      def toggle_checked(path)
        child_path = model_filter.convert_path_to_child_path(path)

        store.get_iter(child_path).then do |iter|
          if iter && store.get_value(iter, COLUMN_SENSITIVE)
            checked = store.get_value(iter, COLUMN_CHECKED)
            store.set_value(iter, COLUMN_CHECKED, !checked)
            @on_can_join_changed&.call
          end
        end
      end

      def clear_idle
        if @idle_id
          GLib::Source.remove(@idle_id)
        end
        @idle_id = nil
      end

      def monotonic_microseconds
        (Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1_000_000).to_i
      end
  end
end
