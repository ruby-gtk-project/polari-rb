# frozen_string_literal: true

require_relative 'signals'
require_relative 'settings'
require_relative 'accounts_monitor'
require_relative 'room'

module Polari
  # RoomManager is the registry of open rooms, and the saved-channel list
  # that brings them back on the next start.
  #
  # Ported from src/roomManager.js: lookupRoom/lookupRoomByName, the rooms
  # getter, restoring the saved channels once the accounts are known, and
  # keeping "saved-channel-list" in step as rooms are joined and left
  # (including dropping an account's channels when the account goes away).
  #
  # Upstream reaches this through GActions with (ssb)/(sssb) parameters that
  # the window, the IRC parser and the dialogs activate. Tuple variants
  # carrying booleans do not survive the Ruby GLib bindings, so the actions in
  # application.rb take the string parameters and call the methods below —
  # join_room, message_user and leave_room — which is where upstream's action
  # handlers put their bodies.
  class RoomManager
    include Signals

    def self.default = @default ||= new

    def self.reset = @default = nil

    def initialize(settings: Settings.default, accounts_monitor: AccountsMonitor.default)
      @rooms = {}
      @settings = settings
      @accounts_monitor = accounts_monitor

      @accounts_monitor.connect('account-shown') do |_mon, account|
        restore_rooms(account.object_path)
      end
      @accounts_monitor.connect('account-hidden') do |_mon, account|
        remove_rooms(account.object_path)
      end
      @accounts_monitor.connect('account-removed') do |_mon, account|
        remove_rooms(account.object_path)
        remove_saved_channels_for_account(account.object_path)
      end

      @accounts_monitor.prepare { restore_rooms }
    end

    def lookup_room(id) = @rooms[id]

    def lookup_room_by_name(name, account)
      @rooms.values.find do |room|
        room.channel_name == name.to_s.downcase && room.account == account
      end
    end

    def lookup_room_by_channel(channel)
      Room.create_room_id(
        channel.account,
        channel.identifier,
        channel.handle_type,
      ).then { |id| @rooms[id] }
    end

    def room_count = @rooms.size

    def rooms = @rooms.values

    # app.join-room: remembers the channel, then joins it.
    def join_room(account_path, channel_name, present: true)
      add_saved_channel(account_path, channel_name)

      @accounts_monitor.prepare do
        ensure_room(account_path, channel_name, :room, present: present)
      end
    end

    # app.message-user: opens a private conversation, which is never saved.
    def message_user(account_path, nick, present: true)
      @accounts_monitor.prepare do
        ensure_room(account_path, nick, :contact, present: present)
      end
    end

    # app.leave-room: forgets the channel and drops the room.
    def leave_room(id)
      @rooms[id].then do |room|
        if room
          remove_saved_channel(room.account.object_path, room.channel_name)
          remove_room(room)
        end
      end
    end

    # Called by the IRC transport when it has a channel for a room, creating
    # the room if the channel arrived unprompted (an invite, or a private
    # message from someone new).
    def ensure_room_for_channel(channel, present: false)
      account_path = channel.account.object_path
      channel_name = channel.target_contact&.alias || channel.identifier

      ensure_room(
        account_path,
        channel_name,
        channel.handle_type,
        present: present,
      ).tap { |room| room.channel = channel }
    end

    def ensure_room(account_path, channel_name, type, present: false)
      account = @accounts_monitor.lookup_account(account_path)

      if account.nil?
        remove_saved_channels_for_account(account_path)
        nil
      else
        add_room(account, channel_name, type, present: present)
      end
    end

    private

      def add_room(account, channel_name, type, present:)
        if account.visible?
          id = Room.create_room_id(account, channel_name, type)
          room = @rooms[id] || create_room(account, channel_name, type)

          if present
            emit('room-presented', room)
          end
          room
        end
      end

      def create_room(account, channel_name, type)
        Room.new(
          account:      account,
          channel_name: channel_name,
          type:         type,
        ).tap do |room|
          @rooms[room.id] = room
          emit('room-added', room)
        end
      end

      def remove_room(room)
        if @rooms.delete(room.id)
          emit('room-removed', room)
        end
      end

      def remove_rooms(account_path)
        @rooms.values.each do |room|
          if account_path.nil? || room.account.object_path == account_path
            remove_room(room)
          end
        end
      end

      def restore_rooms(account_path = nil)
        saved_channels.each do |channel|
          if account_path.nil? || channel['account'] == account_path
            ensure_room(channel['account'], channel['channel'], :room, present: false)
          end
        end
        emit('rooms-loaded')
      end

      def saved_channels = @settings['saved-channel-list']

      def find_channel_index(channels, account_path, channel_name)
        match_name = channel_name.to_s.downcase

        channels.find_index do |channel|
          channel['account'] == account_path &&
            channel['channel'].to_s.downcase == match_name
        end
      end

      def add_saved_channel(account_path, channel_name)
        saved_channels.dup.then do |channels|
          if find_channel_index(channels, account_path, channel_name).nil?
            channels.push('account' => account_path, 'channel' => channel_name)
            @settings['saved-channel-list'] = channels
          end
        end
      end

      def remove_saved_channel(account_path, channel_name)
        saved_channels.dup.then do |channels|
          find_channel_index(channels, account_path, channel_name).then do |position|
            if position
              channels.delete_at(position)
              @settings['saved-channel-list'] = channels
            end
          end
        end
      end

      def remove_saved_channels_for_account(account_path)
        @settings['saved-channel-list'] = saved_channels.reject do |channel|
          channel['account'] == account_path
        end
      end
  end
end
