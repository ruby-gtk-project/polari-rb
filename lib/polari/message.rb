# frozen_string_literal: true

require 'time'

module Polari
  # Message is one line of a conversation: its text, who sent it, when, and
  # whether it is an action (/me) or came from us.
  #
  # Ported from src/lib/polari-message.c. Upstream's boxed type carries the
  # same five fields plus two conversions: one from a TpMessage, and
  # polari_message_to_tracker_resource() for the search index. There is no
  # Telepathy and no Tracker here, so the conversions this port needs are to
  # and from the chat-log store in logger.rb — to_log_entry() keeps the shape
  # of the RDF resource upstream writes (data/ontologies/polari.ontology), so
  # the two stay interchangeable.
  class Message
    attr_reader :text, :sender, :time
    # The pending-message id the transport assigned, when the message is
    # still unacknowledged. The chat view keeps a buffer mark per pending id.
    attr_accessor :pending_id

    def initialize(text:, sender:, time:, is_action: false, is_self: false)
      @text = text.to_s
      @sender = sender.to_s
      @time = time
      @is_action = is_action
      @is_self = is_self
      @pending_id = nil
    end

    def action? = @is_action
    def self? = @is_self

    def copy
      Message.new(
        text:      @text,
        sender:    @sender,
        time:      @time,
        is_action: @is_action,
        is_self:   @is_self,
      )
    end

    # Upstream compares logged messages against the channel's pending ones
    # field by field to drop the duplicates; this is that comparison.
    def ==(other)
      other.is_a?(Message) &&
        text == other.text &&
        sender == other.sender &&
        time.to_i == other.time.to_i &&
        action? == other.action? &&
        self? == other.self?
    end
    alias eql? ==

    def hash = [text, sender, time.to_i, action?, self?].hash

    # The log-store form of create_sender_resource/create_channel_resource:
    # the message, its sender and the channel it belongs to, with the same
    # field names as the polari: ontology.
    def to_log_entry(account_id:, channel_name:, is_room: true)
      {
        'type' => 'polari:Message',
        'polari:isAction' => action?,
        'polari:time' => time.utc.iso8601,
        'polari:text' => text,
        'polari:sender' => {
          'type' => self? ? 'polari:SelfContact' : 'polari:Contact',
          'polari:nick' => sender,
          'polari:id' => sender.downcase,
        },
        'polari:channel' => {
          'type' => is_room ? 'polari:Room' : 'polari:Conversation',
          'polari:name' => channel_name,
          'polari:account' => {
            'type' => 'polari:Account',
            'polari:id' => account_id,
          },
        },
      }
    end

    def self.from_log_entry(entry)
      sender = entry.fetch('polari:sender', {})
      new(
        text:      entry['polari:text'],
        sender:    sender['polari:nick'],
        time:      Time.iso8601(entry['polari:time']),
        is_action: entry['polari:isAction'] ? true : false,
        is_self:   sender['type'] == 'polari:SelfContact',
      )
    end
  end
end
