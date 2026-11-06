# frozen_string_literal: true

require 'tsparql'
require 'gio2'
require 'time'
require 'fileutils'
require_relative 'message'
require_relative 'utils'

module Polari
  # SparqlStore opens the real Tracker/TinySPARQL store the chat log lives
  # in, loaded from the ontology at data/ontologies/polari.ontology and
  # queried with the statements in data/sparql/ — the same five files
  # upstream's Tracker queries answer, run here against the same store.
  #
  # Ported from the store Utils.getSparqlStore() opens in src/utils.js.
  # There used to be no Ruby binding for Tracker, so this port kept a
  # hand-rolled JSON-lines file per channel instead and re-implemented the
  # five queries' filtering, sorting and full-text matching by hand; now
  # that `tsparql` exists, the store is the real TinySPARQL connection the
  # ontology and the queries were always written for, and ChatLogStore,
  # LogWalker and LogFinder below talk to it exactly the way the C and JS
  # code do.
  class SparqlStore
    DEFAULT_GRAPH = 'polari:irc'

    # The repo root's data/ directory, which ships with the gem (see
    # polari-rb.gemspec) two levels above lib/polari.
    DATA_DIR = File.expand_path(
      File.join(
        __dir__,
        '..',
        '..',
        'data',
      ),
    )

    QUERIES = {
      room_events:         'get-room-events.rq',
      room_events_forward: 'get-room-events-forward.rq',
      count_results:       'count-results.rq',
      search_messages:     'search-messages.rq',
      context:             'get-context.rq',
    }.freeze

    def self.default = @default ||= new

    def self.reset = @default = nil

    def initialize(path: nil)
      @path = path || File.join(Utils.polari_data_dir, 'chatlogs.v2')
      @statements = {}
    end

    def connection
      @connection ||= begin
        FileUtils.mkdir_p(@path)
        Tsparql::SparqlConnection.new(
          0,
          Gio::File.new_for_path(@path),
          Gio::File.new_for_path(File.join(DATA_DIR, 'ontologies')),
          nil,
        )
      end
    end

    def insert(&block)
      batch = connection.create_batch
      yield(batch)
      batch.execute(nil)
    end

    # Runs one of the statements in data/sparql/, with `binds` applied as
    # bind_string/bind_datetime/bind_int according to each value's class,
    # and yields the cursor row by row as an array of column values (with
    # Tsparql's [value, length] string pairs already unwrapped).
    def query(name, binds = {})
      statement = statement_for(name)
      statement.clear_bindings
      binds.each { |key, value| bind(statement, key.to_s, value) }

      cursor = statement.execute(nil)
      rows = []
      while cursor.next(nil)
        rows << Array.new(cursor.n_columns) { |i| column(cursor, i) }
      end
      cursor.close
      rows
    end

    private

      def statement_for(name)
        @statements[name] ||= connection.query_statement(
          File.read(File.join(DATA_DIR, 'sparql', QUERIES.fetch(name))),
          nil,
        )
      end

      def bind(statement, key, value)
        case value
        when Time   then statement.bind_datetime(key, value)
        when Integer then statement.bind_int(key, value)
        when true, false then statement.bind_boolean(key, value)
        else statement.bind_string(key, value.to_s)
        end
      end

      def column(cursor, index)
        if !cursor.bound?(index)
          nil
        else
          case cursor.get_value_type(index)
          when Tsparql::SparqlValueType::BOOLEAN then cursor.get_boolean(index)
          when Tsparql::SparqlValueType::INTEGER then cursor.get_integer(index)
          when Tsparql::SparqlValueType::DOUBLE then cursor.get_double(index)
          else unwrap(cursor.get_string(index))
          end
        end
      end

      def unwrap(value) = value.is_a?(Array) ? value.first : value
  end

  # ChatLogStore is where the conversation log lives, keyed by the same
  # channel IRI upstream's RDF resources use.
  #
  # Ported from the parts of src/utils.js and src/lib/polari-message.c that
  # write a message into the Tracker store: append() builds the same
  # polari:Message/polari:Contact/polari:Channel/polari:Account resource
  # graph polari_message_to_tracker_resource() does, over the real
  # TinySPARQL connection in SparqlStore.
  class ChatLogStore
    def self.default = @default ||= new

    def initialize(store: SparqlStore.default)
      @store = store
    end

    # urn:channel:<account id>:<channel name>, the channel IRI every query
    # below keys on.
    def self.channel_iri(room)
      "urn:channel:#{room.account.path_suffix}:#{room.channel_name}"
    end

    def append(room, message)
      channel = channel_resource(room)

      @store.insert do |batch|
        batch.add_resource(SparqlStore::DEFAULT_GRAPH, channel)
        batch.add_resource(SparqlStore::DEFAULT_GRAPH, message_resource(channel, message))
      end
    end

    # get-room-events.rq, newest first within the one-year window upstream
    # bounds it to.
    def room_events(channel_iri, end_time)
      rows = @store.query(:room_events, channel: channel_iri, endTime: end_time)
      rows.map { |row| message_from_row(row) }
    end

    # get-room-events-forward.rq, oldest first.
    def room_events_forward(channel_iri, start_time)
      rows = @store.query(:room_events_forward, channel: channel_iri, startTime: start_time)
      rows.map { |row| message_from_row(row) }
    end

    # count-results.rq: the number of messages matching keyword, in one
    # channel (the statement groups by channel, so only the row for this
    # one is kept).
    def count_results(channel_iri, keyword)
      @store.query(:count_results, keyword: keyword)
            .find { |channel, _matches| channel == channel_iri }
            &.then { |_channel, matches| matches } || 0
    end

    # search-messages.rq: the matching messages, newest first, as the
    # {time:, sender_nick:, text:} rows the search view's rows key on.
    def search_messages(channel_iri, keyword, limit, offset)
      @store.query(
        :search_messages,
        keyword: keyword,
        channel: channel_iri,
        limit:   limit,
        offset:  offset,
      ).map { |text, sender_nick, time| simple_row(text, sender_nick, time) }
    end

    # get-context.rq: the up-to-two rows that followed one message.
    def context(channel_iri, msg_time)
      @store.query(:context, channel: channel_iri, msgTime: msg_time)
            .map { |time, sender_nick, text| simple_row(text, sender_nick, time) }
    end

    private

      def message_from_row(row)
        text, sender_nick, time, is_action, is_self = row
        Message.new(
          text:      text,
          sender:    sender_nick,
          time:      Time.iso8601(time),
          is_action: is_action == true,
          is_self:   is_self == true,
        )
      end

      def simple_row(text, sender_nick, time)
        { time: Time.iso8601(time), sender_nick: sender_nick, text: text }
      end

      def channel_resource(room)
        iri = self.class.channel_iri(room)

        Tsparql::Resource.new(iri).tap do |resource|
          resource.set_uri('rdf:type', room.room? ? 'polari:Room' : 'polari:Conversation')
          resource.set_string('polari:name', room.channel_name)
          resource.set_relation('polari:account', account_resource(room.account))
        end
      end

      def account_resource(account)
        Tsparql::Resource.new("urn:account:#{account.path_suffix}").tap do |resource|
          resource.set_uri('rdf:type', 'polari:Account')
          resource.set_string('polari:id', account.path_suffix)
        end
      end

      def message_resource(channel, message)
        Tsparql::Resource.new(nil).tap do |resource|
          resource.set_uri('rdf:type', 'polari:Message')
          resource.set_boolean('polari:isAction', message.action?)
          resource.set_datetime('polari:time', message.time)
          resource.set_string('polari:text', message.text)
          resource.set_relation('polari:sender', sender_resource(message))
          resource.set_relation('polari:channel', channel)
        end
      end

      # The ontology (data/ontologies/polari.ontology) gives polari:Contact
      # only a nick — polari:id is an Account property.
      def sender_resource(message)
        Tsparql::Resource.new(nil).tap do |resource|
          resource.set_uri('rdf:type', message.self? ? 'polari:SelfContact' : 'polari:Contact')
          resource.set_string('polari:nick', message.sender)
        end
      end
  end

  # LogWalker pages backwards (and then forwards again) through one room's
  # log, which is how the chat view fills its backlog.
  #
  # Ported from the LogWalker class in src/logger.js: get_events() runs
  # get-room-events.rq and get_events_forward() runs
  # get-room-events-forward.rq, keeping upstream's clustering rule — a run
  # of messages sharing a sender and a timestamp is never cut in half by the
  # event limit — as the one piece of _getResults() that is upstream's own
  # logic rather than the statement's.
  class LogWalker
    def initialize(room, store: ChatLogStore.default)
      @room = room
      @store = store
      @channel_iri = ChatLogStore.channel_iri(room)
      @is_end = false
    end

    def end? = @is_end

    def get_events(end_time, num_events)
      if @is_end
        []
      else
        messages = @store.room_events(@channel_iri, end_time)
        limit_messages(messages, num_events).then do |results|
          @is_end = results.length < num_events
          results.reverse
        end
      end
    end

    def get_events_forward(start_time, num_events)
      messages = @store.room_events_forward(@channel_iri, start_time)
      limit_messages(messages, num_events)
    end

    private

      # _getResults(): stop at the limit, but only where the sender or the
      # timestamp changes, so a burst stays whole.
      def limit_messages(messages, num_events)
        [].tap do |results|
          messages.each_with_index do |message, index|
            previous = results.last
            if index > num_events && breaks_cluster?(message, previous)
              break
            end
            results << message
          end
        end
      end

      def breaks_cluster?(message, previous)
        previous.nil? ||
          (message.time.to_i != previous.time.to_i &&
            (message.sender != previous.sender ||
              message.action? != previous.action?))
      end
  end

  # LogFinder answers the sidebar's "how many matches per room" and the
  # search view's "which messages matched, with the two that followed each".
  #
  # Ported from the LogFinder class in src/logger.js: count_results()
  # runs count-results.rq for every known room, fetch_results() runs
  # search-messages.rq plus get-context.rq for each hit — the real
  # fts:match full-text search, not the hand-rolled word-prefix scan this
  # port used before `tsparql` existed.
  class LogFinder
    # The room manager is only needed for count_results, which asks about
    # every known room; the search view constructs a finder without one, as
    # upstream does.
    def initialize(room_manager = nil, store: ChatLogStore.default)
      @room_manager = room_manager
      @store = store
      @cancelled = false
    end

    # Matches per room, as a Hash keyed by room — upstream keys its result
    # object by room too.
    def count_results(keyword)
      @cancelled = false

      (@room_manager ? @room_manager.rooms : []).each_with_object({}) do |room, results|
        matches = @store.count_results(ChatLogStore.channel_iri(room), keyword)
        if matches.positive? && !@cancelled
          results[room] = matches
        end
      end
    end

    # The matching messages of one room, newest first, each with up to two
    # following messages as context.
    def fetch_results(room, keyword, limit, offset)
      channel_iri = ChatLogStore.channel_iri(room)

      @store.search_messages(
        channel_iri,
        keyword,
        limit,
        offset,
      ).map do |row|
        [row, *@store.context(channel_iri, row[:time])]
      end
    end

    def cancel
      @cancelled = true
    end
  end
end
