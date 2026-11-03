# frozen_string_literal: true

require 'adwaita'
require_relative 'logger'
require_relative 'utils'

module Polari
  # SearchRow is one search hit: the date, the matching message, and the two
  # messages that followed it.
  #
  # Ported from the SearchRow class in src/searchView.js plus
  # data/ui/search-row.ui.
  class SearchRow < Gtk::ListBoxRow
    def initialize(context)
      super()
      @context = context
      @start_time = context.first[:time]
      @end_time = context.last[:time]
    end

    attr_reader :start_time, :end_time

    def build
      tap do |row|
        row.child = box

        box.tap do |vbox|
          vbox.append(date_label)
          vbox.append(messages_grid)
        end

        @context.each_with_index do |message, index|
          messages_grid.attach(nick_label(message), 0, index, 1, 1)
          messages_grid.attach(text_label(message), 1, index, 3, 1)
        end

        date_label.label = Utils.format_date_time(@start_time)
      end
    end

    def box
      @box ||= Gtk::Box.new(:vertical, 6).tap do |vbox|
        vbox.margin_top = 6
        vbox.margin_bottom = 6
        vbox.margin_start = 6
        vbox.margin_end = 6
      end
    end

    def date_label
      @date_label ||= Gtk::Label.new.tap do |label|
        label.halign = :end
        label.add_css_class('dim-label')
        label.add_css_class('caption')
      end
    end

    def messages_grid
      @messages_grid ||= Gtk::Grid.new.tap do |grid|
        grid.column_homogeneous = true
        grid.column_spacing = 12
        grid.row_spacing = 6
      end
    end

    private

      def nick_label(message)
        Gtk::Label.new(message[:sender_nick].to_s).tap do |label|
          label.halign = :start
          label.valign = :start
          label.xalign = 0
          label.yalign = 0
          label.add_css_class('caption-heading')
        end
      end

      def text_label(message)
        Gtk::Label.new(message[:text].to_s).tap do |label|
          label.halign = :start
          label.valign = :start
          label.xalign = 0
          label.yalign = 0
          label.wrap = true
          label.add_css_class('caption')
        end
      end
  end

  # SearchSection is one room's results: its name, three hits at a time, and
  # a row at the bottom that fetches three more.
  #
  # Ported from the SearchSection class in src/searchView.js plus
  # data/ui/search-section.ui. Activating a hit asks the window to show the
  # conversation at that point, one second past the end of the context — the
  # same hand-off upstream makes.
  class SearchSection < Gtk::Box
    PAGE_SIZE = 3

    def initialize(room, search_terms, on_result_activated: nil, store: ChatLogStore.default)
      super(:vertical, 12)
      @room = room
      @search_terms = search_terms
      @on_result_activated = on_result_activated
      @log_finder = LogFinder.new(nil, store: store)
      @offset = 0
      @rows = []

      self.margin_top = 24
      self.margin_bottom = 24
      self.margin_start = 24
      self.margin_end = 24
    end

    attr_reader :room

    def build
      tap do |section|
        section.append(title_label)
        section.append(list)

        title_label.label = @room.display_name.to_s
        list.signal_connect('row-activated') { |_l, row| on_row_activated(row) }

        self.search = @search_terms
      end
    end

    def search = @search_terms

    def search=(terms)
      @search_terms = terms
      @offset = 0

      @rows.each { |row| list.remove(row) }
      @rows = []
      list.remove(load_more_row)
      list.append(load_more_row)

      fetch_results
    end

    def title_label
      @title_label ||= Gtk::Label.new.tap do |label|
        label.halign = :start
        label.add_css_class('heading')
      end
    end

    def list
      @list ||= Gtk::ListBox.new.tap do |box|
        box.selection_mode = :none
        box.add_css_class('boxed-list')
      end
    end

    def load_more_row
      @load_more_row ||= Gtk::ListBoxRow.new.tap do |row|
        row.activatable = true
        row.child = Gtk::Image.new.tap do |image|
          image.icon_name = 'list-add'
          image.margin_top = 6
          image.margin_bottom = 6
        end
      end
    end

    private

      def fetch_results
        results = @log_finder.fetch_results(@room, @search_terms, PAGE_SIZE, @offset)

        if results.length != PAGE_SIZE
          load_more_row.visible = false
        end

        results.each do |context|
          SearchRow.new(context).build.tap do |row|
            list.insert(row, @offset)
            @rows.push(row)
            @offset += 1
          end
        end
      end

      def on_row_activated(row)
        if row == load_more_row
          fetch_results
        else
          @on_result_activated&.call(@room, row.end_time + 1)
        end
      end
  end

  # SearchView is the search page of the window: one section per room the
  # sidebar's filter kept, scrolled to the section of the active room.
  #
  # Ported from the SearchView class in src/searchView.js. Upstream binds its
  # ::search property into each section and follows the toplevel's
  # ::notify::active-room from vfunc_realize; here the window sets #search and
  # #rooms and calls #scroll_to, and the sections are updated directly.
  class SearchView < Gtk::ScrolledWindow
    def initialize(on_result_activated: nil)
      super()
      @on_result_activated = on_result_activated
      @sections = {}
      @search_terms = ''

      self.hscrollbar_policy = :never
      self.vexpand = true
    end

    def build
      tap do |view|
        view.child = box
      end
    end

    def search = @search_terms

    def search=(terms)
      @search_terms = terms
      @sections.each_value { |section| section.search = terms }
    end

    # The rooms with matches, as the sidebar reports them: sections for rooms
    # that are gone are dropped, and new ones are added.
    def rooms=(rooms)
      @sections.keys.each do |room_id|
        unless rooms.any? { |room| room.id == room_id }
          box.remove(@sections.delete(room_id))
        end
      end

      rooms.each do |room|
        unless @sections.key?(room.id)
          @sections[room.id] = build_section(room)
          box.append(@sections[room.id])
        end
      end
    end

    def scroll_to(room)
      @sections[room&.id].then do |section|
        if section
          _inside, point = section.compute_point(box, Graphene::Point.new(0, 0))
          vadjustment.value = point.y
        end
      end
    end

    def cancel
      @sections.each_value { |section| box.remove(section) }
      @sections = {}
    end

    def box = @box ||= Gtk::Box.new(:vertical, 0)

    private

      def build_section(room)
        SearchSection.new(
          room,
          @search_terms,
          on_result_activated: @on_result_activated,
        ).build
      end
  end
end
