# frozen_string_literal: true

# Drives the real IRC transport (lib/polari/telepathy_client.rb) against a
# tiny fake IRC server on a loopback TCP socket — not a FakeChannel standing
# in for it, the actual wire protocol: NICK/USER, 001, JOIN, 353/366, an
# incoming PRIVMSG, and an outgoing one the fake server reads back.
#
# Run it from the repository root:
#
#   nix develop --command xvfb-run -a ruby test/drive_telepathy_client.rb

require 'fileutils'
require 'tmpdir'
require 'socket'

ENV['XDG_CONFIG_HOME'] = Dir.mktmpdir('polari-drive-config')
ENV['XDG_DATA_HOME'] = Dir.mktmpdir('polari-drive-data')

$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))

require 'polari'
require_relative 'gtk_driver'

Polari::Utils.needs_onetime_action?('initial-setup')

# A minimal IRC server: just enough protocol for one client to register,
# join a channel, see a member list, receive a message and have one read
# back. Lines it does not recognise are ignored, the way a real server
# ignores anything it has no handler for.
class FakeIrcServer
  attr_reader :port, :received

  def initialize
    @tcp = TCPServer.new('127.0.0.1', 0)
    @port = @tcp.addr[1]
    @received = []
    @client = nil
  end

  def start
    Thread.new { serve }
  end

  def send_line(line)
    @client&.write("#{line}\r\n")
  end

  private

    def serve
      @client = @tcp.accept
      nick = nil

      while (line = @client.gets("\r\n") || @client.gets("\n"))
        line = line.chomp
        @received << line

        if line.start_with?('NICK ')
          nick = line.delete_prefix('NICK ').strip
        elsif line.start_with?('USER ')
          send_line(":fakeserver 001 #{nick} :Welcome to the fake network")
        elsif line.start_with?('JOIN ')
          channel = line.delete_prefix('JOIN ').strip
          send_line(":#{nick}!#{nick}@fake JOIN #{channel}")
          send_line(":fakeserver 353 #{nick} = #{channel} :#{nick} bob")
          send_line(":fakeserver 366 #{nick} #{channel} :End of names")
        end
      end
    rescue IOError, Errno::ECONNRESET => e
      warn "FAKE SERVER IOError: #{e.class}: #{e.message}"
    rescue StandardError => e
      warn "FAKE SERVER CRASHED: #{e.class}: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
    end
end

SERVER = FakeIrcServer.new
SERVER.start

def wait_until(timeout_s = 10)
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout_s
  done = false

  until done
    done = yield

    unless done
      if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        done = true
      else
        GLib::MainContext.default.iteration(false)
        sleep(0.02)
      end
    end
  end

  yield
end

SHOTS = File.expand_path('../tmp/shots-telepathy-client', __dir__)
FileUtils.rm_rf(SHOTS)

GtkDriver.drive(Polari::Application.new, shots: SHOTS, timeout: 60) do |d, polari_app|
  d.window { polari_app.window }

  d.step('the app is active with no accounts yet') do
    d.check('no accounts at startup') { Polari::AccountsMonitor.default.accounts.empty? }
  end

  d.step('creating an account for the fake server') do
    account = Polari::AccountsMonitor.default.create_account(
      display_name: 'Fake Network',
      parameters:   { 'server' => '127.0.0.1', 'port' => SERVER.port.to_s, 'use-ssl' => false, 'account' => 'drivebot' },
      nickname:     'drivebot',
    )
    @account_path = account.object_path
  end

  d.step('requesting presence available connects the real socket') do
    account = Polari::AccountsMonitor.default.lookup_account(@account_path)
    account.request_presence(Polari::Account::PRESENCE_AVAILABLE)
  end

  d.step('the transport reaches CONNECTED over the real wire') do
    account = Polari::AccountsMonitor.default.lookup_account(@account_path)
    connected = wait_until(10) { account.connection_status == Polari::Account::STATUS_CONNECTED }
    d.check('account status is CONNECTED') { connected }
    d.check('the server actually saw NICK and USER') do
      SERVER.received.any? { |l| l.start_with?('NICK') } && SERVER.received.any? { |l| l.start_with?('USER') }
    end
    d.check('account.connection is the live IrcConnection') { !account.connection.nil? }
  end

  d.step('joining a room sends a real JOIN and gets a real member list') do
    Polari::RoomManager.default.join_room(@account_path, '#test', present: true)
  end

  d.step('the room has a live channel with both members') do
    account = Polari::AccountsMonitor.default.lookup_account(@account_path)
    room = Polari::RoomManager.default.lookup_room(
      Polari::Room.create_room_id(account, '#test', :room),
    )
    @room = room

    joined = wait_until(10) { room && !room.channel.nil? && room.members.length == 2 }
    d.check('the room has a channel') { joined }
    d.check('the server actually saw our JOIN') { SERVER.received.any? { |l| l.start_with?('JOIN #test') } }
    d.check('bob is a member from the real NAMES reply') { room.members.map(&:alias).include?('bob') }
  end

  d.step('a PRIVMSG from the fake server arrives in the chat view') do
    SERVER.send_line(':bob!bob@fake PRIVMSG #test :hello from the wire')
  end

  d.step('the chat view shows the real incoming message') do
    view = polari_app.window.room_stack.view_for_room(@room)
    arrived = wait_until(10) { view.chat_view.buffer.text.include?('hello from the wire') }
    d.check('the message text reached the chat log') { arrived }
    d.check('bob is in the buffer as the sender') { view.chat_view.buffer.text.include?('bob') }
    d.shot('01-message-received')
  end

  d.step('sending a message writes a real PRIVMSG the server reads back') do
    @room.channel.send_text('hi from the real client')
  end

  d.step('the server received it and the chat view shows our own message') do
    sent = wait_until(10) { SERVER.received.any? { |l| l.include?('hi from the real client') } }
    d.check('the server saw the PRIVMSG') { sent }
    d.check('it was addressed to #test') { SERVER.received.any? { |l| l.start_with?('PRIVMSG #test :hi from the real client') } }

    view = polari_app.window.room_stack.view_for_room(@room)
    shown = wait_until(5) { view.chat_view.buffer.text.include?('hi from the real client') }
    d.check('the sent message shows in our own chat log') { shown }
    d.shot('02-message-sent')
  end

  d.step('requesting offline presence sends a real QUIT and tears the channel down') do
    account = Polari::AccountsMonitor.default.lookup_account(@account_path)
    account.request_presence(Polari::Account::PRESENCE_OFFLINE)
  end

  d.step('the account disconnects and the room loses its channel') do
    account = Polari::AccountsMonitor.default.lookup_account(@account_path)
    gone = wait_until(10) { account.connection_status == Polari::Account::STATUS_DISCONNECTED }
    d.check('account status is DISCONNECTED') { gone }
    d.check('the server actually saw QUIT') { SERVER.received.any? { |l| l.start_with?('QUIT') } }
    no_channel = wait_until(5) { @room.channel.nil? }
    d.check('the room channel was invalidated') { no_channel }
  end
end
