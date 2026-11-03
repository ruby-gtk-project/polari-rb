# frozen_string_literal: true

require 'json'
require 'fileutils'

module Polari
  # Settings holds the keys of upstream's two GSettings schemas: the
  # application's own (org.gnome.Polari) and the per-account one
  # (org.gnome.Polari.Account), which upstream instantiates once per account
  # path under /org/gnome/Polari/Accounts/<id>/.
  #
  # Ported from data/org.gnome.Polari.gschema.xml. A compiled schema has to be
  # installed into the system's glib-2.0/schemas directory before GSettings
  # can read it, and requiring an install step to run the port from a checkout
  # is worse than the alternative, so the same keys, defaults and semantics
  # are backed by a JSON file under XDG_CONFIG_HOME — the choice the pilot
  # port made for the same reason.
  class Settings
    SCHEMA_ID = 'org.gnome.Polari'
    ACCOUNT_SCHEMA_ID = 'org.gnome.Polari.Account'

    DEFAULTS = {
      'saved-channel-list'   => [],
      'run-in-background'    => false,
      'window-width'         => 800,
      'window-height'        => 500,
      'window-maximized'     => false,
      'last-selected-channel' => {},
    }.freeze

    ACCOUNT_DEFAULTS = {
      'identify-botname'             => 'NickServ',
      'identify-command'             => 'identify',
      'identify-username'            => '',
      'identify-username-supported'  => false,
      'muted-usernames'              => [],
    }.freeze

    class << self
      def default = @default ||= new

      # The per-account settings upstream reaches through
      # /org/gnome/Polari/Accounts/<path suffix>/.
      def for_account(path_suffix)
        @accounts ||= {}
        @accounts[path_suffix] ||= new(
          defaults: ACCOUNT_DEFAULTS,
          schema:   ACCOUNT_SCHEMA_ID,
          path:     File.join(config_dir, 'accounts', "#{path_suffix}.json"),
        )
      end

      def config_dir
        File.join(
          ENV.fetch('XDG_CONFIG_HOME', File.expand_path('~/.config')),
          'polari-rb',
        )
      end

      # Lets the specs and the test instance point the whole settings tree at
      # a scratch directory.
      def reset
        @default = nil
        @accounts = nil
      end
    end

    attr_reader :schema, :location

    def initialize(defaults: DEFAULTS, schema: SCHEMA_ID, path: nil)
      @defaults = defaults
      @schema = schema
      @location = path || File.join(self.class.config_dir, 'settings.json')
      @values = @defaults.merge(read)
    end

    def [](key) = @values.fetch(key.to_s, @defaults[key.to_s])

    def []=(key, value)
      @values[key.to_s] = value
      write
      value
    end

    def reset(key)
      @values[key.to_s] = @defaults[key.to_s]
      write
      @values[key.to_s]
    end

    def keys = @defaults.keys

    # Named accessors for every key, so callers do not repeat the strings:
    # run_in_background, run_in_background=, run_in_background? and so on.
    (DEFAULTS.keys | ACCOUNT_DEFAULTS.keys).each do |key|
      name = key.tr('-', '_')
      define_method(name) { self[key] }
      define_method(:"#{name}=") { |value| self[key] = value }
      define_method(:"#{name}?") { self[key] == true }
    end

    # Restores the window geometry the previous run recorded, the way
    # upstream's bindings on default-width/default-height/maximized do.
    def apply_to(window)
      window.set_default_size(self['window-width'], self['window-height'])
      if self['window-maximized']
        window.maximize
      end
    end

    def remember(window)
      self['window-maximized'] = window.maximized?
      unless window.maximized?
        @values['window-width'] = window.default_width
        @values['window-height'] = window.default_height
        write
      end
    end

    private

      def read
        if File.exist?(@location)
          JSON.parse(File.read(@location))
        else
          {}
        end
      rescue JSON::ParserError => e
        warn "Error parsing #{@location}: #{e.message}"
        {}
      end

      def write
        FileUtils.mkdir_p(File.dirname(@location))
        File.write(@location, JSON.pretty_generate(@values))
      end
  end
end
