module EventMachine
  module WebSocket
    class Handler
      include Debugger

      attr_reader :request, :state

      def initialize(connection, request, debug = false)
        @connection, @request = connection, request
        @debug = debug
        @state = :handshake
        initialize_framing
      end

      def run_server
        @connection.send_data handshake_server
        @state = :connected
        @connection.trigger_on_open
      end

      def run_client
        self.mask_outbound_messages = true
        self.require_masked_inbound_messages = false
        @connection.send_data handshake_client
      end

      # Handshake response
      def handshake
        # Implemented in subclass
      end

      def handshake_server
        handshake  #backwards compatibility
      end

      # Handshake initiation
      def handshake_client
        # Implemented in subclass
      end

      def receive_data(data)
        @data << data
        process_data(data)
      end

      def close_websocket(code, body)
        # Implemented in subclass
      end

      def unbind
        @state = :closed
        @connection.trigger_on_close
      end
    end
  end
end
