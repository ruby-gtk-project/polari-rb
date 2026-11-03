# frozen_string_literal: true

require 'adwaita'
require_relative 'chat_view'
require_relative 'irc_parser'
require_relative 'tab_completion'
require_relative 'paste_manager'

module Polari
  # ChatEntry is the message entry: it keeps the emoji icon and completion of
  # a plain Gtk::Entry, and hands multi-line pastes, images and files on to
  # the paste confirmation instead of inserting them.
  #
  # Ported from the ChatEntry class in src/entryArea.js. Upstream reads the
  # clipboard itself to tell text from an image from a file; the Ruby bindings
  # have no async clipboard read to drive from here, so the entry watches the
  # text being inserted (which is what catches a multi-line paste) and takes
  # images and files from the drop targets.
  class ChatEntry < Gtk::Entry
    include DropTargets

    MAX_LINES = 5

    def initialize(on_text_pasted: nil, on_file_pasted: nil)
      super()
      @on_text_pasted = on_text_pasted
      @on_file_pasted = on_file_pasted

      self.hexpand = true
      self.show_emoji_icon = true
      self.enable_emoji_completion = true
    end

    def can_drop? = sensitive?

    def build
      tap do |entry|
        add_drop_targets(entry, on_text: on_text_pasted_as_drop, on_file: @on_file_pasted)

        entry.delegate.signal_connect('insert-text') do |delegate, text, _length, _position|
          on_insert_text(delegate, text)
        end

        emoji_action.then do |action|
          if action
            action.signal_connect('activate') do
              if sensitive? && mapped?
                delegate.signal_emit('insert-emoji')
              end
            end
          end
        end
      end
    end

    private

      def emoji_action
        Gio::Application.default&.lookup_action('show-emoji-picker')
      end

      # A paste of five lines or more is offered to the paste service rather
      # than pasted into the entry.
      def on_insert_text(delegate, text)
        lines = text.to_s.lines.length

        if lines >= MAX_LINES
          delegate.signal_emit_stop('insert-text')
          @on_text_pasted&.call(text, lines)
        end
      end

      def on_text_pasted_as_drop
        @on_text_pasted_as_drop ||= proc do |text|
          @on_text_pasted&.call(text, text.to_s.lines.length)
        end
      end
  end

  # NickPopover is the "Change nickname" popover behind the nick button.
  #
  # Ported from the NickPopover class in src/entryArea.js plus
  # data/ui/nick-popover.ui.
  class NickPopover < Gtk::Popover
    def initialize(on_nick_changed: nil)
      super()
      @on_nick_changed = on_nick_changed
      @nick = ''
      self.position = :top
    end

    attr_reader :nick

    def build
      tap do |popover|
        popover.child = box
        popover.default_widget = change_button

        box.tap do |vbox|
          vbox.append(prompt_label)
          vbox.append(nick_entry)
          vbox.append(change_button)
        end

        change_button.signal_connect('clicked') do
          unless nick_entry.text.empty?
            @nick = nick_entry.text
            @on_nick_changed&.call(@nick)
          end
        end
      end
    end

    def nick=(nick)
      unless nick == @nick
        unless nick_entry.has_focus?
          nick_entry.text = nick.to_s
        end
        @nick = nick
      end
    end

    def box
      @box ||= Gtk::Box.new(:vertical, 6).tap do |box|
        box.margin_start = 6
        box.margin_end = 6
        box.margin_top = 6
        box.margin_bottom = 6
      end
    end

    def prompt_label
      @prompt_label ||= Gtk::Label.new('Change nickname:').tap do |label|
        label.halign = :start
        label.hexpand = true
      end
    end

    def nick_entry
      @nick_entry ||= Gtk::Entry.new.tap do |entry|
        entry.activates_default = true
      end
    end

    def change_button
      @change_button ||= Gtk::Button.new(label: '_Change').tap do |button|
        button.receives_default = true
        button.halign = :end
        button.hexpand = true
        button.use_underline = true
        button.add_css_class('suggested-action')
      end
    end
  end

  # EntryArea is the bottom bar of a chat: the nick button, the message entry
  # and — on its second stack page — the confirmation before anything is
  # uploaded to a public paste service.
  #
  # Ported from the EntryArea class in src/entryArea.js plus
  # data/ui/entry-area.ui, including the nick column width that follows the
  # chat view's widest nick, the Escape/Backspace/Ctrl+Z shortcut that cancels
  # a pending paste, and typing anywhere in the window landing in the entry.
  class EntryArea < Gtk::Stack
    MAX_NICK_UPDATE_TIME = 5

    def initialize(room, max_nick_chars: ChatView::MAX_NICK_CHARS, on_confirmation_changed: nil)
      super()
      @room = room
      @max_nick_chars = max_nick_chars
      @on_confirmation_changed = on_confirmation_changed
      @paste_content = nil

      self.valign = :end
      self.transition_type = :crossfade
      add_css_class('polari-entry-area')
      add_css_class('view')
    end

    def confirmation_visible? = visible_child_name == 'paste-confirmation'

    def max_nick_chars=(value)
      @max_nick_chars = value
      update_nick
    end

    def build
      tap do |area|
        area.add_named(default_page, 'default')
        area.add_named(paste_box, 'paste-confirmation')

        default_page.tap do |box|
          box.append(nick_button)
          box.append(chat_entry.build)
        end

        paste_box.tap do |box|
          box.append(spinner_bin)
          box.append(upload_label)
          box.append(confirm_label)
          box.append(button_revealer)
          box.add_controller(paste_key_controller)
        end

        button_revealer.child = button_box
        button_box.tap do |box|
          box.append(cancel_button)
          box.append(paste_button)
        end

        connect_signals
        update_nick
      end
    end

    # Offers a multi-line paste to the paste service.
    def paste_text(text, lines)
      confirm_label.label = pluralize(
        lines,
        'Paste %s line of text to public paste service?',
        'Paste %s lines of text to public paste service?',
      )
      upload_label.label = pluralize(
        lines,
        'Uploading %s line of text to public paste service…',
        'Uploading %s lines of text to public paste service…',
      )
      set_paste_content(text)
    end

    def paste_image(image)
      confirm_label.label = 'Upload image to public paste service?'
      upload_label.label = 'Uploading image to public paste service…'
      set_paste_content(image)
    end

    def paste_file(file)
      name = file.query_info('standard::display-name', :none).display_name
      confirm_label.label = format('Upload “%s” to public paste service?', name)
      upload_label.label = format('Uploading “%s” to public paste service…', name)
      set_paste_content(file)
    rescue StandardError => e
      warn "Failed to read dropped file: #{e.message}"
    end

    def default_page
      @default_page ||= Gtk::Box.new(:horizontal, 6).tap do |box|
        box.margin_start = 6
        box.margin_end = 12
        box.margin_top = 12
        box.margin_bottom = 12
      end
    end

    def nick_button
      @nick_button ||= Gtk::ToggleButton.new.tap do |button|
        button.receives_default = true
        button.focus_on_click = false
        button.add_css_class('flat')
        button.add_css_class('polari-nick-button')
        button.child = nick_label
      end
    end

    def nick_label
      @nick_label ||= Gtk::Label.new.tap do |label|
        label.xalign = 0
        label.attributes = Pango::AttrList.new.tap do |attributes|
          attributes.insert(Pango::AttrWeight.new(Pango::Weight::BOLD))
        end
      end
    end

    def chat_entry
      @chat_entry ||= ChatEntry.new(
        on_text_pasted: method(:paste_text),
        on_file_pasted: method(:paste_file),
      )
    end

    def nick_popover
      @nick_popover ||= NickPopover.new(on_nick_changed: method(:set_nick)).tap(&:build)
    end

    def paste_box
      @paste_box ||= Gtk::Box.new(:horizontal, 6).tap do |box|
        box.add_css_class('background')
        box.add_css_class('polari-paste-confirmation')
      end
    end

    def spinner_bin
      @spinner_bin ||= Adwaita::Bin.new.tap do |bin|
        bin.width_request = 16
        bin.child = upload_spinner
      end
    end

    def upload_spinner
      @upload_spinner ||= Adwaita::Spinner.new.tap do |spinner|
        spinner.visible = false
      end
    end

    def upload_label
      @upload_label ||= Gtk::Label.new.tap do |label|
        label.halign = :start
        label.hexpand = true
        label.ellipsize = :end
        label.xalign = 0
        label.visible = false
      end
    end

    def confirm_label
      @confirm_label ||= Gtk::Label.new.tap do |label|
        label.halign = :start
        label.hexpand = true
        label.ellipsize = :end
        label.xalign = 0
        label.visible = false
      end
    end

    def button_revealer
      @button_revealer ||= Gtk::Revealer.new.tap do |revealer|
        revealer.transition_type = :slide_left
      end
    end

    def button_box
      @button_box ||= Gtk::Box.new(:horizontal, 6).tap do |box|
        box.valign = :center
        box.margin_end = 14
      end
    end

    def cancel_button
      @cancel_button ||= Gtk::Button.new(label: '_Cancel').tap do |button|
        button.receives_default = true
        button.use_underline = true
      end
    end

    def paste_button
      @paste_button ||= Gtk::Button.new(label: '_Paste').tap do |button|
        button.receives_default = true
        button.use_underline = true
        button.add_css_class('suggested-action')
      end
    end

    def paste_key_controller
      @paste_key_controller ||= Gtk::EventControllerKey.new.tap do |controller|
        controller.signal_connect_after('key-pressed') do |_c, keyval, _code, state|
          on_paste_key_pressed(keyval, state)
        end
      end
    end

    def irc_parser = @irc_parser ||= IrcParser.new(chat_entry, @room)
    def completion = @completion ||= TabCompletion.new(chat_entry)
    def paste_manager = @paste_manager ||= PasteManager.new

    private

      def connect_signals
        signal_connect('notify::visible-child-name') do
          @on_confirmation_changed&.call(confirmation_visible?)
          sync_confirmation_widgets
        end
        signal_connect('notify::sensitive') { on_sensitive_changed }
        signal_connect('realize') { install_toplevel_key_controller }

        nick_button.signal_connect('toggled') do
          nick_button.active? ? nick_popover.popup : nick_popover.popdown
        end
        nick_popover.signal_connect('closed') { nick_button.active = false }
        nick_popover.set_parent(nick_button)

        chat_entry.signal_connect('changed') { chat_entry.remove_css_class('error') }
        cancel_button.signal_connect('clicked') { set_paste_content(nil) }
        paste_button.signal_connect('clicked') { on_paste_clicked }

        irc_parser.build
        completion.build

        @room.connect('members-changed') { update_completions }
        @room.connect('notify::channel') { on_channel_changed }
        @room.account.connect('notify::nickname') do
          if @room.channel.nil?
            update_nick
          end
        end

        on_channel_changed
      end

      def sync_confirmation_widgets
        button_revealer.reveal_child = confirm_label.visible?
        cancel_button.sensitive = confirm_label.visible?
        paste_button.sensitive = confirm_label.visible?
        upload_label.visible = !confirm_label.visible?
      end

      # Typing anywhere in the window goes to the entry, as long as the focus
      # is not in another entry already.
      def install_toplevel_key_controller
        root.then do |toplevel|
          if toplevel
            Gtk::EventControllerKey.new.tap do |controller|
              controller.signal_connect('key-pressed') do |c, keyval, _code, state|
                on_toplevel_key_pressed(c, keyval, state)
              end
              toplevel.add_controller(controller)
            end
          end
        end
      end

      ACTIVATION_KEYS = [
        Gdk::Keyval::KEY_Tab,
        Gdk::Keyval::KEY_Return,
        Gdk::Keyval::KEY_ISO_Enter,
        Gdk::Keyval::KEY_space,
      ].freeze

      def on_toplevel_key_pressed(controller, keyval, state)
        if focus_chat_entry?(keyval, state)
          chat_entry.grab_focus_without_selecting
          controller.forward(chat_entry.delegate)
          true
        else
          false
        end
      end

      def focus_chat_entry?(keyval, state)
        can_focus_chat_entry? &&
          !Gdk::Keyval.to_unicode(keyval).zero? &&
          plain_modifier?(state) &&
          !ACTIVATION_KEYS.include?(keyval)
      end

      def plain_modifier?(state)
        state.to_i.zero? || state.to_i == Gdk::ModifierType::SHIFT_MASK.to_i
      end

      def can_focus_chat_entry?
        sensitive? &&
          chat_entry.mapped? &&
          !chat_entry.has_focus? &&
          !root&.focus.is_a?(Gtk::Entry)
      end

      def on_paste_key_pressed(keyval, state)
        cancel_keys = [Gdk::Keyval::KEY_Escape, Gdk::Keyval::KEY_BackSpace, Gdk::Keyval::KEY_Delete]
        undo = keyval == Gdk::Keyval::KEY_z &&
               !(state.to_i & Gdk::ModifierType::CONTROL_MASK.to_i).zero?

        if cancel_keys.include?(keyval) || undo
          set_paste_content(nil)
          true
        else
          false
        end
      end

      def set_paste_content(content)
        @paste_content = content

        if content
          confirm_label.visible = true
          self.visible_child_name = 'paste-confirmation'
          paste_button.grab_focus
        else
          self.visible_child_name = 'default'
          chat_entry.grab_focus_without_selecting
        end
        sync_confirmation_widgets
      end

      def on_paste_clicked
        confirm_label.visible = false
        upload_spinner.visible = true
        sync_confirmation_widgets

        begin
          url = paste_manager.paste_content(@paste_content, paste_title)
          set_paste_content(nil)
          chat_entry.delegate.signal_emit('insert-at-cursor', url)
        rescue StandardError => e
          warn "Failed to paste content of type #{@paste_content.class}: #{e.message}"
        ensure
          upload_spinner.visible = false
        end
      end

      def paste_title
        nick = @room.self_nick.to_s

        if @room.room?
          format('%s in #%s', nick, @room.display_name)
        else
          format('Paste from %s', nick)
        end
      end

      def on_sensitive_changed
        if can_focus_chat_entry?
          chat_entry.grab_focus
        end

        if sensitive?
          nick_label.add_css_class('polari-active-nick')
        else
          nick_label.remove_css_class('polari-active-nick')
        end
      end

      def on_channel_changed
        update_completions
        update_nick
      end

      def update_completions
        nicks = if chat_entry.mapped? && @room.channel
                  @room.members.map(&:alias)
                else
                  []
                end
        completion.set_completions(nicks)
      end

      def set_nick(nick)
        nick_label.width_chars = [nick.length, @max_nick_chars].max
        nick_label.label = nick
        nick_button.active = false

        if mapped?
          Gio::Application.default&.set_account_nick(@room.account, nick)

          # The account's nickname is a local property that does not
          # necessarily match the externally visible nick, and failing to
          # sync the two is not an error, so the server gets
          # MAX_NICK_UPDATE_TIME seconds before we revert to its nick.
          GLib::Timeout.add_seconds(MAX_NICK_UPDATE_TIME) do
            update_nick
            false
          end
        end
      end

      def update_nick
        nick = @room.channel ? @room.self_nick.to_s : @room.account.nickname.to_s

        nick_label.width_chars = [nick.length, @max_nick_chars].max
        nick_label.label = nick

        if mapped?
          nick_popover.nick = nick
        end
      end

      def pluralize(count, singular, plural)
        format(count == 1 ? singular : plural, count)
      end
  end
end
