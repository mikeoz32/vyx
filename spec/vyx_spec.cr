require "./spec_helper"

describe Vyx::PieceTable do
  it "creates from string and returns same to_s" do
    pt = Vyx::PieceTable.new("Hello World")
    pt.to_s.should eq("Hello World")
    pt.length.should eq(11)
  end

  it "inserts text in the middle" do
    pt = Vyx::PieceTable.new("Hello World")
    pt.insert(6, "Cruel ")
    pt.to_s.should eq("Hello Cruel World")
  end

  it "deletes a range across pieces" do
    pt = Vyx::PieceTable.new("Hello Cruel World")
    pt.delete(6, 6)
    pt.to_s.should eq("Hello World")
  end

  it "inserts at beginning and end" do
    pt = Vyx::PieceTable.new("abc")
    pt.insert(0, "X")
    pt.insert(pt.length, "Z")
    pt.to_s.should eq("XabcZ")
  end

  it "slices unicode text by bytes" do
    pt = Vyx::PieceTable.new("Hello 世界")
    s = pt.slice(6, 6) # "世界" is 6 bytes (3+3)
    s.should eq("世界")
  end

  it "performs multiple consecutive edits" do
    pt = Vyx::PieceTable.new("start")
    pt.insert(5, "-end")
    pt.insert(0, "beg-")
    pt.insert(4, "M")
    pt.delete(4, 1)
    pt.to_s.should eq("beg-start-end")
  end

  it "maps offsets to positions and back" do
    s = "line1\nsecond line\nthird"
    pt = Vyx::PieceTable.new(s)

    off, col = pt.offset_to_position(0)
    off.should eq(0)
    col.should eq(0)

    l, c = pt.offset_to_position(5) # at newline after line1
    l.should eq(0)
    c.should eq(5)

    pos = pt.offset_to_position(6)
    pos.should eq({1, 0})

    # position -> offset rounds-trip for several positions
    0.upto(10) do |i|
      l, c = pt.offset_to_position(i)
      pt.position_to_offset(l, c).should eq(i)
    end
  end

  it "randomized operations match naive string" do
    rng = Random.new
    100.times do
      s = String.build do |b|
        100.times do
          b << (('a'.ord + (rng.rand(26))).chr)
        end
      end
      pt = Vyx::PieceTable.new(s)
      model = s

      200.times do
        if rng.rand(2) == 0
          # insert
          idx = rng.rand(0..pt.length)
          t = ("x" * (rng.rand(1..5)))
          pt.insert(idx, t)
          model = model[0, idx] + t + model[idx..-1]
        else
          # delete
          next if pt.length == 0
          idx = rng.rand(0...pt.length)
          l = rng.rand(1..[1, pt.length - idx].max)
          pt.delete(idx, l)
          model = model[0, idx] + model[idx + l..-1]
        end
        pt.to_s.should eq(model)
      end
    end
  end

  it "slice_views and write_slice_to_builder work and validate" do
    s = "Hello 世界"
    pt = Vyx::PieceTable.new(s)
    views = pt.slice_views(6, 6)
    builder = String::Builder.new
    views.each do |v|
      v.write_to_builder(builder, pt.original, pt.add)
      v.valid?(pt.generation).should eq(true)
    end
    builder.to_s.should eq("世界")

    # write directly (builder)
    b2 = String::Builder.new
    pt.write_slice_to_builder(b2, 6, 6)
    b2.to_s.should eq("世界")

    # write to IO::Memory (streaming)
    io = IO::Memory.new
    pt.write_slice_to_io_streaming(io, 6, 6)
    io.to_s.should eq("世界")

    # invalidation
    first = views.first
    pt.insert(0, "X")
    first.valid?(pt.generation).should eq(false)
  end

  it "compacts add buffer into original and invalidates views" do
    pt = Vyx::PieceTable.new("a")
    100.times { pt.insert(pt.length, "x") }
    before = pt.to_s
    gen0 = pt.generation
    views = pt.slice_views(0, 1)
    pt.compact!
    pt.to_s.should eq(before)
    pt.generation.should be > gen0
    views.first.valid?(pt.generation).should eq(false)
  end

  it "AddBuffer supports append, slice and streaming write" do
    b = Vyx::AddBuffer.new(8)
    s1 = "abcd"
    s2 = "efghijk"
    off1 = b.append(s1)
    off2 = b.append(s2)
    b.bytesize.should eq(s1.bytesize + s2.bytesize)
    b.byte_slice(off1, s1.bytesize).should eq(s1)
    b.byte_slice(off2, s2.bytesize).should eq(s2)
    io = IO::Memory.new
    b.write_to_io(off1, s1.bytesize + s2.bytesize, io)
    io.to_s.should eq(s1 + s2)
  end

  it "auto compacts when threshold exceeded" do
    # use small threshold to trigger auto compaction (bytesize)
    pt = Vyx::PieceTable.new("a", 16)
    10.times { pt.insert(pt.length, "xx") } # total 20 bytes > threshold
    # compaction should have been triggered at least once, leaving add buffer small (<= threshold)
    pt.add.bytesize.should be <= 16
    pt.to_s.should eq("a" + "x" * 20)
  end

  it "compacts when chunk count exceeded" do
    # use large bytes threshold to disable bytesize compaction, but small chunk limit
    pt = Vyx::PieceTable.new("a", 1_000_000, 4, 4) # add_chunk_size=4, chunk_limit=4
    10.times { pt.insert(pt.length, "xxxx") } # each append is chunk-sized
    pt.add.chunks_count.should be <= 4
    pt.to_s.should eq("a" + "x" * 40)
    # metrics updated
    pt.compaction_count.should be > 0
    pt.total_compaction_time_ms.should be >= 0.0
  end

  it "incremental compact_prefix! moves prefix and preserves content" do
    pt = Vyx::PieceTable.new("A")
    # create add buffer content: "bbbb..." in small chunks
    10.times { pt.insert(pt.length, "bbbb") }
    before = pt.to_s
    gen0 = pt.generation
    # move first 8 bytes into original
    pt.compact_prefix!(8)
    pt.to_s.should eq(before)
    pt.generation.should be > gen0
    pt.add.bytesize.should be < (10 * 4)
  end

  it "handles unicode characters (multi-byte) slicing and positions" do
    s = "aé𝄞🙂"
    pt = Vyx::PieceTable.new(s)

    # collect per-character byte offsets
    offsets = [] of Tuple(String, Int32, Int32)
    pos = 0
    while pos < s.bytesize
      lead = s.byte_slice(pos, 1).each_byte.first
      len = if (lead & 0x80) == 0
        1
      elsif (lead & 0xE0) == 0xC0
        2
      elsif (lead & 0xF0) == 0xE0
        3
      else
        4
      end
      ch = s.byte_slice(pos, len)
      offsets << {ch, pos, len}
      pos += len
    end

    offsets.each do |t|
      ch = t[0]
      off = t[1]
      len = t[2]
      pt.slice(off, len).should eq(ch)
      l, c = pt.offset_to_position(off)
      l.should eq(0)
      c.should eq(off)
    end
  end

  it "inserts and deletes unicode and preserves correctness" do
    s = "Hello 世界"
    pt = Vyx::PieceTable.new(s)
    smile = "🙂"
    pt.insert(6, smile)
    pt.to_s.should eq("Hello " + smile + "世界")
    # delete the smile (bytesize)
    pt.delete(6, smile.bytesize)
    pt.to_s.should eq(s)
  end

  it "compaction preserves unicode content and invalidates views" do
    s = "αβγ"
    pt = Vyx::PieceTable.new(s)
    pt.insert(pt.length, "𝄞🙂")
    before = pt.to_s
    views = pt.slice_views(0, pt.length)
    gen0 = pt.generation
    pt.compact!
    pt.to_s.should eq(before)
    pt.generation.should be > gen0
    # previous views should be invalid
    views.each do |v|
      v.valid?(pt.generation).should eq(false)
    end

    # marker migration
    m1 = pt.add_marker(1)
    off1 = pt.marker_offset(m1)
    pt.insert(0, "xyz")
    off2 = pt.marker_offset(m1)
    off2.should eq(off1 + 3)

    # compaction preserves marker positions
    pt.compact!
    pt.marker_offset(m1).should eq(off2)
  end
end
