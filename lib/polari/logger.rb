# frozen_string_literal: true

require 'json'
require 'time'
require 'fileutils'
require_relative 'message'
require_relative 'utils'

module Polari
  # ChatLogStore is where the conversation log lives: one JSON-lines file per
  # channel, under the same data directory and with the same per-message
  # fields as the RDF resources upstream writes
  # (data/ontologies/polari.ontology, kept beside this port's data files).
  #
  # Upstream's log lives in a Tracker SPARQL store, queried with the five
  # statements in data/sparql/. Tracker has no Ruby bindings here, so the
  # walker and finder below answer the same questions against the file store;
  # the queries are kept in data/sparql/ because they are the specification
  # the answers have to match, down to the ordering and the one-year lower
  # bound in get-room-events.rq.
  class ChatLogStore
    def self.default = @default ||= new

    def initialize(path: nil)
      @path = path || File.join(Utils.polari_data_dir, 'chatlogs.v1')
    end

    attr_reader :path

    # urn:channel:<account id>:<channel name>, the channel IRI the walker and
    # the finder key on.
    def self.channel_iri(room)
      "urn:channel:#{room.account.path_suffix}:#{room.channel_name}"
    end

    def append(room, message)
      entry = message.to_log_entry(
        account_id:   room.account.path_suffix,
        channel_name: room.channel_name,
        is_room:      room.room?,
      )

      File.open(log_file(self.class.channel_iri(room)), 'a') do |file|
        file.puts(JSON.generate(entry))
      end
    end

    # Every logged entry of a channel, oldest first, as {time:, sender_nick:,
    # text:, is_action:, is_self:} rows — the columns the SPARQL statements
    # select.
    def rows(channel_iri)
      file = log_file(channel_iri)

      if File.exist?(file)
        File.readlines(file).filter_map { |line| row_from(line) }
      else
        []
      end
    end

    # Every channel that has a log, as its IRI.
    def channel_iris
      Dir.glob(File.join(@path, '*.jsonl')).map do |file|
        File.basename(file, '.jsonl').then { |name| unescape(name) }
      end
    end

    private

      def row_from(line)
        entry = JSON.parse(line)
        sender = entry.fetch('polari:sender', {})

        {
          time:        Time.iso8601(entry['polari:time']),
          sender_nick: sender['polari:nick'],
          text:        entry['polari:text'],
          is_action:   entry['polari:isAction'] ? true : false,
          is_self:     sender['type'] == 'polari:SelfContact',
        }
      rescue JSON::ParserError, ArgumentError, TypeError
        nil
      end

      def log_file(channel_iri)
        FileUtils.mkdir_p(@path)
        File.join(@path, "#{escape(channel_iri)}.jsonl")
      end

      def escape(iri) = iri.gsub(/[^A-Za-z0-9._:-]/) { |c| format('%%%02X', c.ord) }

      def unescape(name) = name.gsub(/%([0-9A-F]{2})/) { Regexp.last_match(1).hex.chr }
  end

  # LogWalker pages backwards (and then forwards again) through one room's
  # log, which is how the chat view fills its backlog.
  #
  # Ported from the LogWalker class in src/logger.js, over the file store
  # above instead of Tracker: get_events() answers get-room-events.rq
  # (messages before a time, newest first, within a year, returned oldest
  # first), get_events_forward() answers get-room-events-forward.rq, and both
  # keep upstream's clustering rule — a run of messages sharing a sender and a
  # timestamp is never cut in half by the event limit.
  class LogWalker
    ONE_YEAR = 60 * 60 * 24 * 365

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
        rows_before(end_time).then do |rows|
          limit_rows(rows, num_events).then do |results|
            @is_end = results.length < num_events
            results.reverse.map { |row| message_from(row) }
          end
        end
      end
    end

    def get_events_forward(start_time, num_events)
      rows_after(start_time).then do |rows|
        limit_rows(rows, num_events).map { |row| message_from(row) }
      end
    end

    private

      # get-room-events.rq: time < endTime and time > endTime - 1y, newest
      # first.
      def rows_before(end_time)
        after = end_time - ONE_YEAR

        @store.rows(@channel_iri)
              .select { |row| row[:time] < end_time && row[:time] > after }
              .sort_by { |row| row[:time] }
              .reverse
      end

      # get-room-events-forward.rq: time > startTime, oldest first.
      def rows_after(start_time)
        @store.rows(@channel_iri)
              .select { |row| row[:time] > start_time }
              .sort_by { |row| row[:time] }
      end

      # _getResults(): stop at the limit, but only where the sender or the
      # timestamp changes, so a burst stays whole.
      def limit_rows(rows, num_events)
        results = []

        rows.each_with_index do |row, index|
          previous = results.last
          if index > num_events && breaks_cluster?(row, previous)
            break
          end
          results << row
        end
        results
      end

      def breaks_cluster?(row, previous)
        previous.nil? ||
          (row[:time] != previous[:time] &&
            (row[:sender_nick] != previous[:sender_nick] ||
              row[:is_action] != previous[:is_action]))
      end

      def message_from(row)
        Message.new(
          text:      row[:text],
          sender:    row[:sender_nick],
          time:      row[:time],
          is_action: row[:is_action],
          is_self:   row[:is_self],
        )
      end
  end

  # LogFinder answers the sidebar's "how many matches per room" and the
  # search view's "which messages matched, with the two that followed each".
  #
  # Ported from the LogFinder class in src/logger.js: count_results() answers
  # count-results.rq, fetch_results() answers search-messages.rq plus
  # get-context.rq for each hit. Tracker's fts:match is a full-text match on
  # word prefixes, which is what term_match? implements.
  class LogFinder
    CONTEXT_SIZE = 2

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
        matches = matching_rows(ChatLogStore.channel_iri(room), keyword).length
        if matches.positive? && !@cancelled
          results[room] = matches
        end
      end
    end

    # The matching messages of one room, newest first, each with up to two
    # following messages as context.
    def fetch_results(room, keyword, limit, offset)
      channel_iri = ChatLogStore.channel_iri(room)
      rows = @store.rows(channel_iri).sort_by { |row| row[:time] }

      matching_rows(channel_iri, keyword)
        .sort_by { |row| row[:time] }
        .reverse
        .drop(offset)
        .take(limit)
        .map { |row| [row, *context_for(rows, row)] }
    end

    def cancel
      @cancelled = true
    end

    private

      # get-context.rq: the next two messages of the same channel.
      def context_for(rows, row)
        rows.select { |candidate| candidate[:time] > row[:time] }.take(CONTEXT_SIZE)
      end

      def matching_rows(channel_iri, keyword)
        terms = keyword.to_s.downcase.split(/\s+/).reject(&:empty?)

        if terms.empty?
          []
        else
          @store.rows(channel_iri).select do |row|
            terms.all? { |term| term_match?(row[:text], term) }
          end
        end
      end

      # fts:match semantics: a term matches a word that starts with it.
      def term_match?(text, term)
        text.to_s.downcase.split(/[^[:alnum:]]+/).any? do |word|
          word.start_with?(term)
        end
      end
  end
end
