# frozen_string_literal: true

require 'json'
require 'fileutils'
require 'net/http'
require 'uri'
require 'adwaita'

module Polari
  # Utils holds the free functions upstream keeps in src/utils.js: finding
  # URLs and channel references in message text, opening a link (with the
  # "Failed to open link" toast when that fails), formatting timestamps and
  # elapsed time, the one-time-action marker files, and the password storage
  # the identify commands use.
  #
  # Ported from src/utils.js. Two deliberate substitutions:
  #
  #   * passwords live in a 0600 JSON file under XDG_DATA_HOME instead of
  #     libsecret, which has no Ruby bindings here. The schemas, attributes
  #     and lookup semantics are upstream's, so the keyring can be swapped
  #     back in without touching the callers.
  #   * the paste helpers talk to the same two services over Net::HTTP
  #     instead of libsoup, and getSparqlStore() has no counterpart because
  #     the port's chat log is a file store (see logger.rb).
  module Utils
    # http://daringfireball.net/2010/07/improved_regex_for_matching_urls
    BALANCED_PARENS = '\([^\s()<>]+\)'
    LEADING_JUNK = "[\\s`(\\[{'\"<«“‘]"
    NOT_TRAILING_JUNK = "[^\\s`!()\\[\\]{};:'\".,<>?«»“”‘’]"

    # Schemes that only use a colon cannot be matched generically without a
    # lot of false positives, so upstream whitelists the useful ones.
    SCHEME_WHITELIST = %w[geo mailto man info ghelp help].freeze

    URL_REGEXP = Regexp.new(
      "(^|#{LEADING_JUNK})" \
      '(' \
      '(?:' \
      '(?:[a-z]+)://' \
      '|' \
      "(?:#{SCHEME_WHITELIST.join('|')}):" \
      '|' \
      'www\d{0,3}[.]' \
      '|' \
      '[a-z0-9.\-]+[.][a-z]{2,4}/' \
      ')' \
      "(?:[^\\s()<>]+|#{BALANCED_PARENS})+" \
      "(?:#{BALANCED_PARENS}|#{NOT_TRAILING_JUNK})" \
      ')',
      Regexp::IGNORECASE,
    )

    CHANNEL_REGEXP = /(^| )#([\w+.-]+)/

    SECRET_SCHEMA_ACCOUNT = 'org.gnome.Polari.Account'
    SECRET_SCHEMA_IDENTIFY = 'org.gnome.Polari.Identify'

    TIME_SPAN_DAY = 86_400

    GPASTE_BASEURL = 'https://paste.gnome.org/'

    # Silly paste.gnome.org limitation: the visible title is even more
    # limited than the 30-character hard limit.
    MAX_PASTE_TITLE_LENGTH = 25

    IMGUR_CLIENT_ID = '4109e59177ec95e'

    # Raised when a paste service answers with something unusable.
    class PasteError < StandardError; end

    # A URL (or IRC channel reference) found in message text: the text as it
    # appears in the message, the URL to open, and the character offset.
    UrlMatch = Data.define(:name, :url, :pos)

    module_function

    def flatpak_sandbox? = File.exist?('/.flatpak-info')

    def user_data_dir
      ENV.fetch('XDG_DATA_HOME', File.expand_path('~/.local/share'))
    end

    def polari_data_dir = File.join(user_data_dir, 'polari')

    # Creates the file, and raises Errno::EEXIST when it is already there —
    # which is how needs_onetime_action? tells a first run from a later one.
    def touch_file(path)
      FileUtils.mkdir_p(File.dirname(path))
      File.open(path, File::WRONLY | File::CREAT | File::EXCL).close
      path
    end

    # Whether the named one-time action still has to run. The marker file is
    # created on the first call, so later calls answer false.
    def needs_onetime_action?(name)
      path = File.join(polari_data_dir, "#{name}-completed")
      begin
        touch_file(path)
        true
      rescue Errno::EEXIST
        false
      rescue SystemCallError => e
        warn "Failed to mark onetime action #{name} as completed: #{e.message}"
        true
      end
    end

    def find_urls(text)
      each_match(URL_REGEXP, text).map do |match|
        name = match[2]
        UrlMatch.new(
          name: name,
          url:  scheme?(name) ? name : "http://#{name}",
          pos:  match.begin(0) + match[1].length,
        )
      end
    end

    def find_channels(text, server)
      each_match(CHANNEL_REGEXP, text).map do |match|
        UrlMatch.new(
          name: "##{match[2]}",
          url:  "irc://#{server}/#{match[2]}",
          pos:  match.begin(0) + match[1].length,
        )
      end
    end

    # The JS regexps are global, and are stepped with exec() until they stop
    # matching; this walks a Ruby regexp over the string the same way.
    def each_match(regexp, text)
      matches = []
      string = text.to_s
      offset = 0

      while (match = regexp.match(string, offset))
        matches << match
        offset = match.end(0)
      end
      matches
    end

    def scheme?(text) = text.to_s.match?(/\A[a-z][a-z0-9+.\-]*:/i)

    # Opens a link, and tells the user with a toast when that failed —
    # upstream's openURL(), including the toast's wording.
    def open_url(url)
      app = Gio::Application.default
      window = app.respond_to?(:active_window) ? app.active_window : nil

      Gtk::UriLauncher.new(url).launch(window, nil) do |launcher, result|
        begin
          launcher.launch_finish(result)
        rescue StandardError => e
          warn "Failed to open #{url}: #{e.message}"
          show_failed_link_toast(window)
        end
      end
    end

    def show_failed_link_toast(window)
      if window.respond_to?(:add_toast)
        window.add_toast(Adwaita::Toast.new('Failed to open link'))
      end
    end

    # Replaces the contents of +terms+ with the words of +text+, and answers
    # whether that changed anything — the search views re-query only when it
    # did.
    def update_terms(terms, text)
      normalized = text.to_s.strip.downcase.gsub(/\s+/, ' ')
      new_terms = normalized.empty? ? [] : normalized.split(' ')
      changed = new_terms != terms

      if changed
        terms.replace(new_terms)
      end
      changed
    end

    # Markup-escapes text for the labels that use Pango markup (the window
    # subtitle builds links out of the channel topic). GLib's own
    # markup_escape_text is not bound in the Ruby bindings.
    def markup_escape_text(text)
      text.to_s
          .gsub('&', '&amp;')
          .gsub('<', '&lt;')
          .gsub('>', '&gt;')
          .gsub('"', '&quot;')
          .gsub("'", '&apos;')
    end

    # "Now", "Unavailable", "%d minutes ago" … — the ladder upstream uses for
    # the last-activity line in /WHOIS output and the user popovers.
    def format_time_passed(seconds)
      count = seconds.to_i
      if seconds.nil? || seconds.to_s.empty?
        'Unavailable'
      elsif count.zero?
        'Now'
      else
        format_elapsed(count)
      end
    end

    def format_elapsed(seconds)
      minutes = seconds / 60
      hours = minutes / 60
      days = hours / 24

      if seconds < 60
        pluralize(seconds, 'second')
      elsif minutes < 60
        pluralize(minutes, 'minute')
      elsif hours < 24
        pluralize(hours, 'hour')
      else
        format_elapsed_days(days)
      end
    end

    def format_elapsed_days(days)
      if days < 7
        pluralize(days, 'day')
      elsif days < 30
        pluralize(days / 7, 'week')
      else
        pluralize(days / 30, 'month')
      end
    end

    def pluralize(count, unit)
      if count == 1
        "#{count} #{unit} ago"
      else
        "#{count} #{unit}s ago"
      end
    end

    # The timestamp format the chat view inserts between messages: time only
    # for today, "Yesterday, …", the weekday this week, and progressively
    # more of the date further back. Honours the desktop's clock-format.
    def format_date_time(time)
      now = Time.now
      days_ago = (midnight(now) - midnight(time)) / TIME_SPAN_DAY

      if clock_format == '24h'
        time.strftime(format_24h(time, now, days_ago))
      else
        time.strftime(format_12h(time, now, days_ago))
      end
    end

    def midnight(time) = Time.new(time.year, time.month, time.day, 0, 1, 0)

    def clock_format
      schema = Gio::SettingsSchemaSource.default.lookup('org.gnome.desktop.interface', true)
      if schema
        Gio::Settings.new('org.gnome.desktop.interface').get_string('clock-format')
      else
        '24h'
      end
    end

    def format_24h(time, now, days_ago)
      if days_ago < 1
        "%H∶%M"
      elsif days_ago < 2
        "Yesterday, %H∶%M"
      elsif days_ago < 7
        "%A, %H∶%M"
      elsif time.year == now.year
        "%B %d, %H∶%M"
      else
        "%B %d %Y, %H∶%M"
      end
    end

    def format_12h(time, now, days_ago)
      if days_ago < 1
        "%l∶%M %p"
      elsif days_ago < 2
        "Yesterday, %l∶%M %p"
      elsif days_ago < 7
        "%A, %l∶%M %p"
      elsif time.year == now.year
        "%B %d, %l∶%M %p"
      else
        "%B %d %Y, %l∶%M %p"
      end
    end

    # Uploads text to paste.gnome.org and answers the URL of the paste.
    #
    # The expiry is asked of the server once and the value closest to a day
    # is picked, and the title is cut down to the server's limit — both
    # upstream's _getGpasteExpire() and gpaste().
    def gpaste(text, title)
      @gpaste_expire ||= fetch_gpaste_expire
      short_title = title.to_s.length > MAX_PASTE_TITLE_LENGTH ? "#{title[0, MAX_PASTE_TITLE_LENGTH - 1]}…" : title

      post_form(
        "#{GPASTE_BASEURL}api/json/create",
        { 'title' => short_title, 'data' => text, 'expire' => @gpaste_expire, 'language' => 'text' },
      ).then do |info|
        info.dig('result', 'id').then do |id|
          if id.nil?
            raise PasteError, 'Paste server did not return a URL'
          end
          "#{GPASTE_BASEURL}#{id}"
        end
      end
    end

    # Uploads a PNG image (the bytes, as #gpaste takes the text) to imgur and
    # answers the link — upstream's imgurPaste().
    def imgur_paste(png_data, title)
      post_form(
        'https://api.imgur.com/3/image',
        { 'title' => title.to_s, 'image' => [png_data].pack('m0') },
        headers: { 'Authorization' => "Client-ID #{IMGUR_CLIENT_ID}" },
      ).then do |info|
        unless info['success']
          raise PasteError, 'Failed to upload image to paste service'
        end
        info.dig('data', 'link')
      end
    end

    def fetch_gpaste_expire
      day = 24 * 60 * 60
      values = get_json("#{GPASTE_BASEURL}api/json/parameter/expire").dig('result', 'values')

      if values.nil?
        raise PasteError, 'Returned data is missing expected fields'
      end

      values.map(&:to_i).min_by { |value| (day - value).abs }.to_s
    end

    def get_json(url)
      Net::HTTP.get_response(URI.parse(url)).then do |response|
        check_response(response)
        JSON.parse(response.body)
      end
    end

    def post_form(url, params, headers: {})
      uri = URI.parse(url)

      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https') do |http|
        request = Net::HTTP::Post.new(uri)
        headers.each { |name, value| request[name] = value }
        request.set_form_data(params)

        http.request(request).then do |response|
          check_response(response)
          JSON.parse(response.body)
        end
      end
    end

    def check_response(response)
      unless response.is_a?(Net::HTTPOK)
        raise PasteError, "Unexpected response: #{response.message}"
      end
    end

    def store_account_password(account, password)
      store_password(SECRET_SCHEMA_ACCOUNT, account, password)
    end

    def store_identify_password(account, password)
      store_password(SECRET_SCHEMA_IDENTIFY, account, password)
    end

    def lookup_account_password(account) = lookup_password(SECRET_SCHEMA_ACCOUNT, account)
    def lookup_identify_password(account) = lookup_password(SECRET_SCHEMA_IDENTIFY, account)
    def clear_account_password(account) = clear_password(SECRET_SCHEMA_ACCOUNT, account)
    def clear_identify_password(account) = clear_password(SECRET_SCHEMA_IDENTIFY, account)

    def keyring_path = File.join(polari_data_dir, 'passwords.json')

    def read_keyring
      if File.exist?(keyring_path)
        JSON.parse(File.read(keyring_path))
      else
        {}
      end
    rescue JSON::ParserError => e
      warn "Failed to read stored passwords: #{e.message}"
      {}
    end

    def write_keyring(passwords)
      FileUtils.mkdir_p(File.dirname(keyring_path))
      File.write(keyring_path, JSON.pretty_generate(passwords))
      File.chmod(0o600, keyring_path)
    end

    def store_password(schema, account, password)
      read_keyring.then do |passwords|
        passwords[schema] ||= {}
        passwords[schema][account.path_suffix] = password
        write_keyring(passwords)
      end
    end

    def lookup_password(schema, account)
      read_keyring.dig(schema, account.path_suffix)
    end

    def clear_password(schema, account)
      read_keyring.then do |passwords|
        passwords.fetch(schema, {}).delete(account.path_suffix)
        write_keyring(passwords)
      end
    end
  end
end
