# frozen_string_literal: true

require_relative 'rb/version'

# The part of Polari that loads without a display.
#
# This file exists because `require 'gtk4'` initialises GTK at require time
# and raises Gtk::InitError when there is no display server, so anything
# that reaches a widget class cannot be loaded by a plain `ruby -e` or by a
# test process on a headless machine. The split is along that line and no
# other:
#
#   require 'polari/rb'   the models and the settings, accounts and room
#                         managers — no gtk4, no adwaita, loadable anywhere;
#   require 'polari'      all of the above plus every widget, the
#                         application, and the pieces that reach `utils.rb`
#                         (the Tracker-backed log store, the TPL importer),
#                         which pulls in `adwaita` for its toast helper and
#                         so needs a display.
#
# It is also the file the gem's version constant lives under, which is why
# spec/spec_helper.rb requires it: the specs for the display-free half need
# nothing more, and the ones that drive widgets ask for 'polari' themselves.
require_relative 'signals'
require_relative 'util'
require_relative 'message'
require_relative 'settings'
require_relative 'networks_manager'
require_relative 'accounts_monitor'
require_relative 'room'
require_relative 'room_manager'
require_relative 'user_tracker'
