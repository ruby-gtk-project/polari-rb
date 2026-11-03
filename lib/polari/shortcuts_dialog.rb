# frozen_string_literal: true

require 'adwaita'

module Polari
  # ShortcutsDialog lists the keyboard shortcuts, in the two sections
  # upstream groups them in.
  #
  # Ported from data/ui/shortcuts-dialog.ui: an AdwShortcutsDialog with a
  # General and a Navigation section. Most items name an action rather than an
  # accelerator, and Adwaita shows whatever accelerator the application
  # installed for it (see Application#install_accels); the two that are not
  # actions carry their accelerator directly, as upstream does.
  class ShortcutsDialog < Adwaita::ShortcutsDialog
    SECTIONS = {
      'General'    => [
        ['Join Room', action: 'app.show-join-dialog'],
        ['Leave Room', action: 'app.leave-current-room'],
        ['Show Userlist', action: 'app.user-list'],
        ['Toggle Search', action: 'app.search'],
        ['Show Emoji Picker', action: 'app.show-emoji-picker'],
        ['Show Help', action: 'app.help'],
        ['Open Menu', accelerator: 'F10'],
        ['Quit', action: 'app.quit'],
        ['Keyboard Shortcuts', action: 'app.shortcuts-dialog'],
      ],
      'Navigation' => [
        ['Next Room', action: 'app.next-room'],
        ['Previous Room', action: 'app.previous-room'],
        ['Next Room with Unread Messages', action: 'app.next-pending-room'],
        ['Previous Room with Unread Messages', action: 'app.previous-pending-room'],
        ['First Room', action: 'app.first-room'],
        ['Last Room', action: 'app.last-room'],
        ['First – Ninth Room', accelerator: '<Alt>1...9'],
      ],
    }.freeze

    def initialize
      super()
      self.title = 'Keyboard Shortcuts'
    end

    def build
      tap do |dialog|
        SECTIONS.each do |title, items|
          dialog.add(section(title, items))
        end
      end
    end

    private

      def section(title, items)
        Adwaita::ShortcutsSection.new.tap do |section|
          section.title = title
          items.each { |(label, options)| section.add(item(label, **options)) }
        end
      end

      # Adwaita::ShortcutsItem takes its title and accelerator positionally,
      # and neither may be nil — an action-driven item therefore starts with
      # an empty accelerator and gets the action set afterwards.
      def item(label, action: nil, accelerator: '')
        Adwaita::ShortcutsItem.new(label, accelerator).tap do |shortcut|
          if action
            shortcut.action_name = action
          end
        end
      end
  end
end
