# frozen_string_literal: true

require 'gio2'
require_relative 'signals'
require_relative 'util'

module Polari
  # Room is one conversation: a channel on an account, its display name,
  # topic, member list and the nick we answer to in it.
  #
  # Ported from src/lib/polari-room.c, including the parts that are easy to
  # get wrong: the room id is the account path, the handle type and the
  # case-folded channel name; the channel name is folded but the display name
  # keeps the case the user typed (minus a leading '#'); topics and part
  # messages have IRC colour codes stripped; and the nick we highlight on is
  # the base nick unless the account's user name sits between the base nick
  # and the full nick, in which case it is the user name.
  #
  # The channel is whatever the IRC transport hands us
  # (src/telepathyClient.js, not ported yet). Room only requires of it the
  # interface polari-room.c requires of a TpTextChannel: the signals
  # group-contacts-changed, message-sent and invalidated, a member list, and
  # methods to send a message, set the subject and add or remove members.
  class Room
    include Signals

    # Tp.HandleType, whose numbers are part of the room id
    HANDLE_TYPE_NONE = 0
    HANDLE_TYPE_CONTACT = 1
    HANDLE_TYPE_ROOM = 2

    TYPE_NUMBERS = {
      contact: HANDLE_TYPE_CONTACT,
      room:    HANDLE_TYPE_ROOM,
      none:    HANDLE_TYPE_NONE,
    }.freeze

    # Tp.ChannelGroupChangeReason, as on_group_contacts_changed switches on it
    CHANGE_REASON_NONE = :none
    CHANGE_REASON_OFFLINE = :offline
    CHANGE_REASON_KICKED = :kicked
    CHANGE_REASON_BANNED = :banned
    CHANGE_REASON_RENAMED = :renamed

    # Returns the room id for an account, a channel name and a handle type.
    def self.create_room_id(account, name, type)
      "#{account.object_path}/#{TYPE_NUMBERS.fetch(type, HANDLE_TYPE_NONE)}/#{name.to_s.downcase}"
    end

    attr_reader :account, :type, :channel_name, :display_name, :topic, :icon,
                :channel, :channel_error

    def initialize(account:, channel_name:, type: :room)
      @account = account
      @type = type
      @topic = nil
      @channel = nil
      @channel_error = nil
      @channel_signals = []
      @ignore_identify = false

      update_self_user
      set_channel_name(channel_name)
      update_icon
      update_self_nick
    end

    def id = self.class.create_room_id(@account, @channel_name, @type)

    def room? = @type == :room
    def contact? = @type == :contact

    def self_nick = @self_nick

    # Whether a message should be highlighted: always in a private
    # conversation, and in a room when it mentions our nick and is not our
    # own.
    def should_highlight_message?(sender, message)
      if room?
        !match_self_nick?(sender) && match_self_nick?(message)
      else
        true
      end
    end

    def channel_error=(error)
      unless error == @channel_error
        @channel_error = error
        notify('channel-error')
      end
    end

    def channel=(channel)
      unless channel == @channel
        disconnect_channel
        if channel && check_channel(channel)
          connect_channel(channel)
        end
        update_self_nick
        notify('channel')
      end
    end

    # The members of the channel, as the user list and tab completion see
    # them: objects answering to #alias.
    def members
      if @channel.respond_to?(:members)
        @channel.members
      else
        []
      end
    end

    def set_topic(topic)
      if @channel.respond_to?(:set_subject)
        @channel.set_subject(topic)
      end
    end

    # Set by the transport (or by /TOPIC's round trip through the server),
    # with colour codes stripped the way update_subject() strips them.
    def update_topic(raw_topic)
      Util.strip_color_codes(raw_topic).then do |subject|
        unless subject == @topic
          @topic = subject
          notify('topic')
        end
      end
    end

    def add_member(member)
      if @channel.respond_to?(:add_members)
        @channel.add_members([member])
      end
    end

    def remove_member(member)
      if @channel.respond_to?(:remove_members)
        @channel.remove_members([member])
      end
    end

    # Sends an identify/login message to the nick-serving bot, and keeps the
    # ::identify-sent signal from firing for our own message.
    def send_identify_message(command:, password:, username: nil)
      if @channel.nil?
        raise IOError, 'The room is disconnected.'
      end

      @ignore_identify = true
      text = [command, username, password].compact.reject(&:empty?).join(' ')

      begin
        @channel.send_text(text)
      rescue StandardError => e
        @ignore_identify = false
        raise e
      end
    end

    # Called by the transport for every message we sent, so a plain
    # "identify <password>" the user typed into a private conversation can
    # offer to store the password.
    def message_sent(text)
      if contact?
        Util.match_identify_message(text).then do |parsed|
          if parsed
            unless @ignore_identify
              emit('identify-sent', *parsed)
            end
            @ignore_identify = false
          end
        end
      end
    end

    # The dispatch of on_group_contacts_changed: one signal per member for
    # the reason the server gave, then ::members-changed once.
    def members_changed(added: [], removed: [], actor: nil, reason: CHANGE_REASON_NONE, message: nil)
      text = message.nil? ? nil : Util.strip_color_codes(message)

      case reason
      when CHANGE_REASON_RENAMED then emit_renamed(added, removed)
      when CHANGE_REASON_OFFLINE
        removed.each { |member| emit('member-disconnected', member, text) }
      when CHANGE_REASON_KICKED
        removed.each { |member| emit('member-kicked', member, actor) }
      when CHANGE_REASON_BANNED
        removed.each { |member| emit('member-banned', member, actor) }
      when CHANGE_REASON_NONE
        removed.each { |member| emit('member-left', member, text) }
        added.each { |member| emit('member-joined', member) }
      end

      emit('members-changed')
    end

    private

      def emit_renamed(added, removed)
        if removed.length == 1 && added.length == 1
          emit('member-renamed', removed.first, added.first)
        else
          warn "Renamed: expected 1 removed and 1 added, but got #{removed.length} " \
               "removed and #{added.length} added"
        end
      end

      def set_channel_name(channel_name)
        if channel_name
          @channel_name = channel_name.downcase
          set_display_name(channel_name.delete_prefix('#'))
        else
          @channel_name = nil
          set_display_name(nil)
        end
        notify('channel-name')
      end

      def set_display_name(display_name)
        @display_name = display_name
        notify('display-name')
      end

      def update_icon
        @icon = contact? ? Gio::ThemedIcon.new('avatar-default-symbolic') : nil
        notify('icon')
      end

      # The IRC user name of the account, trimmed to its trailing
      # alphanumeric and folded — "nick_" configured as the account name
      # highlights as "nick".
      def update_self_user
        username = @account.parameters.fetch('account', '').to_s
        length = username.length
        length -= 1 while length.positive? && !Util.alnum?(username[length - 1])
        @self_user = username[0, length].to_s.downcase
      end

      # We want highlights for 'nick-away'/'nick' and vice versa, but not for
      # 'the-nick'/'the': when basenick <= username <= nickname, the username
      # is the safer thing to match on.
      def update_self_nick
        nick = current_nick.to_s
        basenick = Util.get_basenick(nick)

        if @self_user.start_with?(basenick) && nick.downcase.start_with?(@self_user)
          @self_nick = @self_user
        else
          @self_nick = basenick
        end
      end

      def current_nick
        if @channel.respond_to?(:self_nick) && @channel.self_nick
          @channel.self_nick
        else
          @account.nickname
        end
      end

      def match_self_nick?(text) = Util.match_nick(text.to_s, @self_nick)

      # A channel only belongs to this room when it is on the same account
      # and carries the same (folded) name.
      def check_channel(channel)
        channel.account == @account &&
          channel.identifier.to_s.downcase == @channel_name
      end

      def connect_channel(channel)
        @channel = channel

        if channel.respond_to?(:connect)
          @channel_signals = [
            channel.connect('group-contacts-changed') do |_c, details|
              members_changed(**details)
            end,
            channel.connect('message-sent') { |_c, text| message_sent(text) },
            channel.connect('invalidated') { self.channel = nil },
            channel.connect('notify::self-nick') { update_self_nick },
          ]
        end

        if channel.respond_to?(:subject)
          update_topic(channel.subject.to_s)
        end
      end

      def disconnect_channel
        if @channel.respond_to?(:disconnect)
          @channel_signals.each { |id| @channel.disconnect(id) }
        end
        @channel_signals = []
        @channel = nil
      end
  end
end
