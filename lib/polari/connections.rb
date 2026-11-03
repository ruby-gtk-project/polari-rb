# frozen_string_literal: true

require 'etc'
require 'adwaita'
require_relative 'accounts_monitor'
require_relative 'networks_manager'
require_relative 'utils'

module Polari
  # ConnectionRow is one predefined network in the network list, greyed out
  # with "Already added" once an account for it exists.
  #
  # Ported from the ConnectionRow class in src/connections.js.
  class ConnectionRow < Gtk::ListBoxRow
    def initialize(id, networks_manager: NetworksManager.default)
      super()
      @id = id
      @networks_manager = networks_manager

      self.name = "ConnectionRow #{network_name}"
    end

    attr_reader :id

    def network_name = @networks_manager.network_name(@id)

    def build
      tap do |row|
        row.child = box

        box.tap do |line|
          line.append(Gtk::Label.new(network_name).tap { |label| label.halign = :start })
          line.append(added_label)
        end

        row.bind_property('sensitive', row, 'activatable', :sync_create)
        row.bind_property('sensitive', added_label, 'visible',
                          [:sync_create, :invert_boolean])
      end
    end

    def box
      @box ||= Gtk::Box.new(:horizontal, 12).tap do |line|
        line.margin_start = 12
        line.margin_end = 12
        line.margin_top = 12
        line.margin_bottom = 12
      end
    end

    def added_label
      @added_label ||= Gtk::Label.new('Already added').tap do |label|
        label.hexpand = true
        label.halign = :end
        label.visible = false
      end
    end
  end

  # ConnectionsList is the list of predefined networks the join dialog's "Add
  # Network" page shows: filtered by the search entry, favourites first, and
  # with an empty state when nothing matches.
  #
  # Ported from the ConnectionsList class in src/connections.js. Activating a
  # row creates an account for that network from the network list's details,
  # which is what upstream's Tp.AccountRequest does; here AccountsMonitor
  # creates it.
  class ConnectionsList < Gtk::ScrolledWindow
    def initialize(
      favorites_only: false,
      accounts_monitor: AccountsMonitor.default,
      networks_manager: NetworksManager.default,
      on_account_created: nil,
      on_account_selected: nil
    )
      super()
      @favorites_only = favorites_only
      @accounts_monitor = accounts_monitor
      @networks_manager = networks_manager
      @on_account_created = on_account_created
      @on_account_selected = on_account_selected
      @rows = {}
      @filter_terms = []

      self.hscrollbar_policy = :never
    end

    def build
      tap do |widget|
        widget.child = list

        list.tap do |box|
          box.signal_connect('row-activated') { |_l, row| on_row_activated(row) }
          box.set_filter_func { |row| filter_row(row) }
          box.set_header_func { |row, before| update_header(row, before) }
          box.set_sort_func { |row1, row2| sort_rows(row1, row2) }
          box.placeholder = placeholder
        end

        @accounts_monitor.connect('account-added') do |_m, account|
          set_account_row_sensitive(account, false)
        end
        @accounts_monitor.connect('account-removed') do |_m, account|
          set_account_row_sensitive(account, true)
        end

        populate_networks
      end
    end

    def set_filter(filter)
      if Utils.update_terms(@filter_terms, filter)
        list.invalidate_filter

        list.get_row_at_y(0).then do |row|
          if row
            list.select_row(row)
          end
        end
      end
    end

    def activate_selected
      list.selected_row.then do |row|
        if row
          on_row_activated(row)
        end
      end
    end

    def list = @list ||= Gtk::ListBox.new

    def placeholder
      @placeholder ||= Gtk::Box.new(:vertical, 0).tap do |box|
        box.halign = :center
        box.valign = :center
        box.add_css_class('dim-label')
        box.append(Gtk::Image.new.tap do |image|
          image.icon_name = 'edit-find-symbolic'
          image.pixel_size = 115
        end)
        box.append(Gtk::Label.new('No results.'))
      end
    end

    private

      def populate_networks
        list.children.each { |row| list.remove(row) }
        @rows.clear

        used_networks = @accounts_monitor.accounts.select(&:predefined?).map(&:service)

        @networks_manager.networks.each do |network|
          id = network['id']

          if !@favorites_only || @networks_manager.network_favorite?(id)
            ConnectionRow.new(id, networks_manager: @networks_manager).build.tap do |row|
              row.sensitive = !used_networks.include?(id)
              @rows[id] = row
              list.append(row)
            end
          end
        end
      end

      def on_row_activated(row)
        @on_account_selected&.call

        details = @networks_manager.network_details(row.id)
        account = @accounts_monitor.create_account(
          display_name: @networks_manager.network_name(row.id),
          parameters:   details,
          nickname:     details['account'],
          service:      row.id,
        )

        Utils.clear_account_password(account)
        Utils.clear_identify_password(account)

        @on_account_created&.call(account)
      end

      def set_account_row_sensitive(account, sensitive)
        if account.predefined? && @rows.key?(account.service)
          @rows[account.service].sensitive = sensitive
        end
      end

      def filter_row(row)
        match_terms = @networks_manager.network_match_terms(row.id)

        @filter_terms.all? do |term|
          match_terms.any? { |candidate| candidate.include?(term) }
        end
      end

      def update_header(row, before)
        if before.nil?
          row.header = nil
        elsif row.header.nil?
          row.header = Gtk::Separator.new(:horizontal)
        end
      end

      def sort_rows(row1, row2)
        favorite1 = @networks_manager.network_favorite?(row1.id)
        favorite2 = @networks_manager.network_favorite?(row2.id)

        if favorite1 != favorite2
          favorite1 ? -1 : 1
        else
          @networks_manager.network_name(row1.id) <=> @networks_manager.network_name(row2.id)
        end
      end
  end

  # ConnectionDetails is the five-row editor for a custom network: server
  # address, network name, TLS, nickname and real name. It creates an account
  # when it has none, and updates the one it was given.
  #
  # Ported from the ConnectionDetails class in src/connections.js plus
  # data/ui/connection-details.ui, including the "server:port" parsing, the
  # default ports, the real-name completion from the system's name, the
  # can-confirm rule (server and nick filled in, and something actually
  # changed) and the error hints the properties dialog sets.
  class ConnectionDetails < Adwaita::PreferencesPage
    ERROR_HINT_NONE = :none
    ERROR_HINT_SERVER = :server
    ERROR_HINT_NICK = :nick

    SERVER_REGEX = /\A(.*?)(?::(\d{1,5}))?\z/

    def initialize(
      account: nil,
      accounts_monitor: AccountsMonitor.default,
      on_account_created: nil,
      on_can_confirm_changed: nil
    )
      super()
      @accounts_monitor = accounts_monitor
      @on_account_created = on_account_created
      @on_can_confirm_changed = on_can_confirm_changed
      @account = account
      @saved = {}
    end

    def build
      tap do |page|
        page.add(server_group)
        page.add(user_group)

        server_group.tap do |group|
          group.add(server_row)
          group.add(name_row)
          group.add(ssl_row)
        end

        user_group.tap do |group|
          group.add(nick_row)
          group.add(realname_row)
        end

        [name_row, server_row, nick_row, realname_row].each do |row|
          row.signal_connect('changed') { @on_can_confirm_changed&.call }
          row.delegate.activates_default = true
        end
        ssl_row.signal_connect('notify::active') { @on_can_confirm_changed&.call }

        realname_row.signal_connect('changed') { complete_realname }

        self.account = @account
      end
    end

    def account = @account

    def account=(account)
      @account = account
      server_group.visible = !service?
      reset

      if @account
        populate_from_account(@account)
      end
    end

    # A predefined network's server settings are not the user's business.
    def service? = !@account.nil? && @account.predefined?

    def can_confirm?
      changed = @saved.any? do |key, value|
        current_values[key] != value
      end

      !server_row.text.empty? && !nick_row.text.empty? && changed
    end

    def set_error_hint(hint)
      if hint == ERROR_HINT_SERVER
        server_row.add_css_class('error')
      else
        server_row.remove_css_class('error')
      end

      if hint == ERROR_HINT_NICK
        nick_row.add_css_class('error')
      else
        nick_row.remove_css_class('error')
      end
    end

    def reset
      @saved = {
        name:     '',
        server:   '',
        nick:     Etc.getlogin || ENV.fetch('USER', ''),
        realname: '',
        ssl:      false,
      }
      apply_values(@saved)

      if server_row.visible?
        server_row.grab_focus
      else
        nick_row.grab_focus
      end
    end

    def save
      if can_confirm?
        if @account
          update_account
        else
          create_account
        end
      end
    end

    def server_group
      @server_group ||= Adwaita::PreferencesGroup.new.tap do |group|
        group.hexpand = true
      end
    end

    def user_group
      @user_group ||= Adwaita::PreferencesGroup.new.tap do |group|
        group.hexpand = true
      end
    end

    def server_row = @server_row ||= entry_row('_Server Address')
    def name_row = @name_row ||= entry_row('Net_work Name')
    def nick_row = @nick_row ||= entry_row('_Nickname')
    def realname_row = @realname_row ||= entry_row('_Real Name')

    def ssl_row
      @ssl_row ||= Adwaita::SwitchRow.new.tap do |row|
        row.title = 'Use secure c_onnection'
        row.use_underline = true
      end
    end

    private

      def entry_row(title)
        Adwaita::EntryRow.new.tap do |row|
          row.title = title
          row.use_underline = true
        end
      end

      def current_values
        {
          name:     name_row.text,
          server:   server_row.text,
          nick:     nick_row.text,
          realname: realname_row.text,
          ssl:      ssl_row.active?,
        }
      end

      def apply_values(values)
        name_row.text = values[:name]
        server_row.text = values[:server]
        nick_row.text = values[:nick]
        realname_row.text = values[:realname]
        ssl_row.active = values[:ssl]
      end

      # Typing the beginning of the system's real name fills in the rest.
      def complete_realname
        text = realname_row.text.to_s
        realname = Etc.getpwnam(Etc.getlogin.to_s).gecos.to_s.split(',').first.to_s

        if !text.empty? && realname.start_with?(text) && realname != text
          realname_row.text = realname
          realname_row.select_region(text.length, -1)
        end
      rescue ArgumentError
        nil
      end

      def params
        server, port = parse_server
        name = name_row.text.strip

        {
          'name'    => name.empty? ? server : name,
          'server'  => server,
          'account' => nick_row.text.strip,
        }.then { |collected| add_optional_params(collected, port) }
      end

      def add_optional_params(collected, port)
        collected.tap do |all|
          unless realname_row.text.to_s.strip.empty?
            all['fullname'] = realname_row.text.strip
          end
          if ssl_row.active?
            all['use-ssl'] = true
          end
          if port
            all['port'] = port.to_i
          elsif ssl_row.active?
            all['port'] = Account::DEFAULT_SSL_PORT
          end
        end
      end

      def parse_server
        match = SERVER_REGEX.match(server_row.text.to_s.strip)
        [match[1], match[2]]
      end

      def create_account
        details = params

        @accounts_monitor.create_account(
          display_name: details['name'],
          parameters:   details.except('name'),
          nickname:     details['account'],
        ).tap do |account|
          Utils.clear_account_password(account)
          Utils.clear_identify_password(account)
          @on_account_created&.call(account)
        end
      end

      def update_account
        details = params

        @account.update_parameters(details.except('name'))
        @account.display_name = details['name']
        @accounts_monitor.save
      end

      def populate_from_account(account)
        connection = account.connection_params
        ssl = connection['use-ssl'] ? true : false
        default_port = ssl ? Account::DEFAULT_SSL_PORT : Account::DEFAULT_PORT
        server = connection['server'].to_s

        if connection['port'] != default_port
          server = "#{server}:#{connection['port']}"
        end

        @saved = {
          name:     server == account.display_name ? '' : account.display_name.to_s,
          server:   server,
          nick:     connection['account'].to_s,
          realname: connection['fullname'].to_s,
          ssl:      ssl,
        }
        apply_values(@saved)
      end
  end

  # ConnectionProperties is the dialog the sidebar's Properties action opens:
  # the same editor, with Cancel and Apply, and the network error explained
  # at the bottom when the last connection attempt failed.
  #
  # Ported from the ConnectionProperties class in src/connections.js plus
  # data/ui/connection-properties.ui.
  class ConnectionProperties < Adwaita::Dialog
    NETWORK_ERROR_MESSAGE =
      'Polari disconnected due to a network error. ' \
      'Please check if the address field is correct.'

    NETWORK_ERRORS = [
      'org.freedesktop.Telepathy.Error.ConnectionRefused',
      'org.freedesktop.Telepathy.Error.NetworkError',
    ].freeze

    def initialize(account)
      super()
      @account = account

      self.title = format('“%s” Properties', account.display_name)
      self.follows_content_size = true
    end

    def build
      tap do |dialog|
        dialog.child = toolbar_view
        dialog.default_widget = apply_button

        toolbar_view.tap do |view|
          view.add_top_bar(header_bar)
          view.content = details.build
          view.add_bottom_bar(error_box)
          view.bottom_bar_style = :raised
          view.reveal_bottom_bars = false
        end

        header_bar.tap do |bar|
          bar.show_start_title_buttons = false
          bar.show_end_title_buttons = false
          bar.pack_start(cancel_button)
          bar.pack_end(apply_button)
        end

        error_box.tap do |box|
          box.start_widget = error_icon
          box.center_widget = error_label
        end

        apply_button.signal_connect('clicked') do
          details.save
          close
        end

        @account.connect('notify::connection-status') { sync_error_message }
        sync_error_message
        update_apply_sensitivity
      end
    end

    def toolbar_view = @toolbar_view ||= Adwaita::ToolbarView.new
    def header_bar = @header_bar ||= Adwaita::HeaderBar.new

    def details
      @details ||= ConnectionDetails.new(
        account:                @account,
        on_can_confirm_changed: method(:update_apply_sensitivity),
      )
    end

    def cancel_button
      @cancel_button ||= Gtk::Button.new(label: '_Cancel').tap do |button|
        button.receives_default = true
        button.use_underline = true
        button.action_name = 'window.close'
      end
    end

    def apply_button
      @apply_button ||= Gtk::Button.new(label: '_Apply').tap do |button|
        button.receives_default = true
        button.use_underline = true
        button.add_css_class('suggested-action')
      end
    end

    def error_box
      @error_box ||= Gtk::CenterBox.new.tap do |box|
        box.add_css_class('polari-error-information')
      end
    end

    def error_icon
      @error_icon ||= Gtk::Image.new.tap do |image|
        image.icon_name = 'dialog-error-symbolic'
        image.icon_size = :large
        image.valign = :start
        image.margin_start = 24
        image.margin_end = 12
        image.margin_top = 12
        image.margin_bottom = 12
      end
    end

    def error_label
      @error_label ||= Gtk::Label.new.tap do |label|
        label.vexpand = true
        label.wrap = true
        label.xalign = 0
        label.yalign = 0
        label.margin_top = 12
        label.margin_bottom = 12
      end
    end

    private

      def update_apply_sensitivity
        apply_button.sensitive = details.can_confirm?
      end

      def sync_error_message
        details.set_error_hint(ConnectionDetails::ERROR_HINT_NONE)
        toolbar_view.reveal_bottom_bars = false

        if failed_connection? && NETWORK_ERRORS.include?(@account.connection_error)
          error_label.label = NETWORK_ERROR_MESSAGE
          details.set_error_hint(ConnectionDetails::ERROR_HINT_SERVER)
          toolbar_view.reveal_bottom_bars = true
        end
      end

      def failed_connection?
        @account.connection_status == Account::STATUS_DISCONNECTED &&
          @account.connection_status_reason != Account::REASON_REQUESTED
      end
  end
end
