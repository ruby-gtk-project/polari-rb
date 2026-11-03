# frozen_string_literal: true

require 'json'
require 'fileutils'
require 'securerandom'
require 'gio2'
require_relative 'signals'
require_relative 'settings'
require_relative 'networks_manager'

module Polari
  # Account is one IRC connection the user has configured: its parameters,
  # its nickname, whether it is shown in the sidebar, and its connection
  # state.
  #
  # Ported from the PolariAccount subclass at the bottom of
  # src/accountsMonitor.js. Upstream's accounts are TpAccount proxies owned by
  # the Telepathy account manager; there is no Telepathy here, so the same
  # properties sit on a plain model that AccountsMonitor stores in a JSON
  # file. The property names, the derived values (predefined, servers,
  # connection params with their default ports) and the notifications are
  # upstream's, so the IRC transport (src/telepathyClient.js, not ported yet)
  # can drive the connection state through the setters below without the
  # widgets noticing a difference.
  class Account
    include Signals

    # Tp.ConnectionStatus
    STATUS_CONNECTED = :connected
    STATUS_CONNECTING = :connecting
    STATUS_DISCONNECTED = :disconnected

    # Tp.ConnectionStatusReason
    REASON_NONE_SPECIFIED = :none_specified
    REASON_REQUESTED = :requested

    # Tp.ConnectionPresenceType, of which Polari only ever requests two
    PRESENCE_OFFLINE = :offline
    PRESENCE_AVAILABLE = :available

    # Error names upstream matches on, in the dbus spelling TpError uses
    ERROR_AUTHENTICATION_FAILED = 'org.freedesktop.Telepathy.Error.AuthenticationFailed'
    ERROR_CONNECTION_FAILED = 'org.freedesktop.Telepathy.Error.ConnectionFailed'
    ERROR_CERT_UNTRUSTED = 'org.freedesktop.Telepathy.Error.Cert.Untrusted'

    DEFAULT_SSL_PORT = 6697
    DEFAULT_PORT = 6667

    attr_reader :object_path, :parameters, :service, :connection_status,
                :connection_status_reason, :connection_error,
                :requested_presence_type

    # The live connection, set by the IRC transport while the account is
    # connected — upstream reads TpAccount:connection for the same purpose
    # (the server room listing and the self contact come from it).
    attr_accessor :connection

    def initialize(object_path:, parameters:, display_name: nil, nickname: nil, service: nil)
      @object_path = object_path
      @parameters = parameters
      @display_name = display_name || parameters['server']
      @nickname = nickname || parameters['account']
      @service = service
      @visible = true
      @enabled = true
      @reachable = nil
      @connection_status = STATUS_DISCONNECTED
      @connection_status_reason = REASON_REQUESTED
      @connection_error = nil
      @requested_presence_type = PRESENCE_OFFLINE
      @connection = nil
    end

    # The trailing component of the object path, which upstream uses as the
    # per-account settings path and as the keyring attribute.
    def path_suffix = @object_path.split('/').last(3).join('/')

    def display_name = @display_name

    def display_name=(value)
      unless value == @display_name
        @display_name = value
        notify('display-name')
      end
    end

    def nickname = @nickname

    def nickname=(value)
      unless value == @nickname
        @nickname = value
        notify('nickname')
      end
    end

    def visible? = @visible
    def visible = @visible

    def visible=(value)
      unless value == @visible
        @visible = value
        notify('visible')
      end
    end

    def enabled? = @enabled

    def enabled=(value)
      unless value == @enabled
        @enabled = value
        notify('enabled')
      end
    end

    def reachable = @reachable
    def reachable? = @reachable == true

    def reachable=(value)
      unless value == @reachable
        @reachable = value
        notify('reachable')
      end
    end

    # Set by the IRC transport as it connects, disconnects or fails.
    def set_connection_status(status, reason: REASON_NONE_SPECIFIED, error: nil)
      @connection_status = status
      @connection_status_reason = reason
      @connection_error = error
      notify('connection-status')
    end

    # The two presence requests Polari makes: going online, and going offline
    # (on /QUIT, on the connection popover's Disconnect, and on shutdown).
    def request_presence(presence)
      unless presence == @requested_presence_type
        @requested_presence_type = presence
        notify('requested-presence-type')
      end
    end

    def predefined? = NetworksManager.default.account_predefined?(self)

    def update_parameters(parameters)
      @parameters = @parameters.merge(parameters)
      notify('parameters')
    end

    # The parameters with the holes filled in the way upstream's
    # getConnectionParams() fills them: use-ssl as a boolean, and the port
    # defaulted from it.
    def connection_params
      @parameters.dup.then do |params|
        params['use-ssl'] = params['use-ssl'] ? true : false
        default_port = params['use-ssl'] ? DEFAULT_SSL_PORT : DEFAULT_PORT
        params['port'] = params['port'].to_i.positive? ? params['port'].to_i : default_port
        params
      end
    end

    # A predefined network's servers come from the network list; a custom
    # account has exactly the one server it was configured with.
    def servers
      if predefined?
        NetworksManager.default.network_servers(@service)
      else
        connection_params.then do |params|
          [{ 'address' => params['server'], 'port' => params['port'] }]
        end
      end
    end

    def settings = Settings.for_account(path_suffix.tr('/', '-'))

    def to_h
      {
        'object_path'  => @object_path,
        'display_name' => @display_name,
        'nickname'     => @nickname,
        'service'      => @service,
        'parameters'   => @parameters,
        'visible'      => @visible,
        'enabled'      => @enabled,
      }
    end

    def self.from_h(hash)
      new(
        object_path:  hash['object_path'],
        parameters:   hash['parameters'] || {},
        display_name: hash['display_name'],
        nickname:     hash['nickname'],
        service:      hash['service'],
      ).tap do |account|
        account.visible = hash.fetch('visible', true)
        account.enabled = hash.fetch('enabled', true)
      end
    end
  end

  # AccountsMonitor is the set of IRC accounts the application knows about,
  # and the signals the sidebar, the room manager and the connection list
  # follow to stay in step with it.
  #
  # Ported from src/accountsMonitor.js. Upstream wraps the Telepathy account
  # manager: it prepares it asynchronously, filters the accounts down to the
  # IRC ones, and watches the network monitor to tell whether each account's
  # servers can be reached. This port keeps the interface — getDefault(),
  # prepare(), accounts, visibleAccounts, lookupAccount() and the same eight
  # signals — and stores the accounts in a JSON file, since the port has no
  # Telepathy to ask. Reachability still comes from Gio's network monitor.
  class AccountsMonitor
    include Signals

    ACCOUNT_PATH_PREFIX = '/org/freedesktop/Telepathy/Account/idle/irc'

    def self.default = @default ||= new

    def self.reset = @default = nil

    def initialize(path: nil)
      @accounts = {}
      @prepared = false
      @prepared_callbacks = []
      @location = path || File.join(Settings.config_dir, 'accounts.json')

      read_accounts
      @prepared = true

      @network_monitor = Gio::NetworkMonitor.default
      @network_monitor.signal_connect('network-changed') { on_network_changed }
      on_network_changed
    end

    attr_reader :location

    def accounts = @accounts.values

    def visible_accounts = @accounts.values.select(&:visible?)

    def lookup_account(object_path) = @accounts[object_path]

    # Upstream's accounts arrive asynchronously, so callers hand it a
    # callback that runs once the account manager is prepared. Here the
    # accounts are read from disk in the constructor, so the callback runs
    # straight away — the shape stays the same for the transport to hook into
    # later.
    def prepare(&callback)
      if @prepared
        callback.call
      else
        @prepared_callbacks << callback
      end
    end

    # Creates an account from the parameters the join dialog and the
    # connection editor collect, the way upstream's Tp.AccountRequest does.
    def create_account(display_name:, parameters:, nickname: nil, service: nil)
      object_path = "#{ACCOUNT_PATH_PREFIX}/#{SecureRandom.hex(8)}"

      Account.new(
        object_path:  object_path,
        parameters:   parameters,
        display_name: display_name,
        nickname:     nickname || parameters['account'],
        service:      service,
      ).tap do |account|
        add_account(account)
        write_accounts
      end
    end

    def remove_account(account)
      if @accounts.delete(account.object_path)
        write_accounts
        emit('account-removed', account)
        emit('accounts-changed')
      end
    end

    # Persists whatever the connection editor changed.
    def save = write_accounts

    private

      def add_account(account)
        unless @accounts.key?(account.object_path)
          @accounts[account.object_path] = account
          watch_account(account)

          emit('account-added', account)
          emit('accounts-changed')
        end
      end

      def watch_account(account)
        account.connect('notify::connection-status') do
          emit('account-status-changed', account)
        end
        account.connect('notify::reachable') do
          emit('account-reachable-changed', account)
        end
        account.connect('notify::visible') do
          update_account_reachable(account)
          emit(account.visible? ? 'account-shown' : 'account-hidden', account)
          emit('accounts-changed')
        end
        account.connect('notify::enabled') do
          emit(account.enabled? ? 'account-enabled' : 'account-disabled', account)
          emit('accounts-changed')
        end
      end

      def on_network_changed
        visible_accounts.each { |account| update_account_reachable(account) }
      end

      # Upstream probes every server of the account with
      # GNetworkMonitor.can_reach_async(); the Ruby bindings have no
      # introspected async variant to drive from here, so the port asks the
      # same monitor the coarser question it answers synchronously.
      def update_account_reachable(account)
        account.reachable = @network_monitor.network_available?
      end

      def read_accounts
        if File.exist?(@location)
          JSON.parse(File.read(@location)).each do |hash|
            add_account(Account.from_h(hash))
          end
        end
      rescue JSON::ParserError => e
        warn "Error parsing #{@location}: #{e.message}"
      end

      def write_accounts
        FileUtils.mkdir_p(File.dirname(@location))
        File.write(@location, JSON.pretty_generate(accounts.map(&:to_h)))
      end
  end
end
