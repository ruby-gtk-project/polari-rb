# frozen_string_literal: true

require 'adwaita'
require_relative 'signals'
require_relative 'utils'
require_relative 'room_manager'
require_relative 'accounts_monitor'

module Polari
  # FeedbackPopover is the popover the entry grows when a slash command has
  # something to say: a wrapped label for one message, or a grid for the
  # command list.
  #
  # Ported from the FeedbackPopover class at the bottom of src/ircParser.js.
  class FeedbackPopover < Gtk::Popover
    GRID_MAX_COLUMNS = 4

    def initialize
      super()
      self.position = :top
    end

    def build
      tap do |popover|
        popover.child = stack

        stack.tap do |s|
          s.add_child(feedback_label)
          s.add_child(feedback_grid)
        end
      end
    end

    def show_feedback(text)
      feedback_label.label = text
      stack.visible_child = feedback_label
      popup
    end

    def show_usage(command)
      show_feedback(format('Usage: %s', IrcParser::KNOWN_COMMANDS.fetch(command)))
    end

    # The command list, laid out in up to four columns, filled column by
    # column the way upstream fills it.
    def show_grid(header, items)
      feedback_grid.tap do |grid|
        grid.children.each { |child| grid.remove(child) }

        columns = [items.length, GRID_MAX_COLUMNS].min
        rows = (items.length / columns) + (items.length % columns)

        grid.attach(Gtk::Label.new(header), 0, 0, columns, 1)
        attach_items(grid, items, rows, columns)
      end

      stack.visible_child = feedback_grid
      popup
    end

    def stack
      @stack ||= Gtk::Stack.new.tap do |stack|
        stack.vhomogeneous = false
      end
    end

    def feedback_label
      @feedback_label ||= Gtk::Label.new.tap do |label|
        label.wrap = true
      end
    end

    def feedback_grid
      @feedback_grid ||= Gtk::Grid.new.tap do |grid|
        grid.column_homogeneous = true
        grid.row_spacing = 6
        grid.column_spacing = 18
      end
    end

    private

      def attach_items(grid, items, rows, columns)
        rows.times do |row|
          columns.times do |column|
            items[row + (column * rows)].then do |item|
              if item
                grid.attach(Gtk::Label.new(item), column, row + 1, 1, 1)
              end
            end
          end
        end
      end
  end

  # IrcParser turns what the user typed into either a message or a slash
  # command, and reports back through the feedback popover (or by marking the
  # entry as erroneous).
  #
  # Ported from src/ircParser.js, keeping the command set, the usage strings
  # and the behaviour of each command. Two notes:
  #
  #   * sending needs a channel, so — exactly as upstream — a room without one
  #     swallows the input rather than reporting an error. The IRC transport
  #     that provides channels is telepathy_client.rb (ported from
  #     src/telepathyClient.js).
  #   * upstream activates app actions with (ssb)/(sssb) tuple parameters.
  #     The Ruby GLib bindings cannot build a tuple variant (an array of
  #     mixed types collapses to a string array), so the port's actions take
  #     string arrays of the same arity; see Application.
  class IrcParser
    include Signals

    KNOWN_COMMANDS = {
      'CLOSE'  => '/CLOSE [<channel>] [<reason>] — closes <channel>, by default the current one',
      'HELP'   => '/HELP [<command>] — displays help for <command>, or a list of available commands',
      'INVITE' => '/INVITE <nick> [<channel>] — invites <nick> to <channel>, or the current one',
      'JOIN'   => '/JOIN <channel> — joins <channel>',
      'KICK'   => '/KICK <nick> — kicks <nick> from current channel',
      'ME'     => '/ME <action> — sends <action> to the current channel',
      'MSG'    => '/MSG <nick> [<message>] — sends a private message to <nick>',
      'NAMES'  => '/NAMES — lists users on the current channel',
      'NICK'   => '/NICK <nickname> — sets your nick to <nickname>',
      'PART'   => '/PART [<channel>] [<reason>] — leaves <channel>, by default the current one',
      'QUERY'  => '/QUERY <nick> — opens a private conversation with <nick>',
      'QUIT'   => '/QUIT [<reason>] — disconnects from the current server',
      'SAY'    => '/SAY <text> — sends <text> to the current room/contact',
      'TOPIC'  => '/TOPIC <topic> — sets the topic to <topic>, or shows the current one',
      'WHOIS'  => '/WHOIS <nick> — requests information on <nick>',
    }.freeze

    UNKNOWN_COMMAND_MESSAGE =
      'Unknown command — try /HELP for a list of available commands'

    ROOM_PREFIXES = ['#', '&', '+', '!'].freeze

    def initialize(entry, room)
      @entry = entry
      @room = room
      @app = Gio::Application.default
      @room_manager = RoomManager.default
    end

    def build
      feedback.tap do |popover|
        popover.build
        popover.set_parent(@entry)

        @entry.signal_connect('activate') do
          if process(@entry.text)
            @entry.text = ''
          else
            @entry.add_css_class('error')
            @entry.grab_focus
          end
        end
      end
    end

    def feedback = @feedback ||= FeedbackPopover.new

    # Handles one line of input. Answers false when the line was wrong, which
    # is what makes the entry go red and keep its text.
    def process(text)
      if @room.nil? || @room.channel.nil? || text.to_s.empty?
        true
      elsif text[0] != '/'
        send_text(text)
        true
      else
        run_command(text)
      end
    end

    private

      def run_command(text)
        argv = text.rstrip.delete_prefix('/').split(/ +/)
        command = argv.shift.to_s.upcase

        case command
        when 'HELP' then command_help(argv)
        when 'INVITE' then command_invite(argv)
        when 'J', 'JOIN' then command_join(argv)
        when 'KICK' then command_kick(argv)
        when 'ME' then command_me(argv, text)
        when 'MSG' then command_msg(argv)
        when 'NAMES' then command_names
        when 'NICK' then command_nick(argv)
        when 'PART', 'CLOSE' then command_part(argv)
        when 'QUERY' then command_query(argv)
        when 'QUIT' then command_quit(text)
        when 'SAY' then command_say(argv, text)
        when 'TOPIC' then command_topic(argv, text)
        when 'WHOIS' then command_whois(argv, text)
        else unknown_command
        end
      end

      def unknown_command
        feedback.show_feedback(UNKNOWN_COMMAND_MESSAGE)
        false
      end

      def strip_command(text) = text[text.index(' ').to_i..].to_s.lstrip

      def command_help(argv)
        command = argv.shift&.upcase

        if command && !KNOWN_COMMANDS.key?(command)
          unknown_command
        elsif command
          feedback.show_usage(command)
          true
        else
          feedback.show_grid('Known commands:', KNOWN_COMMANDS.keys)
          true
        end
      end

      def command_invite(argv)
        with_nick(argv, 'INVITE') do |nick|
          lookup_contact(nick).then do |contact|
            if contact
              @room.add_member(contact)
              true
            else
              false
            end
          end
        end
      end

      def command_kick(argv)
        with_nick(argv, 'KICK') do |nick|
          lookup_contact(nick).then do |contact|
            if contact
              @room.remove_member(contact)
              true
            else
              false
            end
          end
        end
      end

      def command_join(argv)
        with_nick(argv, 'JOIN') do |name|
          if argv.any?
            warn "Excess arguments to JOIN command: #{argv.join(' ')}"
          end

          room = ROOM_PREFIXES.any? { |prefix| name.start_with?(prefix) } ? name : "##{name}"
          activate('join-room', [@room.account.object_path, room])
          true
        end
      end

      def command_me(argv, text)
        if argv.empty?
          feedback.show_usage('ME')
          false
        else
          send_action(strip_command(text))
          true
        end
      end

      def command_msg(argv)
        nick = argv.shift
        message = argv.join(' ')

        if nick.nil? || message.empty?
          feedback.show_usage('MSG')
          false
        else
          activate('message-user', [@room.account.object_path, nick, message])
          true
        end
      end

      def command_names
        @app.activate_action('user-list', nil)
        true
      end

      def command_nick(argv)
        with_nick(argv, 'NICK') do |nick|
          if argv.any?
            warn "Excess arguments to NICK command: #{argv.join(' ')}"
          end

          @app.set_account_nick(@room.account, nick)
          true
        end
      end

      # PART and CLOSE take an optional room name before the reason, so the
      # first argument is only consumed when it names a room we are in.
      def command_part(argv)
        named = argv.first.then do |name|
          name ? @room_manager.lookup_room_by_name(name, @room.account) : nil
        end

        if named
          argv.shift
        end

        room = named || @room
        activate('leave-room', [room.id, argv.join(' ')])
        true
      end

      def command_query(argv)
        with_nick(argv, 'QUERY') do |nick|
          activate('query-user', [@room.account.object_path, nick])
          true
        end
      end

      def command_quit(text)
        @room.account.request_presence(Account::PRESENCE_OFFLINE)
        if @room.channel.respond_to?(:disconnect_with_message)
          @room.channel.disconnect_with_message(strip_command(text))
        end
        true
      end

      def command_say(argv, text)
        if argv.empty?
          feedback.show_usage('SAY')
          false
        else
          send_text(strip_command(text))
          true
        end
      end

      def command_topic(argv, text)
        if argv.any?
          @room.set_topic(strip_command(text))
        else
          feedback.show_feedback(@room.topic || 'No topic set')
        end
        true
      end

      def command_whois(argv, text)
        if argv.empty?
          feedback.show_usage('WHOIS')
          false
        else
          show_user_info(strip_command(text))
        end
      end

      def show_user_info(nick)
        lookup_contact(nick).then do |contact|
          if contact
            feedback.show_feedback(format_user_info(contact))
            true
          else
            false
          end
        end
      end

      def format_user_info(contact)
        info = contact.respond_to?(:contact_info) ? contact.contact_info : {}
        name = info['fn'] || contact.alias
        format(
          'User: %s - Last activity: %s',
          name,
          Utils.format_time_passed(info['x-idle-time']),
        )
      end

      def with_nick(argv, command)
        argv.shift.then do |nick|
          if nick.nil?
            feedback.show_usage(command)
            false
          else
            yield(nick)
          end
        end
      end

      def lookup_contact(nick)
        if @room.channel.respond_to?(:lookup_contact)
          @room.channel.lookup_contact(nick)
        end
      end

      def activate(name, arguments)
        @app.lookup_action(name).activate(GLib::Variant.new(arguments))
      end

      def send_text(text)
        if @room.channel.respond_to?(:send_text)
          @room.channel.send_text(text)
        end
      end

      def send_action(text)
        if @room.channel.respond_to?(:send_action)
          @room.channel.send_action(text)
        end
      end
  end
end
