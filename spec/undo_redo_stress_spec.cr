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
        pt.add_marker(off, undoable: true)
      when 3
        # remove random marker
        if pt.marker_count > 0
          keys = pt.marker_snapshot.keys
          id = keys.sample
          pt.remove_marker(id, undoable: true)
        end
      when 4
        # compact occasionally
        if rng.rand(10) == 0
          pt.compact_prefix!(rng.rand(0..[pt.add.bytesize, 1].max)) rescue nil
        end
      end

      # occasionally snapshot and exercise undo/redo cycles
      if i % 25 == 0
        # occasionally wrap a small transaction
        if rng.rand(10) == 0
          pt.apply_transaction do
            3.times do
              idx = rng.rand(0..pt.length)
              txt = "x" * rng.rand(1..3)
              pt.insert(idx, txt)
            end
          end
        end

        doc_before = pt.to_s
        # capture markers map
        markers_before = pt.marker_snapshot

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
          next unless pt.marker_snapshot.has_key?(id)
          pt.marker_offset(id).should eq(off)
        end
      end
    end
  end
end
