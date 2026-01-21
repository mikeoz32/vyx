require "concurrent"
require "./piece_table"

module Vyx
  # Simple per-buffer actor implemented with fibers + channels as a spike.
  # This is a lightweight actor facade that will be swapped with a proper
  # actor implementation (Ametist) later if desired.

  class BufferActor
    abstract class Message
      class Insert < Message
        getter index : Int32
        getter text : String
        def initialize(@index : Int32, @text : String)
        end
      end

      class Delete < Message
        getter index : Int32
        getter length : Int32
        def initialize(@index : Int32, @length : Int32)
        end
      end

      class GetText < Message
        getter reply : Channel(String)
        def initialize(@reply : Channel(String))
        end
      end

      class Stop < Message; end
    end

    @mailbox : Channel(Message)
    @pt : PieceTable
    @running : Bool
    @lock : Mutex
    @thread : Fiber?

    def initialize(@name : String)
      @mailbox = Channel(Message).new
      @pt = PieceTable.new("")
      @running = true
      @lock = Mutex.new
      @thread = spawn do
        loop do
          msg = @mailbox.receive
          case msg
          when Message::Insert
            @pt.insert(msg.index, msg.text)
          when Message::Delete
            @pt.delete(msg.index, msg.length)
          when Message::GetText
            # synchronous reply
            snapshot = @lock.synchronize { @pt.to_s }
            msg.reply.send(snapshot)
          when Message::Stop
            break
          end
        end
      end
    end

    # Synchronous call that returns the current text (safe snapshot)
    def text
      reply = Channel(String).new
      @mailbox.send(Message::GetText.new(reply))
      reply.receive
    end

    def insert(index : Int32, text : String)
      @mailbox.send(Message::Insert.new(index, text))
    end

    def delete(index : Int32, length : Int32)
      @mailbox.send(Message::Delete.new(index, length))
    end

    def stop
      @mailbox.send(Message::Stop.new)
      @running = false
    end
  end
end
