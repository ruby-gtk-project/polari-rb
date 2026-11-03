# frozen_string_literal: true

require 'adwaita'
require_relative 'irc_parser'

module Polari
  # TabCompletion completes nicks and slash commands in the chat entry: Tab
  # inserts the first match, a popover lists the rest, and Tab again (or the
  # arrow keys) walks through them.
  #
  # Ported from src/tabCompletion.js, including the details that make it feel
  # right: a completion at the start of the line gets ": " appended, a
  # completion that directly follows a previous one chains with ", ", a
  # command completion gets a plain space, and Escape puts back what the user
  # had typed.
  class TabCompletion
    def initialize(entry)
      @entry = entry
      @can_complete = false
      @key = ''
      @start_pos = 0
      @end_pos = -1
      @is_command = false
      @is_chained = false
      @previous_was_command = false
      @rows = {}
    end

    def build
      popup.tap do |popover|
        popover.set_parent(@entry)
        popover.child = list

        list.tap do |box|
          box.set_filter_func { |row| filter(row) }
          box.signal_connect('row-selected') { |_box, row| on_row_selected(row) }
          box.signal_connect('row-activated') { stop }

          IrcParser::KNOWN_COMMANDS.each_key do |command|
            box.append(completion_row("/#{command}"))
          end
        end

        @entry.add_controller(key_controller)
        @entry.add_controller(focus_controller)
        @entry.signal_connect('unmap') { cancel }
      end
    end

    # The nick list of the current room, handed over whenever the membership
    # changes. Rows for nicks that are gone are dropped, the command rows
    # stay.
    def set_completions(completions)
      if popup.visible?
        id = popup.signal_connect('unmap') do
          popup.signal_handler_disconnect(id)
          set_completions(completions)
        end
      else
        replace_nick_rows(completions)
        @can_complete = !completions.empty?
      end
    end

    def popup
      @popup ||= Gtk::Popover.new.tap do |popover|
        popover.position = :top
        popover.autohide = false
      end
    end

    def list
      @list ||= Gtk::ListBox.new.tap do |box|
        box.selection_mode = :single
      end
    end

    def key_controller
      @key_controller ||= Gtk::EventControllerKey.new.tap do |controller|
        controller.propagation_phase = :capture
        controller.signal_connect('key-pressed') do |_c, keyval, _code, _state|
          on_key_pressed(keyval)
        end
      end
    end

    def focus_controller
      @focus_controller ||= Gtk::EventControllerFocus.new.tap do |controller|
        controller.signal_connect('leave') { cancel }
      end
    end

    private

      def completion_row(text)
        Gtk::ListBoxRow.new.tap do |row|
          row.child = Gtk::Label.new(text).tap do |label|
            label.halign = :start
            label.margin_start = 6
            label.margin_end = 6
          end
          @rows[row] = text
        end
      end

      def row_text(row) = @rows[row].to_s

      def replace_nick_rows(completions)
        kept = {}

        completions.each do |nick|
          existing = @rows.key(nick)
          if existing
            kept[existing] = nick
            list.remove(existing)
          end
        end

        list.children.each do |row|
          unless row_text(row).start_with?('/')
            list.remove(row)
            @rows.delete(row)
          end
        end

        @rows = @rows.select { |_row, text| text.start_with?('/') }.merge(kept)
        completions.each { |nick| list.append(@rows.key(nick) || completion_row(nick)) }
      end

      def on_key_pressed(keyval)
        if @key.empty?
          start_completion(keyval)
        else
          continue_completion(keyval)
        end
      end

      def start_completion(keyval)
        if keyval == Gdk::Keyval::KEY_Tab
          start
          true
        else
          false
        end
      end

      def continue_completion(keyval)
        case keyval
        when Gdk::Keyval::KEY_Tab, Gdk::Keyval::KEY_Down then move_selection(1)
        when Gdk::Keyval::KEY_ISO_Left_Tab, Gdk::Keyval::KEY_Up then move_selection(-1)
        when Gdk::Keyval::KEY_Escape then cancel
        else stop_on_text(keyval)
        end
      end

      def move_selection(count)
        visible = visible_rows

        if visible.any?
          current = list.selected_row
          index = current ? visible.index(current).to_i : 0
          list.select_row(visible[(index + visible.length + count) % visible.length])
        end
        true
      end

      # Any key that produces a character ends the completion; the Return
      # that would otherwise activate the entry while the popup is up is
      # eaten.
      def stop_on_text(keyval)
        if Gdk::Keyval.to_unicode(keyval).zero?
          false
        else
          popup_shown = popup.visible?
          stop
          popup_shown && [
            Gdk::Keyval::KEY_Return,
            Gdk::Keyval::KEY_KP_Enter,
            Gdk::Keyval::KEY_ISO_Enter,
          ].include?(keyval)
        end
      end

      def row_completion(row)
        @previous_was_command = @is_command

        if @is_command
          "#{row_text(row)} "
        elsif @start_pos.zero? || @is_chained
          "#{row_text(row)}: "
        else
          row_text(row)
        end
      end

      def on_row_selected(row)
        if row
          insert_completion(row_completion(row))
        end
      end

      def filter(row)
        if @key.empty?
          false
        else
          row_text(row).downcase.start_with?(@key)
        end
      end

      def insert_completion(completion)
        position = @entry.position
        @end_pos = @start_pos + completion.length
        @entry.delete_text(@start_pos, position)
        @entry.insert_text(completion, -1, @start_pos)
        @entry.position = @end_pos
      end

      # Turns the ":" of the previous completion into a "," (or back), which
      # is what makes "nick1, nick2: " read correctly.
      def set_previous_completion_chained(chained)
        start = @start_pos - 2
        @entry.delete_text(start, start + 1)
        @entry.insert_text(chained ? ',' : ':', -1, start)
      end

      def start
        if @can_complete
          text = @entry.text[0, @entry.position].to_s
          @start_pos = text.rindex(' ').then { |index| index ? index + 1 : 0 }
          @key = text[@start_pos..].to_s.downcase
          @is_command = @key.start_with?('/')

          if @start_pos.zero?
            @end_pos = -1
          end

          @is_chained = @end_pos == @start_pos && !@is_command && !@previous_was_command

          list.invalidate_filter
          complete_first
        end
      end

      def complete_first
        visible_rows.then do |visible|
          if visible.any?
            if @is_chained
              set_previous_completion_chained(true)
            end
            insert_completion(row_completion(visible.first))

            if visible.length > 1
              list.select_row(visible.first)
              show_popup
            end
          end
        end
      end

      def show_popup
        delegate = @entry.delegate
        extents, = delegate.compute_cursor_extents(@start_pos)
        _inside, bounds = @entry.compute_bounds(delegate)

        popup.pointing_to = Gdk::Rectangle.new((extents.x - bounds.x).to_i, 0, 1, 1)
        popup.popup
      end

      def stop
        unless @key.empty?
          popup.popdown
          popup.set_size_request(-1, -1)
          @key = ''
          list.invalidate_filter
        end
        true
      end

      def cancel
        unless @key.empty?
          if @is_chained
            set_previous_completion_chained(false)
          end
          insert_completion('')
          stop
        end
        true
      end

      def visible_rows = list.children.select(&:child_visible?)
  end
end
