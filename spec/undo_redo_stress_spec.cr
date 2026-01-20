require "./spec_helper"

describe "Undo/Redo stress" do
  it "all-undo-all-redo restores state across random ops and compaction" do
    rng = Random.new(1234)
    pt = Vyx::PieceTable.new(String.build { 50.times { ('a'.ord + rng.rand(26)).chr } })

    500.times do |i|
      case rng.rand(5)
      when 0
        # insert
        idx = rng.rand(0..pt.length)
        txt = "x" * rng.rand(1..4)
        pt.insert(idx, txt)
      when 1
        # delete
        next if pt.length == 0
        idx = rng.rand(0...pt.length)
        l = rng.rand(1..[1, pt.length - idx].max)
        pt.delete(idx, l)
      when 2
        # add marker
        off = rng.rand(0..pt.length)
        pt.add_marker(off)
      when 3
        # remove random marker
        if pt.marker_count > 0
          id = pt.instance_variable_get(:@markers).keys.sample
          pt.remove_marker(id)
        end
      when 4
        # compact occasionally
        if rng.rand(10) == 0
          pt.compact_prefix!(rng.rand(0..[pt.add.bytesize, 1].max)) rescue nil
        end
      end

      # occasionally snapshot and exercise undo/redo cycles
      if i % 25 == 0
        doc_before = pt.to_s
        # capture markers map
        markers_before = {} of Int32 => Int32
        pt.instance_variable_get(:@markers).each do |id, m|
          begin
            markers_before[id] = pt.marker_offset(id)
          rescue
            # ignore
          end
        end

        # perform all undos
        while pt.undo_available?
          pt.undo
        end

        # then redo them all
        while pt.redo_available?
          pt.redo
        end

        # validate state restored
        doc_before.should eq(pt.to_s)
        markers_before.each do |id, off|
          next unless pt.instance_variable_get(:@markers).has_key?(id)
          pt.marker_offset(id).should eq(off)
        end
      end
    end
  end
end
