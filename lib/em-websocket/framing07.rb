# encoding: BINARY

module EventMachine
  module WebSocket
    module Framing07
      
      attr_accessor :mask_outbound_messages, :require_masked_inbound_messages

      def initialize_framing
        @data = MaskedString.new
        @application_data_buffer = '' # Used for MORE frames
        @mask_outbound_messages = false
        @require_masked_inbound_messages = true
      end
      
      def process_data(newdata)
        error = false

        while !error && @data.size >= 2
          pointer = 0

          fin = (@data.getbyte(pointer) & 0b10000000) == 0b10000000
          # Ignoring rsv1-3 for now
          opcode = @data.getbyte(pointer) & 0b00001111
          pointer += 1

          mask = (@data.getbyte(pointer) & 0b10000000) == 0b10000000
          length = @data.getbyte(pointer) & 0b01111111
          pointer += 1

          if require_masked_inbound_messages
            raise WebSocketError, 'Data from client must be masked' unless mask
          end

          payload_length = case length
          when 127 # Length defined by 8 bytes
            # Check buffer size
            if @data.getbyte(pointer+8-1) == nil
              debug [:buffer_incomplete, @data]
              error = true
              next
            end
            
            # Only using the last 4 bytes for now, till I work out how to
            # unpack 8 bytes. I'm sure 4GB frames will do for now :)
            l = @data.getbytes(pointer+4, 4).unpack('N').first
            pointer += 8
            l
          when 126 # Length defined by 2 bytes
            # Check buffer size
            if @data.getbyte(pointer+2-1) == nil
              debug [:buffer_incomplete, @data]
              error = true
              next
            end
            
            l = @data.getbytes(pointer, 2).unpack('n').first
            pointer += 2
            l
          else
            length
          end

          # Compute the expected frame length
          frame_length = pointer + payload_length
          frame_length += 4 if mask

          # Check buffer size
          if @data.getbyte(frame_length - 1) == nil
            debug [:buffer_incomplete, @data]
            error = true
            next
          end

          # Remove frame header
          @data.slice!(0...pointer)
          pointer = 0

          # Read application data (unmasked if required)
          @data.read_mask if mask
          pointer += 4 if mask
          application_data = @data.getbytes(pointer, payload_length)
          pointer += payload_length
          @data.unset_mask if mask
          
          # Throw away data up to pointer
          @data.slice!(0...pointer)

          frame_type = opcode_to_type(opcode)

          if frame_type == :continuation && !@frame_type
            raise WebSocketError, 'Continuation frame not expected'
          end

          if !fin
            debug [:moreframe, frame_type, application_data]
            @application_data_buffer << application_data
            # The message type is passed in the first frame
            @frame_type ||= frame_type
          else
            # Message is complete
            if frame_type == :continuation
              @application_data_buffer << application_data
              message(@frame_type, '', @application_data_buffer)
              @application_data_buffer = ''
              @frame_type = nil
            else
              message(frame_type, '', application_data)
            end
          end
        end # end while
      end
      
      def send_frame(frame_type, application_data)
        debug [:sending_frame, frame_type, application_data]

        if @state == :closing && data_frame?(frame_type)
          raise WebSocketError, "Cannot send data frame since connection is closing"
        end

        frame = ''

        opcode = type_to_opcode(frame_type)
        byte1 = opcode | 0b10000000 # fin bit set, rsv1-3 are 0
        frame << byte1

        mask = mask_outbound_messages ? 0b10000000 : 0b00000000 # must be masked if from client
        length = application_data.size
        if length <= 125
          byte2 = length # since rsv4 is 0
          frame << (mask | byte2)
        elsif length < 65536 # write 2 byte length
          frame << (mask | 126)
          frame << [length].pack('n')
        else # write 8 byte length
          frame << (mask | 127)
          frame << [length >> 32, length & 0xFFFFFFFF].pack("NN")
        end

        if mask_outbound_messages
          frame << MaskedString.create_masked_string(application_data)
        else
          frame << application_data
        end

        @connection.send_data(frame)
      end

      def send_text_frame(data)
        send_frame(:text, data)
      end

      private

      FRAME_TYPES = {
        :continuation => 0,
        :text => 1,
        :binary => 2,
        :close => 8,
        :ping => 9,
        :pong => 10,
      }
      FRAME_TYPES_INVERSE = FRAME_TYPES.invert
      # Frames are either data frames or control frames
      DATA_FRAMES = [:text, :binary, :continuation]

      def type_to_opcode(frame_type)
        FRAME_TYPES[frame_type] || raise("Unknown frame type")
      end

      def opcode_to_type(opcode)
        FRAME_TYPES_INVERSE[opcode] || raise(DataError, "Unknown opcode")
      end

      def data_frame?(type)
        DATA_FRAMES.include?(type)
      end
    end
  end
end
