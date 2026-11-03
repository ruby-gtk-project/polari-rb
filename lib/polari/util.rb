# frozen_string_literal: true

module Polari
  # Util holds the helpers upstream keeps in C because the chat view calls
  # them for every message.
  #
  # Ported from src/lib/polari-util.c (polari_util_get_basenick,
  # polari_util_match_nick, polari_util_match_identify_message). The
  # behaviour is pinned by upstream's src/tests/test-util.c, including the
  # cases that look surprising: "nick42" is its own base nick, "nicky" does
  # not match "nick", and an identify command without a username reports an
  # empty username rather than none.
  module Util
    # ^(identify|login) (?:(\S+) )?(\S+)$ in polari-util.c, with
    # G_REGEX_CASELESS.
    IDENTIFY_MESSAGE_REGEX = /\A(identify|login) (?:(\S+) )?(\S+)\z/i

    # IRC colour codes: \x03 followed by one or two digits, optionally a
    # comma and one or two more. polari-room.c strips these from topics and
    # from part/quit messages before showing them.
    COLOR_CODE_REGEX = /\x03(?:[0-9]{1,2}(?:,[0-9]{1,2})?)?/

    module_function

    # The "base nick" of a nick: the leading run of alphanumerics, folded for
    # comparison, so "nick-away" and "nick|bbl" group with "nick". A nick that
    # starts with a non-alphanumeric has no such run, and is folded whole.
    def get_basenick(nick)
      nick.to_s.then do |text|
        length = text.each_char.take_while { |char| alnum?(char) }.length
        if length.positive?
          text[0, length].downcase
        else
          text.downcase
        end
      end
    end

    # Whether +text+ mentions +nick+ as a whole word, where "word" uses the
    # same ASCII-only boundaries as the C version ("assume ASCII nicknames, so
    # no complex pango-style breaks").
    def match_nick(text, nick)
      folded_nick = nick.to_s.downcase
      folded_text = text.to_s.downcase

      if folded_nick.empty?
        false
      else
        word_match?(folded_text, folded_nick)
      end
    end

    # Parses an identify/login message. Returns nil when the message is not
    # one, and [command, username, password] when it is — with the command in
    # the spelling the user typed, and an empty username when the message
    # carried none.
    def match_identify_message(message)
      IDENTIFY_MESSAGE_REGEX.match(message.to_s.strip).then do |match|
        if match
          [match[1], match[2].to_s, match[3]]
        end
      end
    end

    def strip_color_codes(string) = string.to_s.gsub(COLOR_CODE_REGEX, '')

    def alnum?(char) = char.match?(/[[:alnum:]]/) && char.ascii_only?

    # The match loop of polari_util_match_nick: every occurrence of the nick
    # is checked for alphanumeric neighbours, and the first one that stands
    # alone wins.
    def word_match?(text, nick)
      positions = []
      offset = 0
      while (position = text.index(nick, offset))
        positions << position
        offset = position + nick.length
      end

      positions.any? do |position|
        starts_word = position.zero? || !alnum?(text[position - 1])
        following = text[position + nick.length]
        ends_word = following.nil? || !alnum?(following)
        starts_word && ends_word
      end
    end
  end
end
