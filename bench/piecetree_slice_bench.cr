require "time"
require "../src/vyx"

require "benchmark"

def time_it(label)
  m = Benchmark.measure { yield }
  dur = m.real * 1000.0
  puts "#{label.ljust(35)} #{dur.round(3)}ms"
end

# Prepare a ~1MB document with newlines every 80 chars
text = String.build do |b|
  1024.times do
    80.times { b << ((rand(26) + 'a'.ord).chr) }
    b << '\n'
  end
end

puts "Document size: #{text.bytesize} bytes"
pt = Vyx::PieceTable.new(text)

start = 100
length = 10000

# warmup
10.times { pt.slice(start, length) }

puts "Benchmark (start=#{start} len=#{length})"

# Method 1: slice (build full string)
GC.collect
time_it("slice (full string)") do
  100.times do
    s = pt.slice(start, length)
  end
end

# Method 2: write via builder (collect_write)
GC.collect
time_it("write_slice_to_builder") do
  100.times do
    b = String::Builder.new
    pt.write_slice_to_builder(b, start, length)
    s = b.to_s
  end
end

# Method 3: streaming IO (per piece write)
GC.collect
time_it("write_slice_to_io_streaming (IO::Memory)") do
  100.times do
    io = IO::Memory.new
    pt.write_slice_to_io_streaming(io, start, length)
    # read back to ensure we did the writes
    _ = io.to_s
  end
end

puts "Done"

# Micro-benchmark: many small appends with auto-compaction enabled
puts "\nMicro-benchmark: small appends with auto-compaction (threshold=1024)"
pt2 = Vyx::PieceTable.new("", 1024)
GC.collect
m = Benchmark.measure do
  5000.times do
    pt2.insert(pt2.length, "x")
  end
end
puts "Tiny-inserts time: #{(m.real * 1000.0).round(3)}ms"
puts "pt2 add.bytesize: #{pt2.add.bytesize} bytes (should be <= threshold)"
puts "pt2 add.chunks_count: #{pt2.add.chunks_count} chunks (should be <= threshold)"
puts "pt2 add.chunk_size: #{pt2.add.chunk_size}"
puts "pt2 length: #{pt2.length} bytes"
