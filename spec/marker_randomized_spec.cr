require "./spec_helper"

describe Vyx::PieceTable do
  it "randomized marker correctness" do
    rng = Random.new
    # modest sizes for spec
    initial = String.build { 100.times { ('a'.ord + rng.rand(26)).chr } }
    pt = Vyx::PieceTable.new(initial)
    model = initial

    markers = {} of Int32 => Int32 # id -> offset

    # add some markers
    100.times do
      off = rng.rand(0..pt.length)
      id = pt.add_marker(off)
      markers[id] = off
    end

    ops_history = [] of String
    500.times do |it|
      if rng.rand(3) == 0
        # add or remove marker
        if rng.rand(2) == 0 && markers.size < 200
          off = rng.rand(0..pt.length)
          id = pt.add_marker(off)
          markers[id] = off
          ops_history << "add_marker #{id}@#{off}"
        elsif markers.size > 0
          id = markers.keys.sample
          pt.remove_marker(id)
          markers.delete(id)
          ops_history << "remove_marker #{id}"
        end
      else
        # edit
        if rng.rand(2) == 0
          # insert
          idx = rng.rand(0..pt.length)
          text = ("x" * (rng.rand(1..5)))
          pt.insert(idx, text)
          model = model[0, idx] + text + model[idx..-1]
          # update naive marker offsets
          markers.each do |k, v|
            if v >= idx
              markers[k] = v + text.bytesize
            end
          end
          ops_history << "insert @#{idx} '#{text}'"
        else
          # delete
          next if pt.length == 0
          idx = rng.rand(0...pt.length)
          l = rng.rand(1..[1, pt.length - idx].max)
          pt.delete(idx, l)
          model = model[0, idx] + model[idx + l..-1]
          markers.each do |k, v|
            if v >= idx && v < idx + l
              # move to idx
              markers[k] = idx
            elsif v >= idx + l
              markers[k] = v - l
            end
          end
          ops_history << "delete @#{idx} len=#{l}"
        end
      end

      # Validate markers match model via pt.marker_offset
      markers.each do |k, v|
        got = pt.marker_offset(k)
        if got != v
          puts "Mismatch! marker=#{k} expected=#{v} got=#{got}"
          puts "doc: #{pt.to_s}"
          puts "ops (tail 10): #{ops_history.last(10).inspect}"
          puts "markers sample: #{markers.to_a.first(20).inspect}"
          begin
            info = pt.debug_marker_info(k)
            puts "marker_info: #{info.inspect}"
            puts "marker dump:\n  #{pt.debug_dump_markers.join("\n  ")}"
          rescue e
            puts "debug info failed: #{e.message}"
          end
          raise "marker mismatch"
        end
      end
      # Validate markers match model via pt.marker_offset
      markers.each do |k, v|
        got = pt.marker_offset(k)
        if got != v
          puts "Mismatch! marker=#{k} expected=#{v} got=#{got}"
          puts "doc: #{pt.to_s}"
          puts "markers sample: #{markers.to_a.first(20).inspect}"
          begin
            info = pt.debug_marker_info(k)
            puts "marker_info: #{info.inspect}"
          rescue e
            puts "debug info failed: #{e.message}"
          end
          raise "marker mismatch"
        end
      end

      pt.to_s.should eq(model)
    end
  end
end
