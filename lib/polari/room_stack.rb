# frozen_string_literal: true

require 'adwaita'
require_relative 'chat_view'
require_relative 'entry_area'
require_relative 'room_manager'
require_relative 'user_tracker'

module Polari
  # MessageInfoBar is the two-line info bar the chat pane overlays: a heading,
  # a subtitle, a close button, and whatever action button the subclass adds.
  #
  # Ported from the MessageInfoBar class in src/roomStack.js.
  class MessageInfoBar < Gtk::InfoBar
    def initialize(title: '', subtitle: '')
      super()
      @title = title
      @subtitle = subtitle

      self.show_close_button = true
      self.revealed = false
      self.valign = :start
    end

    def build
      tap do |bar|
        bar.add_child(box)

        box.tap do |vbox|
          vbox.append(title_label)
          vbox.append(subtitle_label)
        end

        title_label.label = @title
        subtitle_label.label = @subtitle

        bar.signal_connect('response') { |_b, response| on_response(response) }
      end
    end

    def subtitle=(text)
      @subtitle = text
      subtitle_label.label = text
    end

    def box = @box ||= Gtk::Box.new(:vertical, 0)

    def title_label
      @title_label ||= Gtk::Label.new.tap do |label|
        label.add_css_class('heading')
        label.halign = :start
        label.valign = :center
        label.wrap = true
      end
    end

    def subtitle_label
      @subtitle_label ||= Gtk::Label.new.tap do |label|
        label.halign = :start
        label.valign = :center
        label.ellipsize = :end
      end
    end

    private

      # The close button and every action hide the bar again; subclasses
      # override this to act on the response first.
      def on_response(_response)
        self.revealed = false
      end
  end

  # SavePasswordConfirmationBar offers to remember the password of an
  # identify message the user just sent by hand.
  #
  # Ported from the SavePasswordConfirmationBar class in src/roomStack.js.
  class SavePasswordConfirmationBar < MessageInfoBar
    def initialize(room)
      super(
        title:    'Should the password be saved?',
        subtitle: format(
          'Identification will happen automatically the next time you connect to %s',
          room.account.display_name,
        ),
      )
      @room = room
    end

    def build
      super.tap do |bar|
        bar.add_button('_Save Password', Gtk::ResponseType::ACCEPT).tap do |button|
          button.action_name = 'app.save-identify-password'
          button.set_action_target_value(GLib::Variant.new(@room.account.object_path))
        end

        @identify_sent_handler = @room.connect('identify-sent') { bar.revealed = true }
      end
    end

    private

      # Dismissing the bar is a decision too: the password is discarded.
      def on_response(response)
        unless response == Gtk::ResponseType::ACCEPT
          Gio::Application.default
                          .lookup_action('discard-identify-password')
                          .activate(GLib::Variant.new(@room.account.object_path))
        end
        self.revealed = false
      end
  end

  # ChannelErrorBar explains why joining a room failed, and offers a retry.
  #
  # Ported from the ChannelErrorBar class in src/roomStack.js, including the
  # mapping from the channel error to its sentence.
  class ChannelErrorBar < MessageInfoBar
    ERROR_MESSAGES = {
      'org.freedesktop.Telepathy.Error.ChannelFull'       => 'The room is full.',
      'org.freedesktop.Telepathy.Error.ChannelBanned'     => 'You have been banned from the room.',
      'org.freedesktop.Telepathy.Error.ChannelInviteOnly' => 'The room is invite-only.',
      'org.freedesktop.Telepathy.Error.ChannelKicked'     => 'You have been kicked from the room.',
    }.freeze

    DEFAULT_ERROR_MESSAGE =
      'It is not possible to join the room now, but you can retry later.'

    def initialize(room)
      super(title: 'Failed to join the room')
      @room = room
    end

    def build
      super.tap do |bar|
        bar.add_button('_Retry', Gtk::ResponseType::ACCEPT).tap do |button|
          button.action_name = 'app.reconnect-room'
          button.set_action_target_value(GLib::Variant.new(@room.id))
        end

        @room.connect('notify::channel-error') { update_from_error }
      end
    end

    private

      def update_from_error
        if @room.channel_error.to_s.empty?
          self.revealed = false
        else
          self.subtitle = ERROR_MESSAGES.fetch(@room.channel_error, DEFAULT_ERROR_MESSAGE)
          self.revealed = true
        end
      end
  end

  # ChatPlaceholder is what the chat pane shows while no room is selected.
  #
  # Ported from the ChatPlaceholder class in src/roomStack.js: the status page
  # plus an empty box in the entry size group, so the placeholder lines up
  # with the entry areas of the real rooms.
  class ChatPlaceholder < Gtk::Overlay
    def initialize(size_group)
      super()
      @size_group = size_group
    end

    def build
      tap do |overlay|
        overlay.child = status_page
        overlay.add_overlay(input_placeholder)
        @size_group.add_widget(input_placeholder)
      end
    end

    def status_page
      @status_page ||= Adwaita::StatusPage.new.tap do |page|
        page.icon_name = 'org.gnome.Polari-symbolic'
        page.title = 'Polari'
        page.description = 'Join a room using the + button.'
        page.vexpand = true
      end
    end

    def input_placeholder
      @input_placeholder ||= Gtk::Box.new(:horizontal, 0).tap do |box|
        box.valign = :end
      end
    end
  end

  # RoomView is one room's pane: the message log (with a spinner until the
  # backlog is in), the entry area at the bottom, and the info bars overlaid
  # on top.
  #
  # Ported from the RoomView class in src/roomStack.js.
  class RoomView < Gtk::Overlay
    def initialize(room, size_group, user_tracker)
      super()
      @room = room
      @size_group = size_group
      @user_tracker = user_tracker

      self.name = "RoomView #{room.display_name}"
    end

    attr_reader :room

    def build
      tap do |overlay|
        overlay.child = toolbar_view

        if @room.contact?
          overlay.add_overlay(SavePasswordConfirmationBar.new(@room).build)
        end
        overlay.add_overlay(ChannelErrorBar.new(@room).build)

        toolbar_view.tap do |view|
          view.content = loading_status
          view.add_bottom_bar(entry_area.build)
        end

        @size_group.add_widget(entry_area)
        chat_view.build
      end
    end

    def input_sensitive=(sensitive)
      entry_area.sensitive = sensitive
    end

    def show_search_inline(date)
      chat_view.show_search_inline(date)
    end

    def toolbar_view = @toolbar_view ||= Adwaita::ToolbarView.new

    def loading_status
      @loading_status ||= Adwaita::StatusPage.new.tap do |page|
        page.paintable = Adwaita::SpinnerPaintable.new(page)
      end
    end

    def chat_view
      @chat_view ||= ChatView.new(
        @room,
        user_tracker:               @user_tracker,
        on_logs_ready:              method(:on_logs_ready),
        on_max_nick_chars_changed:  method(:on_max_nick_chars_changed),
        on_text_dropped:            method(:on_text_dropped),
        on_file_dropped:            method(:on_file_dropped),
      )
    end

    def entry_area
      @entry_area ||= EntryArea.new(
        @room,
        max_nick_chars:          chat_view.max_nick_chars,
        on_confirmation_changed: method(:on_confirmation_changed),
      ).tap do |area|
        area.sensitive = false
      end
    end

    private

      def on_logs_ready
        toolbar_view.content = chat_view
      end

      def on_max_nick_chars_changed(chars)
        entry_area.max_nick_chars = chars
      end

      # A pending paste raises the bottom bar, the way upstream binds
      # confirmation-visible to the toolbar style.
      def on_confirmation_changed(visible)
        toolbar_view.bottom_bar_style = visible ? :raised : :flat
      end

      def on_text_dropped(text)
        entry_area.paste_text(text, text.to_s.lines.length)
      end

      def on_file_dropped(file)
        entry_area.paste_file(file)
      end
  end

  # RoomStack is the chat pane: one RoomView per room, plus the placeholder,
  # switched by the window's active room.
  #
  # Ported from the RoomStack class in src/roomStack.js. Upstream listens to
  # the toplevel's ::notify::active-room and ::active-room-state-changed from
  # vfunc_realize, and reports its view height through a property it notifies
  # from vfunc_size_allocate; neither hook exists for a Ruby subclass, so the
  # window drives active_room= and update_sensitivity, and view_height is
  # measured when asked.
  class RoomStack < Gtk::Stack
    def initialize(user_status_monitor: UserStatusMonitor.default, room_manager: RoomManager.default)
      super()
      @user_status_monitor = user_status_monitor
      @room_manager = room_manager
      @views = {}
      @active_room = nil

      self.transition_type = :crossfade
    end

    attr_reader :active_room

    def build
      tap do |stack|
        stack.add_named(ChatPlaceholder.new(size_group).build, 'placeholder')

        @room_manager.connect('room-added') { |_mgr, room| room_added(room) }
        @room_manager.connect('room-removed') { |_mgr, room| room_removed(room) }
        @room_manager.rooms.each { |room| room_added(room) }

        update_visible_child
      end
    end

    def size_group = @size_group ||= Gtk::SizeGroup.new(:vertical)

    def active_room=(room)
      @active_room = room
      update_visible_child
      update_sensitivity
    end

    # The entry area is only usable while the room has a channel.
    def update_sensitivity
      @active_room.then do |room|
        if room && @views[room.id]
          @views[room.id].input_sensitive = !room.channel.nil?
        end
      end
    end

    # The height the chat log gets, which is what sizes the user list
    # popover: the stack's height without the entry area.
    def view_height
      entry = size_group.widgets.find(&:mapped?)
      entry_height = entry ? entry.allocated_height - 1 : 0
      allocated_height - entry_height
    end

    def view_for_room(room) = @views[room.id]

    private

      def room_added(room)
        tracker = @user_status_monitor.user_tracker_for_account(room.account)

        RoomView.new(room, size_group, tracker).build.tap do |view|
          @views[room.id] = view
          add_named(view, room.id)
        end
      end

      def room_removed(room)
        @views.delete(room.id).then do |view|
          if view
            remove(view)
          end
        end
        update_visible_child
      end

      def update_visible_child
        name = @active_room && @views.key?(@active_room.id) ? @active_room.id : 'placeholder'
        self.visible_child_name = name
      end
  end
end
