# frozen_string_literal: true

require 'socket'
require 'openssl'
require 'adwaita'
require_relative 'signals'
require_relative 'accounts_monitor'
require_relative 'room_manager'
require_relative 'room'
require_relative 'message'
require_relative 'util'
require_relative 'utils'
require_relative 'settings'

module Polari
  # IrcContact is the one piece of member state the rest of the port asks of
  # a Telepathy contact: a display name, a lookup key, and the WHOIS-style
  # info block IrcParser's /WHOIS formats.
  #
  # Ported from the TpContact wrapping done throughout src/telepathyClient.js
  # and src/userTracker.js — this port has no Telepathy contacts, only the
  # nick an IRC server line names.
  class IrcContact
    attr_reader :alias

    def initialize(nick)
      @alias = nick.to_s
    end

    def identifier = @alias.downcase
    def to_s = @alias

    # /WHOIS has nothing to show beyond the nick without a round trip this
    # port does not make; IrcParser's format_user_info reads "fn" and
    # "x-idle-time", both absent here, falling back to the nick itself.
    def contact_info = {}
  end

  # IrcChannel is one joined room or private conversation: the whole
  # interface Room, IrcParser and UserTracker ask of a TpTextChannel (see
  # room.rb's class comment, and the FakeChannel test/drive_polari.rb builds
  # to the same contract), backed by a real IrcConnection instead of
  # telepathy-idle.
  class IrcChannel
    include Signals

    attr_reader :account, :identifier, :handle_type, :target_contact, :subject

    def initialize(connection, account:, identifier:, handle_type:)
      @connection = connection
      @account = account
      @identifier = identifier.to_s
      @handle_type = handle_type
      @members = {}
      @subject = nil
      @invalidated = false

      if handle_type == :contact
        @target_contact = IrcContact.new(identifier)
      else
        @target_contact = nil
      end
    end

    def invalidated? = @invalidated

    def self_nick = @connection.nick

    def members = @members.values

    def lookup_contact(nick) = @members[nick.to_s.downcase]

    def send_text(text)
      @connection.privmsg(@identifier, text)
      message_sent(text)
      @connection.notify_sent(self, text)
    end

    def send_action(text)
      @connection.privmsg(@identifier, "\x01ACTION #{text}\x01")
      message_sent("/me #{text}")
      @connection.notify_sent(self, text, action: true)
    end

    def set_subject(topic)
      @connection.set_topic(@identifier, topic)
    end

    def add_members(contacts)
      contacts.each { |contact| @connection.invite(@identifier, contact.alias) }
    end

    def remove_members(contacts)
      contacts.each { |contact| @connection.kick(@identifier, contact.alias) }
    end

    def disconnect_with_message(message)
      @connection.quit(message)
    end

    def message_sent(text) = emit('message-sent', text)

    def invalidate
      unless @invalidated
        @invalidated = true
        emit('invalidated')
      end
    end

    def update_subject(subject)
      @subject = subject
      emit('notify::subject')
    end

    # The dispatch IrcConnection calls as JOIN/PART/QUIT/KICK/NICK lines
    # arrive, matching the shape Room#members_changed destructures.
    def change_members(added: [], removed: [], actor: nil, reason: Room::CHANGE_REASON_NONE, message: nil)
      added.each { |contact| @members[contact.identifier] = contact }
      removed.each { |contact| @members.delete(contact.identifier) }

      emit('group-contacts-changed',
           { added: added, removed: removed, actor: actor, reason: reason, message: message })
    end

    def notify_self_nick = emit('notify::self-nick')
  end

  # RoomInfo is one entry of a /LIST reply: the interface
  # ServerRoomManager#sorted_room_infos asks of a room listing (#name and
  # #members_count).
  RoomInfo = Struct.new(:name, :members_count)

  # IrcConnection is one account's live socket to its IRC server: the actual
  # wire protocol (NICK/USER, JOIN/PART, PRIVMSG, PING/PONG, the numeric
  # replies the UI needs) that telepathy-idle speaks for upstream, run over a
  # background Thread so the blocking reads never stall the GTK main loop,
  # with every effect on the models (notify, emit, new Room members)
  # marshalled back onto it through GLib::Idle.add.
  class IrcConnection
    include Signals

    attr_reader :account, :nick

    def initialize(account, room_manager: RoomManager.default)
      @account = account
      @room_manager = room_manager
      @nick = account.nickname.to_s
      @socket = nil
      @write_mutex = Mutex.new
      @channels = {}
      @room_list = []
      @closing = false
    end

    def channel_for(identifier) = @channels[identifier.to_s.downcase]

    def start
      @account.set_connection_status(Account::STATUS_CONNECTING)

      Thread.new do
        begin
          open_socket
          GLib::Idle.add do
            on_connected
            false
          end
          read_loop
        rescue StandardError => e
          GLib::Idle.add do
            on_connection_error(e)
            false
          end
        end
      end
    end

    def disconnect(message = 'Quit')
      @closing = true
      write_line("QUIT :#{message}")
      close_socket
    end

    def privmsg(target, text)
      text.to_s.each_line(chomp: true) do |line|
        write_line("PRIVMSG #{target} :#{line}")
      end
    end

    def set_topic(channel, topic) = write_line("TOPIC #{channel} :#{topic}")
    def invite(channel, nick) = write_line("INVITE #{nick} #{channel}")
    def kick(channel, nick) = write_line("KICK #{channel} #{nick}")
    def join(channel) = write_line("JOIN #{channel}")

    def part(channel, reason = nil)
      if reason.to_s.empty?
        write_line("PART #{channel}")
      else
        write_line("PART #{channel} :#{reason}")
      end
    end

    def quit(message = nil)
      if message.to_s.empty?
        disconnect('Quit')
      else
        disconnect(message)
      end
    end

    # ServerRoomManager asks for whatever /LIST has collected so far; this
    # port does not block the caller waiting for RPL_LISTEND.
    def list_rooms
      @room_list.each { |info| yield info }
    end

    # Attaches (or re-attaches) the live channel for a saved or newly-opened
    # room, joining it on the wire for a public room. Used both while
    # draining the saved-channel list on connect and by TelepathyClient for
    # a room opened after the connection is already up.
    def attach_room(room)
      connect_room(room)
    end

    # ChatView has no live hookup to a channel's own "message-sent" (see
    # room.rb's class comment: that signal only exists so Room can watch for
    # an identify command), so IrcChannel calls back here with every message
    # it actually sends on the wire, and this is where it reaches the chat
    # log — the same path #deliver uses for what comes back in.
    def notify_sent(channel, text, action: false)
      room = room_for(channel.identifier, channel.handle_type)

      if room
        message = Message.new(text: text, sender: @nick, time: Time.now.utc, is_action: action, is_self: true)
        deliver(room, message, sent: true)
      end
    end

    private

      def open_socket
        params = @account.connection_params
        raw = TCPSocket.open(params['server'], params['port'])

        if params['use-ssl']
          @socket = OpenSSL::SSL::SSLSocket.new(raw).tap do |ssl|
            ssl.sync_close = true
            ssl.connect
          end
        else
          @socket = raw
        end
      end

      def on_connected
        username = @account.parameters.fetch('account', @nick).to_s
        write_line("NICK #{@nick}")
        write_line("USER #{username} 0 * :#{username}")
      end

      def on_connection_error(error)
        @account.set_connection_status(
          Account::STATUS_DISCONNECTED,
          reason: Account::REASON_NONE_SPECIFIED,
          error:  Account::ERROR_CONNECTION_FAILED,
        )
        warn "Failed to connect account #{@account.display_name}: #{error.message}"
      end

      def read_loop
        while (line = read_line)
          schedule_line(line.chomp)
        end
        GLib::Idle.add do
          on_disconnected
          false
        end
      end

      # A `while` loop has one binding for `line` across every iteration, so
      # a closure built directly inside it would see whatever the LAST
      # iteration left there by the time GLib actually runs it, not the line
      # that was current when it was scheduled. Handing the line to a method
      # call gives each iteration its own parameter binding instead.
      def schedule_line(line)
        GLib::Idle.add do
          handle_line(line)
          false
        end
      end

      def read_line
        @socket&.gets("\n")
      rescue IOError, Errno::ECONNRESET, OpenSSL::SSL::SSLError
        nil
      end

      def on_disconnected
        if @closing
          @account.set_connection_status(Account::STATUS_DISCONNECTED, reason: Account::REASON_REQUESTED)
        else
          @account.set_connection_status(
            Account::STATUS_DISCONNECTED,
            reason: Account::REASON_NONE_SPECIFIED,
            error:  Account::ERROR_CONNECTION_FAILED,
          )
        end

        if @account.connection == self
          @account.connection = nil
        end

        @channels.each_value(&:invalidate)
      end

      def write_line(text)
        @write_mutex.synchronize do
          @socket&.write("#{text}\r\n")
        end
      rescue IOError, Errno::EPIPE, OpenSSL::SSL::SSLError => e
        warn "Failed to write to #{@account.display_name}: #{e.message}"
      end

      def close_socket
        @socket&.close
      rescue IOError
        nil
      ensure
        @socket = nil
      end

      PREFIX_NICK_REGEX = /\A([^!@]+)/

      def nick_from_prefix(prefix) = prefix.to_s[PREFIX_NICK_REGEX, 1].to_s

      # A minimal but real IRC message parser: an optional ":prefix ", a
      # command, then space-separated params, the last of which may be a
      # ":trailing param with spaces".
      def parse_line(line)
        rest = line
        prefix = nil

        if rest.start_with?(':')
          prefix, rest = rest[1..].split(' ', 2)
          rest = rest.to_s
        end

        parts = rest.split(' ')
        command = parts.shift.to_s.upcase
        params = []

        parts.each_with_index do |part, index|
          if part.start_with?(':')
            params << parts[index..].join(' ').delete_prefix(':')
            break
          else
            params << part
          end
        end

        [prefix, command, params]
      end

      def handle_line(line)
        prefix, command, params = parse_line(line)

        case command
        when 'PING' then write_line("PONG :#{params.last}")
        when '001' then on_welcome(params)
        when '433' then on_nick_in_use
        when '332' then on_topic_reply(params)
        when '353' then on_names_reply(params)
        when '321' then @room_list = []
        when '322' then on_list_entry(params)
        when 'JOIN' then on_join(prefix, params)
        when 'PART' then on_part(prefix, params)
        when 'QUIT' then on_quit(prefix, params)
        when 'KICK' then on_kick(prefix, params)
        when 'NICK' then on_nick_changed(prefix, params)
        when 'TOPIC' then on_topic_set(params)
        when 'PRIVMSG' then on_message(prefix, params)
        when 'NOTICE' then on_message(prefix, params)
        end
      end

      def on_welcome(params)
        welcomed_nick = params.first.to_s

        unless welcomed_nick.empty?
          @nick = welcomed_nick
        end

        @account.connection = self
        @account.set_connection_status(Account::STATUS_CONNECTED)
        write_line('LIST')
        maybe_identify
        connect_saved_rooms
      end

      def on_nick_in_use
        @nick = "#{@nick}_"
        write_line("NICK #{@nick}")
      end

      def maybe_identify
        password = Utils.lookup_identify_password(@account)

        if password && !password.to_s.empty?
          send_identify(password)
        end
      end

      def send_identify(password)
        settings = @account.settings
        botname = settings['identify-botname']
        channel = ensure_channel(botname, :contact)
        command = settings['identify-command']

        if settings['identify-username'].to_s.empty?
          username = nil
        else
          username = settings['identify-username']
        end

        text = [command, username, password].compact.reject(&:empty?).join(' ')
        channel.send_text(text)
      end

      def connect_saved_rooms
        @room_manager.rooms.select { |room| room.account == @account }.each { |room| connect_room(room) }
      end

      def connect_room(room)
        channel = ensure_channel(room.channel_name, room.type)
        room.channel = channel

        if room.type == :room
          join(room.channel_name)
        end
      end

      def ensure_channel(identifier, type)
        @channels[identifier.to_s.downcase] ||= IrcChannel.new(
          self,
          account:     @account,
          identifier:  identifier,
          handle_type: type,
        )
      end

      def on_list_entry(params)
        name, count = params
        @room_list << RoomInfo.new(name.to_s, count.to_i)
      end

      def on_topic_reply(params)
        _me, channel_name, topic = params
        room_for(channel_name, :room)&.update_topic(topic.to_s)
      end

      def on_topic_set(params)
        channel_name, topic = params
        room_for(channel_name, :room)&.update_topic(topic.to_s)
      end

      def on_names_reply(params)
        _me, _flag, channel_name, names = params
        channel = channel_for(channel_name)

        if channel
          added = names.to_s.split(' ').map { |raw| IrcContact.new(raw.sub(/\A[@+%&~]/, '')) }
          channel.change_members(added: added)
        end
      end

      # Our own JOIN echoing back confirms the channel the earlier #join (or
      # /JOIN) already requested; it must not send another JOIN for it, or
      # a server that itself echoes JOIN turns this into a loop that never
      # settles.
      def on_join(prefix, params)
        nick = nick_from_prefix(prefix)
        channel_name = params.first

        if nick.downcase == @nick.downcase
          room = room_for(channel_name, :room)

          if room && room.channel.nil?
            room.channel = ensure_channel(channel_name, :room)
          end
        else
          channel_for(channel_name)&.change_members(added: [IrcContact.new(nick)])
        end
      end

      def on_part(prefix, params)
        nick = nick_from_prefix(prefix)
        channel_name, reason = params
        channel = channel_for(channel_name)

        if channel
          if nick.downcase == @nick.downcase
            channel.invalidate
          else
            channel.change_members(removed: [IrcContact.new(nick)], message: reason)
          end
        end
      end

      def on_quit(prefix, params)
        nick = nick_from_prefix(prefix)
        reason = params.first

        @channels.each_value do |channel|
          member = channel.lookup_contact(nick)

          if member
            channel.change_members(removed: [member], reason: Room::CHANGE_REASON_OFFLINE, message: reason)
          end
        end
      end

      def on_kick(prefix, params)
        actor_nick = nick_from_prefix(prefix)
        channel_name, kicked_nick, reason = params
        channel = channel_for(channel_name)

        if channel
          if kicked_nick.to_s.downcase == @nick.downcase
            channel.invalidate
          else
            member = channel.lookup_contact(kicked_nick) || IrcContact.new(kicked_nick)
            channel.change_members(
              removed: [member],
              actor:   IrcContact.new(actor_nick),
              reason:  Room::CHANGE_REASON_KICKED,
              message: reason,
            )
          end
        end
      end

      def on_nick_changed(prefix, params)
        old_nick = nick_from_prefix(prefix)
        new_nick = params.first.to_s

        if old_nick.downcase == @nick.downcase
          @nick = new_nick
          @channels.each_value(&:notify_self_nick)
        else
          old_contact = IrcContact.new(old_nick)
          new_contact = IrcContact.new(new_nick)

          @channels.each_value do |channel|
            if channel.lookup_contact(old_nick)
              channel.change_members(
                added:   [new_contact],
                removed: [old_contact],
                reason:  Room::CHANGE_REASON_RENAMED,
              )
            end
          end
        end
      end

      def on_message(prefix, params)
        sender_nick = nick_from_prefix(prefix)
        target, text = params

        unless sender_nick.empty? || text.nil?
          deliver_incoming(sender_nick, target.to_s, text)
        end
      end

      def deliver_incoming(sender_nick, target, text)
        is_action = text.start_with?("\x01ACTION ") && text.end_with?("\x01")

        if is_action
          body = text.delete_prefix("\x01ACTION ").delete_suffix("\x01")
        else
          body = text
        end

        if target.downcase == @nick.downcase
          room_target = sender_nick
          type = :contact
        else
          room_target = target
          type = :room
        end

        room = ensure_room(room_target, type)

        if room
          message = Message.new(text: body, sender: sender_nick, time: Time.now.utc, is_action: is_action)
          deliver(room, message)
        end
      end

      def room_for(channel_name, type)
        @room_manager.lookup_room(Room.create_room_id(@account, channel_name, type))
      end

      def ensure_room(channel_name, type)
        room = room_for(channel_name, type)

        if room.nil?
          channel = ensure_channel(channel_name, type)
          @room_manager.ensure_room_for_channel(channel, present: false)
        else
          if room.channel.nil?
            room.channel = ensure_channel(channel_name, type)
          end
          room
        end
      end

      def deliver(room, message, sent: false)
        application = Polari::Application.current
        window = application&.app&.active_window

        if window.respond_to?(:room_stack)
          view = window.room_stack.view_for_room(room)

          if view
            if sent
              view.chat_view.message_sent(message)
            else
              view.chat_view.message_received(message)
            end
          end
        end
      end
  end

  # TelepathyClient is the port's whole replacement for src/telepathyClient.js:
  # where upstream registers a Tp.BaseClient and lets Mission Control and
  # telepathy-idle do the actual IRC protocol, this port owns the socket
  # itself. It watches AccountsMonitor for the two things that used to be a
  # TpAccount's job — a presence request, and the account going away — and
  # RoomManager for rooms the user opens or closes once connected.
  class TelepathyClient
    def initialize(accounts_monitor: AccountsMonitor.default, room_manager: RoomManager.default)
      @accounts_monitor = accounts_monitor
      @room_manager = room_manager
      @connections = {}
    end

    def start
      @accounts_monitor.prepare do
        @accounts_monitor.accounts.each { |account| watch_account(account) }
        @accounts_monitor.visible_accounts.each { |account| maybe_connect(account) }
      end

      @accounts_monitor.connect('account-added') { |_m, account| watch_account(account) }
      @accounts_monitor.connect('account-removed') { |_m, account| disconnect_account(account) }

      @room_manager.connect('room-added') { |_m, room| on_room_added(room) }
      @room_manager.connect('room-removed') { |_m, room| on_room_removed(room) }

      self
    end

    private

      def maybe_connect(account)
        if account.enabled?
          connect_account(account)
        end
      end

      def watch_account(account)
        account.connect('notify::requested-presence-type') { on_presence_changed(account) }
        account.connect('notify::enabled') { on_enabled_changed(account) }
      end

      def on_enabled_changed(account)
        if account.enabled?
          if account.requested_presence_type == Account::PRESENCE_AVAILABLE
            connect_account(account)
          end
        else
          disconnect_account(account)
        end
      end

      def on_presence_changed(account)
        if account.requested_presence_type == Account::PRESENCE_AVAILABLE
          connect_account(account)
        else
          disconnect_account(account)
        end
      end

      def connect_account(account)
        unless @connections.key?(account.object_path)
          connection = IrcConnection.new(account, room_manager: @room_manager)
          @connections[account.object_path] = connection
          connection.start
        end
      end

      def disconnect_account(account)
        connection = @connections.delete(account.object_path)
        connection&.disconnect
      end

      def on_room_added(room)
        connection = @connections[room.account.object_path]

        if connection && room.account.connection_status == Account::STATUS_CONNECTED
          connection.attach_room(room)
        end
      end

      def on_room_removed(room)
        connection = @connections[room.account.object_path]

        if connection && room.channel && room.type == :room
          connection.part(room.channel_name)
        end
      end
  end
end
