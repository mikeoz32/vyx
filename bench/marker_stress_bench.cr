require "benchmark"
require "../src/vyx"

def time_it(label)
  m = Benchmark.measure { yield }
  dur = m.real * 1000.0
  puts "#{label.ljust(40)} #{dur.round(3)}ms"
end

puts "Marker stress benchmark"

# Configurable params
initial_chars = 50_000
marker_count = 10_000
ops = 5_000

# build initial text
text = String.build do |b|
  initial_chars.times { b << ((rand(26) + 'a'.ord).chr) }
end

pt = Vyx::PieceTable.new(text, 1024 * 1024, 4096, 10000)
puts "doc bytes: #{pt.length}"

# measure marker addition
time_it("add #{marker_count} markers") do
  marker_ids = [] of Int32
  marker_count.times do
    off = rand(0..pt.length)
    marker_ids << pt.add_marker(off)
  end
end

# measure random edits
time_it("perform #{ops} random edits") do
  marker_ids = (1..marker_count).to_a
  ops.times do |i|
    if rand(3) == 0
      # add small marker
      pt.add_marker(rand(0..pt.length))
    else
      if rand(2) == 0
        idx = rand(0..pt.length)
        pt.insert(idx, "x")
      else
        next if pt.length == 0
        idx = rand(0...pt.length)
        l = 1
        pt.delete(idx, l)
      end
    end
  end
end

# sample lookup times
sample_ids = pt.add_marker(0)
# add some markers to sample
s_ids = [] of Int32
1000.times { s_ids << pt.add_marker(rand(0..pt.length)) }

time_it("1000 marker_offset lookups") do
  s_ids.each { |id| _ = pt.marker_offset(id) }
end

puts "Done"
