# frozen_string_literal: true

require 'rexml/document'
require_relative 'logger'
require_relative 'utils'

module Polari
  # TplImporter brings the chat logs telepathy-logger wrote for the old GJS
  # Polari (and for any other Telepathy client against telepathy-idle) into
  # the Tracker/TinySPARQL store ChatLogStore and LogWalker now read from.
  #
  # Ported from src/lib/polari-tpl-importer.c: collect_log_files() finds
  # every telepathy-idle account directory (every "idle_irc_*" directory
  # under $TPL_LOG_DIR/TpLogger/logs, or ~/.local/share/TpLogger/logs when
  # that variable is unset or its directory does not exist) and every log
  # file beneath it; get_channel_and_account_info() reads the account id,
  # the channel name and whether it was a room from a file's path, exactly
  # the way telepathy-idle laid those directories out ("chatrooms" in the
  # path means the channel one level down is a room, and the account id is
  # the "_"-joined form of the three-segment object path Account#path_suffix
  # already uses); and the GMarkup handlers in tpl_log_start_element_handler
  # etc. are the REXML walk over each <message> element below.
  class TplImporter
    ACCOUNT_DIR_PREFIX = 'idle_irc_'

    TIME_PATTERN = /\A(\d{4})(\d{2})(\d{2})(?:T(\d{2}):(\d{2}):(\d{2}))?\z/

    def initialize(store: SparqlStore.default)
      @store = store
    end

    # $TPL_LOG_DIR/TpLogger/logs when that directory exists, otherwise
    # ~/.local/share/TpLogger/logs — collect_files_thread_func()'s fallback.
    def self.default_log_root
      env_root = ENV['TPL_LOG_DIR']
      if env_root && Dir.exist?(File.join(env_root, 'TpLogger', 'logs'))
        File.join(env_root, 'TpLogger', 'logs')
      else
        File.join(Utils.user_data_dir, 'TpLogger', 'logs')
      end
    end

    # Every log file under every "idle_irc_*" directory of root.
    def collect_files(root = self.class.default_log_root)
      if Dir.exist?(root)
        Dir.children(root)
           .select { |name| name.start_with?(ACCOUNT_DIR_PREFIX) }
           .flat_map { |name| Dir.glob(
             File.join(
               root,
               name,
               '**',
               '*',
             ),
           ) }
           .select { |path| File.file?(path) }
      else
        []
      end
    end

    # Imports every log file under root, one batch per file.
    def import_all(root = self.class.default_log_root)
      collect_files(root).each { |path| import(path) }
    end

    # Imports one telepathy-idle log file.
    def import(path)
      account_id, channel_name, is_room = channel_and_account_info(path)
      channel = channel_resource(account_id, channel_name, is_room)
      document = REXML::Document.new(File.read(path))

      @store.insert do |batch|
        batch.add_resource(SparqlStore::DEFAULT_GRAPH, channel)
        document.elements.each('log/message') do |element|
          batch.add_resource(SparqlStore::DEFAULT_GRAPH, message_resource(element, channel))
        end
      end
    end

    private

      # get_channel_and_account_info(): the channel name is the log file's
      # directory, the account id is the directory above that — two levels
      # up when it is "chatrooms", which is how telepathy-idle marks a room.
      def channel_and_account_info(path)
        parent = File.dirname(path)
        channel_name = File.basename(parent)
        above = File.dirname(parent)
        account_dir = File.basename(above)

        if account_dir == 'chatrooms'
          [File.basename(File.dirname(above)).tr('_', '/'), channel_name, true]
        else
          [account_dir.tr('_', '/'), channel_name, false]
        end
      end

      def message_resource(element, channel)
        attrs = element.attributes

        Tsparql::Resource.new(nil).tap do |resource|
          resource.set_uri('rdf:type', 'polari:Message')
          resource.set_boolean('polari:isAction', attrs['type'] == 'action')
          resource.set_string('polari:text', element.text.to_s)
          resource.set_relation('polari:channel', channel)
          resource.set_relation('polari:sender', sender_resource(attrs))

          parse_time(attrs['time']).then do |time|
            if time
              resource.set_datetime('polari:time', time)
            end
          end
        end
      end

      def sender_resource(attrs)
        Tsparql::Resource.new(nil).tap do |resource|
          resource.set_uri('rdf:type', attrs['isuser'] == 'true' ? 'polari:SelfContact' : 'polari:Contact')
          resource.set_string('polari:nick', attrs['name'].to_s)
        end
      end

      def channel_resource(account_id, channel_name, is_room)
        iri = "urn:channel:#{account_id}:#{channel_name.downcase}"

        Tsparql::Resource.new(iri).tap do |resource|
          resource.set_uri('rdf:type', is_room ? 'polari:Room' : 'polari:Conversation')
          resource.set_string('polari:name', channel_name)
          resource.set_relation('polari:account', account_resource(account_id))
        end
      end

      def account_resource(account_id)
        Tsparql::Resource.new("urn:account:#{account_id}").tap do |resource|
          resource.set_uri('rdf:type', 'polari:Account')
          resource.set_string('polari:id', account_id)
        end
      end

      # parse_time_string(): "yyyymmddThh:mm:ss", or just the date.
      def parse_time(str)
        TIME_PATTERN.match(str.to_s).then do |match|
          if match
            year, month, day, hour, min, sec = match.captures.map { |v| v.to_i }
            Time.utc(
              year,
              month,
              day,
              hour,
              min,
              sec,
            )
          end
        end
      end
  end
end
