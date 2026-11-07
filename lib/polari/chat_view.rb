# frozen_string_literal: true

require 'adwaita'
require_relative 'logger'
require_relative 'message'
require_relative 'util'
require_relative 'utils'
require_relative 'user_list'
require_relative 'paste_manager'

module Polari
  # ChatView is the message log: a Gtk::TextView with one tag per role (nick,
  # message, status, timestamp, action, url, …), the backlog paged in from the
  # chat log, clickable nicks and links, and the "chatlog" action group the
  # link context menu acts through.
  #
  # Ported from src/chatView.js. What is kept: the tag set and the tag
  # colours looked up from the stylesheet (active_nick_color and friends in
  # data/style.css), the gap/timestamp/nick-column layout of an inserted
  # message, the compression of join/leave noise into a clickable header, the
  # "New Messages" tag, the pending-message marks that stop autoscrolling on
  # an unread highlight, masking identify passwords in private chats, the
  # nick popover and the URL context menu, and paging the backlog in on scroll
  # or Page_Up.
  #
  # Two things upstream does in virtual functions that the Ruby bindings do
  # not let a subclass override:
  #
  #   * vfunc_snapshot paints the "New Messages" rule and label. Here the
  #     indicator is the 'indicator-line' tag that upstream also applies, so
  #     the position is marked but not drawn.
  #   * vfunc_measure reports a minimum width of one pixel to work around the
  #     text view growing horizontally; the port asks the scrolled window for
  #     the same effect with hscrollbar_policy :never and a width request.
  #
  # Upstream emits ::logs-ready and ::text-dropped and notifies
  # ::max-nick-chars; a Ruby class cannot add GObject signals, so the
  # callbacks are passed in, the way the pilot port passes them.
  class ChatView < Gtk::ScrolledWindow
    include DropTargets

    MAX_NICK_CHARS = 8
    IGNORE_STATUS_TIME = 5
    SCROLL_TIMEOUT = 100

    # Seconds of inactivity after which to insert a timestamp.
    TIMESTAMP_INTERVAL = 300

    # A threshold in seconds used to control the visibility of status
    # messages, and the number of them that collapses into a header.
    INACTIVITY_THRESHOLD = 300
    STATUS_NOISE_MAXIMUM = 4

    NUM_INITIAL_LOG_EVENTS = 50
    NUM_LOG_EVENTS = 10

    MARGIN = 14

    # Space after nicks, matching the nick button in the entry area:
    # 8px padding + 6px spacing.
    NICK_SPACING = 14

    NICKTAG_PREFIX = 'nick'

    TAGS = [
      { name: 'nick', left_margin: MARGIN, weight: Pango::Weight::BOLD },
      { name: 'gap', pixels_above_lines: 10 },
      { name: 'message', indent: 0 },
      { name: 'highlight', weight: Pango::Weight::BOLD },
      { name: 'status', left_margin: MARGIN, indent: 0 },
      { name: 'timestamp', left_margin: MARGIN, indent: 0, justification: :right },
      { name: 'action', left_margin: MARGIN, style: :italic },
      { name: 'url', underline: :single },
      { name: 'indicator-line', pixels_above_lines: 24 },
      { name: 'loading', left_margin: MARGIN, justification: :center },
    ].freeze

    def initialize(
      room,
      user_tracker:,
      on_logs_ready: nil,
      on_max_nick_chars_changed: nil,
      on_text_dropped: nil,
      on_file_dropped: nil
    )
      super()
      @room = room
      @user_tracker = user_tracker
      @on_logs_ready = on_logs_ready
      @on_max_nick_chars_changed = on_max_nick_chars_changed
      @on_text_dropped = on_text_dropped
      @on_file_dropped = on_file_dropped

      @state = { last_nick: nil, last_timestamp: 0, last_status_group: 0 }
      @status_count = { left: 0, joined: 0, total: 0 }
      @pending = {}
      @initial_pending = []
      @button_tags = {}
      @nick_popovers = {}
      @last_activity = {}
      @join_time = 0
      @needs_indicator = true
      @autoscroll = true
      @fetching_backlog = false
      @queried_initial_backlog = false
      @indent_width_chars = MAX_NICK_CHARS
      @oldest_message_time = Time.now.utc + (24 * 60 * 60)
      @log_walker = LogWalker.new(room)

      self.hscrollbar_policy = :never
      self.vexpand = true
      set_size_request(1, -1)
      add_css_class('polari-chat-view')
    end

    attr_reader :room

    def max_nick_chars = @indent_width_chars

    # Nothing can be pasted into a room we are not connected to.
    def can_drop? = !@room.channel.nil?

    def build
      tap do
        insert_action_group('chatlog', action_group)
        self.child = text_view

        text_view.tap do |view|
          view.add_controller(key_controller)
          view.add_controller(motion_controller)
          view.add_controller(click_gesture)
        end

        add_controller(scroll_controller)
        add_drop_targets(text_view, on_text: @on_text_dropped, on_file: @on_file_dropped)
        create_tags
        update_indent
        connect_adjustment
        connect_room

        update_max_nick_chars(@room.account.nickname.to_s.length)
        fetch_initial_backlog
      end
    end

    # The transport hands received and sent messages here; both are inserted,
    # and both end a run of compressed status messages.
    def message_received(message)
      insert_new_message(message)
      reset_status_compressed
      @last_activity[Util.get_basenick(message.sender)] = monotonic_seconds
    end

    def message_sent(message)
      insert_new_message(message)
      reset_status_compressed
    end

    # Jumps the log to a date a search result named, paging in the events
    # around it.
    def show_search_inline(date)
      @oldest_message_time = [date, @oldest_message_time].min
      insert_logs(@log_walker.get_events(date, NUM_LOG_EVENTS), date)
      set_search_mark(date)
    end

    def text_view
      @text_view ||= Gtk::TextView.new.tap do |view|
        view.editable = false
        view.cursor_visible = false
        view.wrap_mode = :word_char
        view.right_margin = MARGIN
        view.bottom_margin = MARGIN
      end
    end

    def buffer = text_view.buffer

    def action_group
      @action_group ||= Gio::SimpleActionGroup.new.tap do |group|
        group.insert(open_url_action)
        group.insert(copy_url_action)
      end
    end

    def open_url_action
      @open_url_action ||= Gio::SimpleAction.new('open-url', GLib::VariantType.new('s')).tap do |action|
        action.signal_connect('activate') { |_a, param| Utils.open_url(param) }
      end
    end

    def copy_url_action
      @copy_url_action ||= Gio::SimpleAction.new('copy-url', GLib::VariantType.new('s')).tap do |action|
        action.signal_connect('activate') { |_a, param| clipboard.set(param) }
      end
    end

    def key_controller
      @key_controller ||= Gtk::EventControllerKey.new.tap do |controller|
        controller.signal_connect('key-pressed') do |_c, keyval, _code, _state|
          on_key_pressed(keyval)
        end
      end
    end

    def scroll_controller
      @scroll_controller ||= Gtk::EventControllerScroll.new(:vertical).tap do |controller|
        controller.signal_connect('scroll') { |_c, _dx, dy| on_scroll(dy) }
      end
    end

    def motion_controller
      @motion_controller ||= Gtk::EventControllerMotion.new.tap do |controller|
        controller.signal_connect('motion') { |_c, x, y| handle_button_tags_hover(x, y) }
        controller.signal_connect('enter') { |_c, x, y| handle_button_tags_hover(x, y) }
        controller.signal_connect('leave') { handle_button_tags_hover(nil, nil) }
      end
    end

    def click_gesture
      @click_gesture ||= Gtk::GestureClick.new.tap do |gesture|
        gesture.propagation_phase = :capture
        gesture.button = 0
        gesture.signal_connect('pressed') { |g, n, x, y| on_pressed(g, n, x, y) }
        gesture.signal_connect('released') { |g, n, x, y| on_released(g, n, x, y) }
      end
    end

    private

      def connect_adjustment
        vadjustment.tap do |adjustment|
          adjustment.signal_connect('value-changed') { check_messages }
          adjustment.signal_connect('changed') { update_scroll }
        end

        signal_connect('edge-reached') do |_w, position|
          if position == Gtk::PositionType::BOTTOM
            @autoscroll = true
          end
        end
      end

      def connect_room
        @room.connect('notify::channel') { on_channel_changed }
        @room.connect('member-renamed') do |_r, old_member, new_member|
          insert_status(
            format('%s is now known as %s', old_member.alias, new_member.alias),
            old_member.alias,
            :renamed,
          )
        end
        @room.connect('member-disconnected') do |_r, member, message|
          insert_status(with_reason(format('%s has disconnected', member.alias), message),
                        member.alias, :left)
        end
        @room.connect('member-kicked') { |_r, member, actor| insert_kicked(member, actor) }
        @room.connect('member-banned') { |_r, member, actor| insert_banned(member, actor) }
        @room.connect('member-joined') do |_r, member|
          insert_status(format('%s joined', member.alias), member.alias, :joined)
        end
        @room.connect('member-left') do |_r, member, message|
          insert_status(with_reason(format('%s left', member.alias), message),
                        member.alias, :left)
        end

        @room.account.connect('notify::nickname') do
          update_max_nick_chars(@room.account.nickname.to_s.length)
        end

        @nick_status_handler = @user_tracker.watch_room_status(@room, nil) do |base_nick, status|
          on_nick_status_changed(base_nick, status)
        end

        on_channel_changed
      end

      def with_reason(text, message)
        if message.to_s.empty?
          text
        else
          "#{text} (#{message})"
        end
      end

      def insert_kicked(member, actor)
        text = actor ? format('%s has been kicked by %s', member.alias, actor.alias)
                     : format('%s has been kicked', member.alias)
        insert_status(text, member.alias, :left)
      end

      def insert_banned(member, actor)
        text = actor ? format('%s has been banned by %s', member.alias, actor.alias)
                     : format('%s has been banned', member.alias)
        insert_status(text, member.alias, :left)
      end

      def create_tags
        TAGS.each do |properties|
          tag = Gtk::TextTag.new(properties[:name])
          properties.except(:name).each { |name, value| tag.set_property(name.to_s, value) }
          buffer.tag_table.add(tag)
        end
        update_tag_colors
      end

      # The nick, status, timestamp and link colours come from the
      # stylesheet, exactly as upstream looks them up in vfunc_css_changed.
      def update_tag_colors
        @active_nick_color = lookup_color('active_nick_color')
        @inactive_nick_color = lookup_color('inactive_nick_color')
        @hovered_link_color = lookup_color('active_nick_hover_color')
        @status_header_hover_color = lookup_color('inactive_nick_hover_color')

        { 'status' => @inactive_nick_color,
          'timestamp' => @inactive_nick_color,
          'url' => @active_nick_color, }.each do |name, color|
          lookup_tag(name).foreground_rgba = color
        end
      end

      def lookup_color(name)
        found, color = style_context.lookup_color(name)
        found ? color : Gdk::RGBA.parse('#000000')
      end

      # The nick column is a tab stop one nick-width in, with the paragraph
      # indented back by the same amount, so wrapped lines line up under the
      # message rather than the nick.
      def update_indent
        metrics = text_view.pango_context.get_metrics(nil, nil)
        char_width = [metrics.approximate_char_width, metrics.approximate_digit_width].max
        pixel_width = Pango.units_to_double(char_width)
        total_width = (@indent_width_chars * pixel_width) + NICK_SPACING

        text_view.tabs = Pango::TabArray.new(1, true).tap do |tabs|
          tabs.set_tab(0, :left, total_width)
        end
        text_view.indent = -total_width
        text_view.left_margin = [MARGIN - total_width, 0].max.to_i
      end

      def update_max_nick_chars(length)
        if length > @indent_width_chars
          @indent_width_chars = length
          update_indent
          @on_max_nick_chars_changed&.call(@indent_width_chars)
        end
      end

      def fetch_initial_backlog
        @fetching_backlog = true
        get_log_events(@oldest_message_time, NUM_INITIAL_LOG_EVENTS)
      end

      def get_log_events(date, num)
        events = @log_walker.get_events(date, num)
        hide_loading_indicator
        @fetching_backlog = false

        unless events.empty?
          insert_logs(events, date)
        end

        unless @queried_initial_backlog
          @queried_initial_backlog = true
          @on_logs_ready&.call
        end
      end

      def insert_logs(events, insert_date)
        append_initial_pending(events) unless @initial_pending.empty?
        indicator_index = events.length - @initial_pending.length
        state = { last_nick: nil, last_timestamp: 0 }
        iter = insertion_point(insert_date)

        events.each_with_index do |message, index|
          insert_message(iter, message, state)

          if index == indicator_index
            set_indicator_mark(iter)
          end

          if !iter.end? || index < events.length - 1
            buffer.insert(iter, "\n")
          end
        end

        update_oldest_message_time(events)
      end

      def update_oldest_message_time(events)
        events.first.then do |first|
          if first && first.time < @oldest_message_time
            @oldest_message_time = first.time
          end
        end
      end

      # The channel's pending messages are already in the log, so the tail of
      # the log is replaced by them rather than shown twice.
      def append_initial_pending(logs)
        pending = @initial_pending.slice!(0, @initial_pending.length)
        first = pending.first
        position = [logs.length - pending.length, 0].max

        while position < logs.length && logs[position] != first
          position += 1
        end

        logs.slice!(position, logs.length)
        logs.concat(pending)
      end

      def insertion_point(insert_date)
        if insert_date == @oldest_message_time
          buffer.start_iter
        else
          buffer.end_iter
        end
      end

      def insert_new_message(message)
        ensure_new_line
        iter = buffer.end_iter
        insert_message(iter, message, @state)

        if @needs_indicator && !message.self?
          set_indicator_mark(buffer.end_iter)
        end
      end

      def insert_message(iter, message, state)
        nick = message.sender
        text = message.text
        needs_gap = nick != state[:last_nick] || message.action?
        highlight = @room.should_highlight_message?(nick, text)
        timestamp = message.time.to_i

        needs_gap = insert_timestamp(iter, timestamp, needs_gap)
        state[:last_timestamp] = timestamp
        update_max_nick_chars(nick.to_s.length)

        body, tags = message_body(iter, message, state, needs_gap)

        if highlight && !@room.contact?
          tags.push(lookup_tag('highlight'))
        end

        insert_text_with_urls(iter, mask_identify_password(body), tags)
        mark_pending(iter, message, highlight)
      end

      def insert_timestamp(iter, timestamp, needs_gap)
        if timestamp - TIMESTAMP_INTERVAL > @state[:last_timestamp]
          tags = [lookup_tag('timestamp')]
          if needs_gap
            tags.push(lookup_tag('gap'))
          end
          insert_with_tags(iter, "#{Utils.format_date_time(Time.at(timestamp))}\n", tags)
          false
        else
          needs_gap
        end
      end

      # An action is one italic line starting with the nick; a normal message
      # puts the nick in its own column and the text after the tab stop.
      def message_body(iter, message, state, needs_gap)
        if message.action?
          state[:last_nick] = nil
          tags = [lookup_tag('action')]
          if needs_gap
            tags.push(lookup_tag('gap'))
          end
          ["#{message.sender} #{message.text}", tags]
        else
          insert_nick(iter, message.sender, state, needs_gap)
          state[:last_nick] = message.sender
          [message.text, [lookup_tag('message')]]
        end
      end

      def insert_nick(iter, nick, state, needs_gap)
        unless state[:last_nick] == nick
          tags = [lookup_tag('nick'), nick_tag(nick)]
          if needs_gap
            tags.push(lookup_tag('gap'))
          end
          insert_with_tags(iter, nick, tags)
          buffer.insert(iter, "\t")
        end
      end

      def nick_tag(nick)
        name = nick_tag_name(nick)

        lookup_tag(name) || Gtk::TextTag.new(name).tap do |tag|
          buffer.tag_table.add(tag)
          @button_tags[tag] = { kind: :nick, nick: nick }
          update_nick_tag(tag, @user_tracker.nick_room_status(nick, @room))
        end
      end

      def nick_tag_name(nick) = "#{NICKTAG_PREFIX}#{Util.get_basenick(nick)}"

      def nick_from_tag_name(name)
        if name.to_s.start_with?(NICKTAG_PREFIX)
          name.sub(NICKTAG_PREFIX, '')
        end
      end

      # Identify passwords the user typed into a private conversation are
      # shown as dots rather than in the clear.
      def mask_identify_password(text)
        if @room.contact?
          Util.match_identify_message(text).then do |parsed|
            if parsed
              text.sub(parsed.last, '●' * parsed.last.length)
            else
              text
            end
          end
        else
          text
        end
      end

      def insert_text_with_urls(iter, text, tags)
        server = @room.account.parameters['server'].to_s
        urls = (Utils.find_urls(text) + Utils.find_channels(text, server)).sort_by(&:pos)
        position = 0

        urls.each do |url|
          insert_with_tags(iter, text[position, url.pos - position].to_s, tags)
          insert_with_tags(iter, url.name, tags + [lookup_tag('url'), url_tag(url.url)])
          position = url.pos + url.name.length
        end

        insert_with_tags(iter, text[position..].to_s, tags)
      end

      def url_tag(url)
        Gtk::TextTag.new.tap do |tag|
          buffer.tag_table.add(tag)
          @button_tags[tag] = { kind: :url, url: url }
        end
      end

      def mark_pending(iter, message, highlight)
        if highlight && message.pending_id
          @pending[message.pending_id] = buffer.create_mark(nil, iter, true)
        end
      end

      def insert_status(text, member, type)
        time = Time.now.to_i

        if time - @join_time >= IGNORE_STATUS_TIME
          grouped = time - @state[:last_timestamp] > INACTIVITY_THRESHOLD

          if grouped || show_status?(member)
            @state[:last_nick] = nil
            insert_status_text(text, type, grouped)
          end
        end
      end

      def insert_status_text(text, type, grouped)
        tags = [lookup_tag('status')]

        if grouped
          count_status(type)
          update_status_header
          tags.push(lookup_tag("status#{@state[:last_status_group]}"))
        else
          reset_status_compressed
        end

        ensure_new_line
        insert_with_tags(buffer.end_iter, text, tags.compact)
      end

      def count_status(type)
        if @status_count.key?(type)
          @status_count[type] += 1
          @status_count[:total] += 1
        end
      end

      # A nick we have not heard from in a while produces no join/leave
      # noise at all.
      def show_status?(nick)
        @last_activity[Util.get_basenick(nick)].then do |activity|
          !activity.nil? && (monotonic_seconds - activity) < INACTIVITY_THRESHOLD
        end
      end

      def reset_status_compressed
        buffer.get_mark('idle-status-start').then do |mark|
          if mark
            buffer.delete_mark(mark)
            @status_count = { left: 0, joined: 0, total: 0 }
            @state[:last_status_group] += 1
          end
        end
      end

      # The "3 users joined, 1 user left" header that collapses a run of
      # status messages once it passes STATUS_NOISE_MAXIMUM.
      def update_status_header
        group = @state[:last_status_group]
        header_tag = ensure_status_tags(group)
        mark = buffer.get_mark('idle-status-start')

        if mark
          clear_header_line(mark)
        else
          ensure_new_line
          buffer.create_mark('idle-status-start', buffer.end_iter, true)
        end

        if @status_count[:total] > STATUS_NOISE_MAXIMUM && header_tag.invisible?
          header_tag.invisible = false
          lookup_tag("status#{group}").invisible = true
        end

        insert_status_header_text(group, header_tag)
      end

      def ensure_status_tags(group)
        lookup_tag("status-compressed#{group}") || create_status_tags(group)
      end

      def create_status_tags(group)
        group_tag = Gtk::TextTag.new("status#{group}")
        arrow_tag = Gtk::TextTag.new("status-arrow-compressed#{group}")
        arrow_tag.invisible = true

        Gtk::TextTag.new("status-compressed#{group}").tap do |header_tag|
          header_tag.invisible = true
          [header_tag, arrow_tag, group_tag].each { |tag| buffer.tag_table.add(tag) }

          group_tag.bind_property('invisible', arrow_tag, 'invisible', :invert_boolean)
          @button_tags[header_tag] = { kind: :status_header, group: group }
        end
      end

      def clear_header_line(mark)
        start = buffer.get_iter_at_mark(mark)
        finish = start.dup
        finish.forward_to_line_end
        buffer.delete(start, finish)
      end

      def insert_status_header_text(group, header_tag)
        stats = []
        if @status_count[:joined].positive?
          stats.push(pluralize_users(@status_count[:joined], 'joined'))
        end
        if @status_count[:left].positive?
          stats.push(pluralize_users(@status_count[:left], 'left'))
        end

        iter = buffer.get_iter_at_mark(buffer.get_mark('idle-status-start'))
        tags = [lookup_tag('gap'), lookup_tag('status'), header_tag]
        text = stats.join(', ')

        insert_with_tags(iter, "#{text} ", tags)
        insert_with_tags(iter, arrow_for(text), tags + [lookup_tag("status-arrow-compressed#{group}")])
        insert_with_tags(iter, "▼", tags + [lookup_tag("status#{group}")])
      end

      def arrow_for(text)
        Pango.find_base_dir(text, -1) == Pango::Direction::LTR ? "▶" : "◀"
      end

      def pluralize_users(count, what)
        if count == 1
          format('%d user %s', count, what)
        else
          format('%d users %s', count, what)
        end
      end

      def on_channel_changed
        @pending.each_key { |id| remove_pending_mark(id) }

        if @room.channel
          @join_time = Time.now.to_i
          @initial_pending = @room.channel.respond_to?(:pending_messages) ? @room.channel.pending_messages : []
        end

        update_max_nick_chars(@room.self_nick.to_s.length)
      end

      def remove_pending_mark(id)
        @pending[id].then do |mark|
          if mark
            if buffer.get_iter_at_mark(mark).end?
              @autoscroll = true
            end
            buffer.delete_mark(mark)
            @pending.delete(id)
          end
        end
      end

      def on_nick_status_changed(base_nick, status)
        lookup_tag(nick_tag_name(base_nick)).then do |tag|
          if tag
            update_nick_tag(tag, status)
          end
        end
      end

      def update_nick_tag(tag, status)
        tag.foreground_rgba =
          status == UserTracker::STATUS_AVAILABLE ? @active_nick_color : @inactive_nick_color
      end

      def update_scroll
        if @autoscroll
          if @search_mark
            text_view.scroll_mark_onscreen(@search_mark)
          elsif @pending.empty?
            text_view.scroll_mark_onscreen(ensure_end_mark)
          else
            @autoscroll = false
            text_view.scroll_mark_onscreen(@pending.values.first)
          end
        end
      end

      def ensure_end_mark
        buffer.get_mark('scroll-end').then do |mark|
          if mark
            buffer.move_mark(mark, buffer.end_iter)
            mark
          else
            buffer.create_mark('scroll-end', buffer.end_iter, false)
          end
        end
      end

      def on_scroll(delta_y)
        set_search_mark(nil)

        if delta_y >= 0
          false
        else
          @autoscroll = false
          fetch_backlog
        end
      end

      def on_key_pressed(keyval)
        case keyval
        when Gdk::Keyval::KEY_Home, Gdk::Keyval::KEY_KP_Home then scroll_to_edge(-1)
        when Gdk::Keyval::KEY_End, Gdk::Keyval::KEY_KP_End then scroll_to_edge(1)
        when Gdk::Keyval::KEY_Up, Gdk::Keyval::KEY_KP_Up,
             Gdk::Keyval::KEY_Page_Up, Gdk::Keyval::KEY_KP_Page_Up
          set_search_mark(nil)
          @autoscroll = false
          fetch_backlog
        else false
        end
      end

      def scroll_to_edge(direction)
        text_view.move_cursor(Gtk::MovementStep::BUFFER_ENDS, direction, false)
        true
      end

      def fetch_backlog
        if vadjustment.value != 0 || @log_walker.end?
          false
        elsif @fetching_backlog
          true
        else
          @fetching_backlog = true
          show_loading_indicator
          get_log_events(@oldest_message_time, NUM_LOG_EVENTS)
          true
        end
      end

      def show_loading_indicator
        iter = buffer.start_iter
        indicator = Gtk::Image.new.tap do |image|
          image.icon_name = 'content-loading-symbolic'
          image.add_css_class('dim-label')
        end

        anchor = buffer.create_child_anchor(iter)
        text_view.add_child_at_anchor(indicator, anchor)
        buffer.insert(iter, "\n")

        buffer.remove_all_tags(buffer.start_iter, iter)
        buffer.apply_tag(lookup_tag('loading'), buffer.start_iter, iter)
      end

      def hide_loading_indicator
        iter = buffer.start_iter

        if iter.child_anchor
          iter.forward_line
          buffer.delete(buffer.start_iter, iter)
        end
      end

      # The "New Messages" position. Upstream paints a rule and a label here
      # from vfunc_snapshot; the tag is what marks the line.
      def set_indicator_mark(iter)
        line_start = iter.dup
        line_start.line_offset = 0
        mark = buffer.get_mark('indicator-line')

        if mark
          clear_indicator_tag(buffer.get_iter_at_mark(mark))
          buffer.move_mark(mark, line_start)
        else
          buffer.create_mark('indicator-line', line_start, true)
        end

        line_iters(line_start).then do |(start, finish)|
          buffer.apply_tag(lookup_tag('indicator-line'), start, finish)
        end
        @needs_indicator = false
      end

      def clear_indicator_tag(iter)
        line_iters(iter).then do |(start, finish)|
          buffer.remove_tag(lookup_tag('indicator-line'), start, finish)
        end
      end

      def line_iters(iter)
        start = iter.dup
        start.backward_line
        start.forward_to_line_end

        finish = iter.dup
        finish.forward_to_line_end

        [start, finish]
      end

      # Acknowledges the pending messages that are on screen, so the room's
      # unread counter only counts what the user has not seen.
      def check_messages
        if @room.channel.respond_to?(:ack_message) && !@pending.empty?
          rect = text_view.visible_rect

          @pending.each do |id, mark|
            location = text_view.get_iter_location(buffer.get_iter_at_mark(mark))
            if rect.y <= location.y && (rect.y + rect.height) > location.y
              @room.channel.ack_message(id)
            end
          end
        end
        @needs_indicator = true
      end

      def set_search_mark(date)
        if @search_mark
          buffer.delete_mark(@search_mark)
        end
        @search_mark = nil

        if date
          @search_mark = buffer.create_mark(nil, insertion_point(date), true)
        end
        update_scroll
      end

      def handle_button_tags_hover(x, y)
        hovered = hovered_button_tags(x, y)

        (@hovered_button_tags || []).each do |tag|
          unless hovered.include?(tag)
            reset_tag_hover(tag)
          end
        end
        hovered.each { |tag| apply_tag_hover(tag) }

        if hovered.empty? != (@hovered_button_tags || []).empty?
          text_view.set_cursor_from_name(hovered.empty? ? 'text' : 'pointer')
        end
        @hovered_button_tags = hovered
      end

      def hovered_button_tags(x, y)
        if x.nil? || y.nil?
          []
        else
          buffer_x, buffer_y = text_view.window_to_buffer_coords(:widget, x.to_i, y.to_i)
          iter = text_view.get_iter_at_location(buffer_x, buffer_y)
          iter.nil? ? [] : iter.tags.select { |tag| @button_tags.key?(tag) }
        end
      end

      def apply_tag_hover(tag)
        info = @button_tags[tag]

        case info[:kind]
        when :url then tag.foreground_rgba = @hovered_link_color
        when :status_header then tag.foreground_rgba = @status_header_hover_color
        end
      end

      def reset_tag_hover(tag)
        info = @button_tags[tag]

        case info[:kind]
        when :url then tag.foreground_rgba = @active_nick_color
        when :status_header then tag.foreground_rgba = @inactive_nick_color
        end
      end

      def on_pressed(gesture, n_press, x, y)
        if n_press == 1 && gesture.current_event.triggers_context_menu?
          hovered_button_tags(x, y).each do |tag|
            info = @button_tags[tag]
            if info[:kind] == :url
              show_url_context_menu(info[:url], x, y)
              gesture.state = Gtk::EventSequenceState::CLAIMED
            end
          end
        end
      end

      def on_released(gesture, n_press, x, y)
        if n_press == 1 && gesture.current_button == Gdk::BUTTON_PRIMARY
          hovered_button_tags(x, y).each { |tag| activate_button_tag(tag, x, y) }
        end
      end

      def activate_button_tag(tag, x, y)
        info = @button_tags[tag]

        case info[:kind]
        when :url then open_url_action.activate(GLib::Variant.new(info[:url]))
        when :nick then show_nick_popover(tag, x, y)
        when :status_header then toggle_status_group(info[:group])
        end
      end

      def toggle_status_group(group)
        lookup_tag("status#{group}").then do |tag|
          tag.invisible = !tag.invisible?
        end
      end

      def show_url_context_menu(url, x, y)
        menu = Gio::Menu.new.tap do |model|
          model.append_item(url_menu_item('Open Link', 'chatlog.open-url', url))
          model.append_item(url_menu_item('Copy Link Address', 'chatlog.copy-url', url))
        end

        Gtk::PopoverMenu.new(menu).tap do |popover|
          popover.position = :bottom
          popover.has_arrow = false
          popover.pointing_to = Gdk::Rectangle.new(x.to_i, y.to_i, 1, 1)
          popover.set_parent(text_view)
          popover.popup
        end
      end

      def url_menu_item(label, action, url)
        Gio::MenuItem.new(label, nil).tap do |item|
          item.set_action_and_target_value(action, GLib::Variant.new(url))
        end
      end

      def show_nick_popover(tag, x, y)
        buffer_x, buffer_y = text_view.window_to_buffer_coords(:widget, x.to_i, y.to_i)
        iter = text_view.get_iter_at_location(buffer_x, buffer_y)

        if iter
          nick = nick_at(iter, tag)
          popover = @nick_popovers[tag] ||= build_nick_popover
          popover.nickname = nick
          popover.pointing_to = Gdk::Rectangle.new(x.to_i, y.to_i, 1, 1)
          popover.popup
        end
      end

      def build_nick_popover
        UserPopover.new(room: @room, user_tracker: @user_tracker).tap do |popover|
          popover.build
          popover.set_parent(text_view)
        end
      end

      def nick_at(iter, tag)
        start = iter.dup
        finish = iter.dup

        unless start.starts_tag(tag)
          start.backward_to_tag_toggle(tag)
        end
        unless finish.ends_tag(tag)
          finish.forward_to_tag_toggle(tag)
        end

        buffer.get_slice(start, finish, false)
      end

      def ensure_new_line
        iter = buffer.end_iter

        unless iter.line_offset.zero?
          insert_with_tags(iter, "\n", continued_status_tags(iter))
        end
      end

      def continued_status_tags(iter)
        group = @state[:last_status_group]

        [lookup_tag("status#{group}"), lookup_tag("status-compressed#{group}")]
          .compact
          .select { |tag| iter.ends_tag(tag) }
      end

      def lookup_tag(name) = buffer.tag_table.lookup(name)

      def insert_with_tags(iter, text, tags)
        offset = iter.offset
        buffer.insert(iter, text)
        start = buffer.get_iter_at_offset(offset)

        buffer.remove_all_tags(start, iter)
        tags.compact.each { |tag| buffer.apply_tag(tag, start, iter) }
      end

      def monotonic_seconds = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
end
