module Vyx
  # Chunked add buffer to avoid large monolithic allocations during many small inserts
  class AddBuffer
    # Simple chunk object that uses a String::Builder to accumulate many small appends
    class Chunk
      getter size : Int32

      def initialize(s : String = "")
        @content = s || ""
        @tail = String::Builder.new
        @tail_bytes = 0
        @size = @content.bytesize
      end

      def append(s : String)
        @tail << s
        @tail_bytes += s.bytesize
        @size += s.bytesize
      end

      def bytesize : Int32
        @size
      end

      private def materialize!
        return if @tail_bytes == 0
        # materialize tail into content
        @content = @content + @tail.to_s
        @tail = String::Builder.new
        @tail_bytes = 0
      end

      def byte_slice(start : Int32, len : Int32) : String
        return "" if len <= 0
        raise ArgumentError.new("slice out of bounds") if start < 0 || start + len > @size

        if @tail_bytes > 0
          materialize!
        end

        @content.byte_slice(start, len)
      end

      def to_s : String
        if @tail_bytes > 0
          materialize!
        end
        @content
      end
    end

    getter chunk_size : Int32
    getter bytesize : Int32

    def initialize(@chunk_size : Int32 = 4096)
      @chunks = [] of Chunk
      @bytesize = 0
    end

    # Append text, return start offset.
    # Packs small appends into the last chunk if there's room and splits large inputs into chunk-sized pieces.
    def append(text : String) : Int32
      start = @bytesize
      return start if text.empty?

      remaining = text.bytesize
      pos = 0

      # Try to append into last chunk if space available
      if !@chunks.empty?
        last = @chunks.last
        space = @chunk_size - last.bytesize
        if space > 0
          take = [space, remaining].min
          last.append(text.byte_slice(pos, take))
          pos += take
          remaining -= take
          @bytesize += take
        end
      end

      # Add remaining in chunk_size pieces
      while remaining > 0
        take = [@chunk_size, remaining].min
        @chunks << Chunk.new(text.byte_slice(pos, take))
        pos += take
        remaining -= take
        @bytesize += take
      end

      start
    end

    # Return a contiguous byte slice as String (may allocate)
    def byte_slice(start : Int32, len : Int32) : String
      return "" if len <= 0
      raise ArgumentError.new("slice out of bounds") if start < 0 || start + len > @bytesize

      builder = String::Builder.new
      remaining = len
      pos = start
      @chunks.each do |c|
        break if remaining <= 0
        if pos >= c.bytesize
          pos -= c.bytesize
          next
        end
        take = [c.bytesize - pos, remaining].min
        builder << c.byte_slice(pos, take)
        remaining -= take
        pos = 0
      end
      builder.to_s
    end

    # Stream a byte range to IO without allocating the whole slice
    def write_to_io(start : Int32, len : Int32, io : IO)
      return if len <= 0
      raise ArgumentError.new("slice out of bounds") if start < 0 || start + len > @bytesize

      remaining = len
      pos = start
      @chunks.each do |c|
        break if remaining <= 0
        if pos >= c.bytesize
          pos -= c.bytesize
          next
        end
        take = [c.bytesize - pos, remaining].min
        io.write(c.byte_slice(pos, take).to_slice)
        remaining -= take
        pos = 0
      end
    end

    def to_s : String
      b = String::Builder.new
      @chunks.each { |c| b << c.to_s }
      b.to_s
    end

    def chunks_count : Int32
      @chunks.size
    end

    # Drop the first `n` bytes from the buffer (destructive). Useful for incremental compaction.
    def drop_prefix!(n : Int32)
      return if n <= 0
      raise ArgumentError.new("drop_prefix out of bounds") if n > @bytesize

      remaining = n
      while remaining > 0 && !@chunks.empty?
        c = @chunks.first
        if remaining >= c.bytesize
          remaining -= c.bytesize
          @chunks.shift
        else
          # remove prefix from first chunk
          s = c.to_s
          new_s = s.byte_slice(remaining, s.bytesize - remaining)
          @chunks[0] = Chunk.new(new_s)
          remaining = 0
        end
      end

      @bytesize -= n
    end
  end
end
