# frozen_string_literal: true

require 'json'
require 'etc'
require_relative 'signals'

module Polari
  # NetworksManager is the list of predefined IRC networks, read once from
  # data/networks.json, and the questions the join dialog and the connection
  # editor ask about them.
  #
  # Ported from src/networksManager.js. Upstream loads the file from the
  # GResource bundle; this port reads the same file from the data directory
  # that ships beside lib/.
  class NetworksManager
    include Signals

    DEFAULT_SSL_PORT = 6697
    DEFAULT_PORT = 6667

    class InvalidNetwork < StandardError; end

    def self.default = @default ||= new

    def self.data_path
      File.expand_path('../../data/networks.json', __dir__)
    end

    def initialize(path: self.class.data_path)
      @networks = []
      @networks_by_id = {}

      parse_networks(File.read(path))
    rescue SystemCallError => e
      warn "Failed to load network list: #{e.message}"
    end

    attr_reader :networks

    def account_predefined?(account)
      !account.nil? && @networks_by_id.key?(account.service)
    end

    def network_name(id) = lookup_network(id).fetch('name')

    def network_favorite?(id) = lookup_network(id).fetch('favorite', false)

    # The parameters a new account for this network needs: the local user name
    # as the IRC account name, and the first (preferably TLS) server.
    def network_details(id)
      server = network_servers(id).first

      {
        'account'  => Etc.getlogin || ENV.fetch('USER', 'polari'),
        'server'   => server.fetch('address'),
        'port'     => server.fetch('port', server['ssl'] ? DEFAULT_SSL_PORT : DEFAULT_PORT),
        'use-ssl'  => server.fetch('ssl', false),
      }.then do |details|
        if server['charset']
          details.merge('charset' => server['charset'])
        else
          details
        end
      end
    end

    # The TLS servers when the network has any, all of them otherwise.
    def network_servers(id)
      network = lookup_network(id)
      servers = network.fetch('servers', [])

      if servers.empty?
        raise InvalidNetwork, "No servers for network #{id}"
      end

      servers.select { |server| server['ssl'] }.then do |ssl_servers|
        ssl_servers.empty? ? servers.dup : ssl_servers
      end
    end

    # The strings the join dialog's network filter matches against.
    def network_match_terms(id)
      network = lookup_network(id)
      servers = network.fetch('servers', []).map { |server| server['address'] }
      ([network['name'], network['id']] + servers).compact.map(&:downcase)
    end

    def find_by_server(server)
      @networks.find do |network|
        network.fetch('servers', []).any? { |s| s['address'] == server }
      end&.fetch('id')
    end

    private

      def parse_networks(data)
        @networks = JSON.parse(data)
        @networks_by_id = @networks.to_h { |network| [network['id'], network] }
        true
      rescue JSON::ParserError => e
        warn "Failed to parse network list: #{e.message}"
        false
      end

      def lookup_network(id)
        @networks_by_id.fetch(id) do
          raise InvalidNetwork, 'Invalid network ID'
        end
      end
  end
end
