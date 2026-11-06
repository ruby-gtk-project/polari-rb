# frozen_string_literal: true

require 'time'

module Polari
  # Message is one line of a conversation: its text, who sent it, when, and
  # whether it is an action (/me) or came from us.
  #
  # Ported from src/lib/polari-message.c. Upstream's boxed type carries the
  # same five fields plus two conversions: one from a TpMessage, and
  # polari_message_to_tracker_resource() for the search index. There is no
  # Telepathy here, but there is a real Tracker/TinySPARQL connection (the
  # `tsparql` gem) — the polari_message_to_tracker_resource() side of that
  # conversion is ChatLogStore#append in logger.rb, which builds the same
  # polari:Message/polari:Contact/polari:Channel resource graph directly
  # against the ontology at data/ontologies/polari.ontology.
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
  end
end
