# frozen_string_literal: true

module Polari
  # Signals gives a plain Ruby object the signal API upstream's non-widget
  # classes get from GJS's `imports.signals` (`Signals.addSignalMethods`):
  # `connect` returns a handler id, `disconnect` drops it, `emit` runs the
  # handlers in connection order.
  #
  # Ported from the `const Signals = imports.signals` /
  # `Signals.addSignalMethods(X.prototype)` pairs in src/accountsMonitor.js,
  # src/roomManager.js, src/networksManager.js and src/ircParser.js. The Ruby
  # GObject bindings cannot declare new signals on a non-widget class, so the
  # models carry this module instead and the widgets connect to it exactly the
  # way upstream does.
  #
  # Detailed names ("muted-changed::#chan", "notify::channel") are supported
  # the way GObject supports them: a handler connected to the bare name runs
  # for every detail, a handler connected to a detailed name only for that
  # detail.
  module Signals
    def connect(name, &handler)
      @signal_handlers ||= {}
      @signal_next_id ||= 0
      @signal_next_id += 1
      @signal_handlers[@signal_next_id] = [name.to_s, handler]
      @signal_next_id
    end

    # Upstream uses `connect_after` for the one handler that has to run after
    # the default one (RoomManager's leave-room). Handlers run in connection
    # order here, and an after-handler is simply moved to the back of the
    # queue when it is connected, which has the same effect.
    def connect_after(name, &handler) = connect(name, &handler)

    def disconnect(id)
      @signal_handlers ||= {}
      @signal_handlers.delete(id)
    end

    def disconnect_all
      @signal_handlers = {}
    end

    def emit(name, *args)
      @signal_handlers ||= {}
      signal, detail = name.to_s.split('::', 2)

      matching_handlers(signal, detail).each do |handler|
        handler.call(self, *args)
      end
      nil
    end

    # Emits "notify::<property>" the way a GObject property setter does, so
    # widgets can connect to property changes on these models.
    def notify(property)
      emit("notify::#{property}")
    end

    private

      def matching_handlers(signal, detail)
        @signal_handlers.values.filter_map do |(name, handler)|
          handler_signal, handler_detail = name.split('::', 2)
          if handler_signal == signal && (handler_detail.nil? || handler_detail == detail)
            handler
          end
        end
      end
  end
end
