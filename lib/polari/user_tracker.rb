# frozen_string_literal: true

require 'gio2'
require_relative 'signals'
require_relative 'util'
require_relative 'accounts_monitor'
require_relative 'room_manager'

module Polari
  # UserTracker knows who is online on one account: which base nicks are in
  # which rooms, which of them are muted, and which of them someone asked to
  # be notified about.
  #
  # Ported from src/userTracker.js. The two maps (per-room contacts and the
  # account-wide base-nick map), the per-room watch handlers, and the
  # approximation for private chats — where the member is kept out of the
  # account-wide map and dropped from every room once the last public room
  # loses them — are upstream's, including the comments explaining why.
  #
  # Upstream notices mutes through "changed::muted-usernames" on the
  # account's GSettings; this port's Settings is a plain JSON file with no
  # change notification, so mute_nick/unmute_nick emit ::muted-changed
  # themselves after writing.
  class UserTracker
    include Signals

    STATUS_AVAILABLE = :available
    STATUS_OFFLINE = :offline

    def initialize(account, room_manager: RoomManager.default, app: Gio::Application.default)
      @account = account
      @room_manager = room_manager
      @app = app
      @base_nick_contacts = {}
      @room_data = {}
      @handler_counter = 0
      @muted_users = account.settings['muted-usernames']

      @room_manager.connect('room-added') { |_mgr, room| on_room_added(room) }
      @room_manager.connect('room-removed') { |_mgr, room| on_room_removed(room) }
      @room_manager.rooms.each { |room| on_room_added(room) }
    end

    def nick_status(nick)
      contacts = @base_nick_contacts[Util.get_basenick(nick)] || []
      contacts.empty? ? STATUS_OFFLINE : STATUS_AVAILABLE
    end

    def nick_room_status(nick, room)
      ensure_room_mapping(room)
      contacts = room_contacts(room)[Util.get_basenick(nick)] || []
      contacts.empty? ? STATUS_OFFLINE : STATUS_AVAILABLE
    end

    def muted?(nick) = @muted_users.include?(nick.to_s.downcase)

    def mute_nick(nick)
      unless muted?(nick)
        @muted_users = @muted_users + [nick.to_s.downcase]
        @account.settings['muted-usernames'] = @muted_users
        emit("muted-changed::#{nick}", nick, true)
      end
    end

    def unmute_nick(nick)
      if muted?(nick)
        @muted_users = @muted_users.reject { |muted| muted == nick.to_s.downcase }
        @account.settings['muted-usernames'] = @muted_users
        emit("muted-changed::#{nick}", nick, false)
      end
    end

    # The contact object behind a nick, preferring the exact spelling over
    # another nick sharing its base nick.
    def lookup_contact(nick)
      contacts = @base_nick_contacts[Util.get_basenick(nick)] || []
      contacts.find { |contact| contact.alias == nick } || contacts.first
    end

    # Watches one room (optionally one base nick in it) for status changes,
    # and answers the handler id to unwatch with.
    def watch_room_status(room, base_nick, &callback)
      ensure_room_mapping(room)
      @handler_counter += 1
      room_handlers(room)[@handler_counter] = { nick: base_nick, handler: callback }
      @handler_counter
    end

    def unwatch_room_status(room, handler_id)
      if @room_data.key?(room)
        room_handlers(room).delete(handler_id)
      end
    end

    # The stateful per-nick action the user popover's bell button toggles.
    def notify_action_name(nick)
      name = internal_notify_action_name(nick)

      if @app.lookup_action(name).nil?
        enabled = nick_status(nick) == STATUS_OFFLINE
        action = Gio::SimpleAction.new(name, nil, GLib::Variant.new(false))
        action.enabled = enabled
        action.signal_connect('notify::enabled') do
          unless action.enabled?
            action.change_state(GLib::Variant.new(false))
          end
        end
        @app.add_action(action)
      end

      "app.#{name}"
    end

    # Called by the transport, or by the room's own membership signals, for
    # the members a channel starts with.
    def track_initial_members(room)
      if room.channel.nil?
        clear_users_from_room(room)
      else
        room.members.each { |member| track_member(member, room) }
      end
    end

    private

      def room_contacts(room) = @room_data.dig(room, :contacts)
      def room_handlers(room) = @room_data.dig(room, :handlers)
      def room_signals(room) = @room_data.dig(room, :signals)

      def ensure_room_mapping(room)
        @room_data[room] ||= { contacts: {}, handlers: {}, signals: [] }
      end

      def on_room_added(room)
        if room.account == @account
          ensure_room_mapping(room)

          room_signals(room).push(
            room.connect('notify::channel') { track_initial_members(room) },
            room.connect('member-joined') { |_r, member| track_member(member, room) },
            room.connect('member-left') { |_r, member| untrack_member(member, room) },
            room.connect('member-disconnected') { |_r, member| untrack_member(member, room) },
            room.connect('member-kicked') { |_r, member| untrack_member(member, room) },
            room.connect('member-banned') { |_r, member| untrack_member(member, room) },
            room.connect('member-renamed') do |_r, old_member, new_member|
              untrack_member(old_member, room)
              track_member(new_member, room)
            end,
          )

          track_initial_members(room)
        end
      end

      def on_room_removed(room)
        if @room_data.key?(room)
          room_signals(room).each { |id| room.disconnect(id) }
          clear_users_from_room(room)
          @room_data.delete(room)
        end
      end

      def clear_users_from_room(room)
        ensure_room_mapping(room)
        room_contacts(room).values.flat_map(&:dup).each do |member|
          untrack_member(member, room)
        end
      end

      def run_handlers(room, member, status)
        base_nick = Util.get_basenick(member.alias)

        room_handlers(room).each_value do |info|
          if info[:nick].nil? || info[:nick] == base_nick
            info[:handler].call(base_nick, status)
          end
        end
      end

      def push_member(map, base_nick, member)
        map[base_nick] ||= []
        map[base_nick].push(member).length
      end

      def pop_member(map, base_nick, member)
        contacts = map[base_nick] || []
        index = contacts.index { |contact| contact.alias == member.alias }

        if index.nil?
          [false, contacts.length]
        else
          contacts.delete_at(index)
          [true, contacts.length]
        end
      end

      def track_member(member, room)
        ensure_room_mapping(room)
        base_nick = Util.get_basenick(member.alias)

        if push_member(room_contacts(room), base_nick, member) == 1
          run_handlers(room, member, STATUS_AVAILABLE)
        end

        # Telepathy does not notify on member changes for private chats, so
        # the online status is approximated by keeping those contacts out of
        # the account-wide map.
        if room.room?
          track_member_globally(member, room, base_nick)
        end

        emit("contacts-changed::#{base_nick}", member.alias)
      end

      def track_member_globally(member, room, base_nick)
        if push_member(@base_nick_contacts, base_nick, member) == 1
          emit("status-changed::#{base_nick}", base_nick, STATUS_AVAILABLE)

          if should_notify_nick?(member.alias)
            notify_nick_available(member, room)
          end
          set_notify_action_enabled(member.alias, false)
        end
      end

      def untrack_member(member, room)
        ensure_room_mapping(room)
        base_nick = Util.get_basenick(member.alias)

        pop_member(room_contacts(room), base_nick, member).then do |(found, remaining)|
          if found && remaining.zero?
            run_handlers(room, member, STATUS_OFFLINE)
          end
        end

        untrack_member_globally(member, base_nick)
      end

      def untrack_member_globally(member, base_nick)
        pop_member(@base_nick_contacts, base_nick, member).then do |(found, remaining)|
          if found
            if remaining.zero?
              emit("status-changed::#{base_nick}", member.alias, STATUS_OFFLINE)
              set_notify_action_enabled(member.alias, true)
              @app.withdraw_notification(internal_notify_action_name(member.alias))
              drop_from_private_chats(member)
            end
            emit("contacts-changed::#{base_nick}", member.alias)
          end
        end
      end

      # The member is no longer in any public room, so assume they
      # disconnected and remove them from the private chats as well.
      def drop_from_private_chats(member)
        @room_data.keys.each do |room|
          unless room.room?
            untrack_member(member, room)
          end
        end
      end

      def notify_nick_available(member, room)
        notification = Gio::Notification.new('User is online')
        notification.body = format('User %s is now online.', member.alias)
        notification.set_default_action_and_target(
          'app.join-room',
          GLib::Variant.new([@account.object_path, room.channel_name]),
        )

        @app.send_notification(internal_notify_action_name(member.alias), notification)
      end

      def should_notify_nick?(nick)
        @app.get_action_state(internal_notify_action_name(nick)).then do |state|
          state ? state.value : false
        end
      end

      def set_notify_action_enabled(nick, enabled)
        @app.lookup_action(internal_notify_action_name(nick)).then do |action|
          if action
            action.enabled = enabled
          end
        end
      end

      def internal_notify_action_name(nick)
        suffix = @account.path_suffix.tr('/', '-')
        "notify-user-#{suffix}-#{Util.get_basenick(nick)}"
      end
  end

  # UserStatusMonitor holds one UserTracker per account, and wires the
  # mute-nick/unmute-nick actions to them.
  #
  # Ported from the UserStatusMonitor class at the top of src/userTracker.js.
  class UserStatusMonitor
    def self.default = @default ||= new

    def self.reset = @default = nil

    def initialize(accounts_monitor: AccountsMonitor.default, app: Gio::Application.default)
      @user_trackers = {}
      @accounts_monitor = accounts_monitor
      @app = app

      connect_mute_actions

      @accounts_monitor.connect('account-added') { |_mon, account| add_account(account) }
      @accounts_monitor.connect('account-removed') do |_mon, account|
        @user_trackers.delete(account)
      end
      @accounts_monitor.accounts.each { |account| add_account(account) }
    end

    def user_tracker_for_account(account)
      add_account(account)
      @user_trackers[account]
    end

    private

      def add_account(account)
        @user_trackers[account] ||= UserTracker.new(account, app: @app)
      end

      def connect_mute_actions
        { 'mute-nick' => true, 'unmute-nick' => false }.each do |name, mute|
          @app.lookup_action(name).then do |action|
            if action
              action.signal_connect('activate') { |_a, params| toggle_mute(params, mute) }
            end
          end
        end
      end

      def toggle_mute(params, mute)
        account_path, nick = params.value
        @accounts_monitor.lookup_account(account_path).then do |account|
          if account
            tracker = user_tracker_for_account(account)
            mute ? tracker.mute_nick(nick) : tracker.unmute_nick(nick)
          end
        end
      end
  end
end
