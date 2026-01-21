require "./spec_helper"

describe "Transaction + Marker stress (deterministic)" do
  it "all-undo-all-redo restores document and markers" do
    rng = Random.new(42)
    pt = Vyx::PieceTable.new(String.build { 80.times { ('a'.ord + rng.rand(26)).chr } })

    # small deterministic stress
    markers_before = {} of Int32 => Int32
    300.times do |i|
      case rng.rand(6)
      when 0
        idx = rng.rand(0..pt.length)
        txt = "x" * rng.rand(1..3)
        pt.insert(idx, txt)
      when 1
        next if pt.length == 0
        idx = rng.rand(0...pt.length)
        l = rng.rand(1..[1, pt.length - idx].max)
        pt.delete(idx, l)
      when 2
        off = rng.rand(0..pt.length)
        pt.add_marker(off, undoable: true)
      when 3
        if pt.marker_count > 0
          id = pt.marker_snapshot.keys.sample
          pt.remove_marker(id, undoable: true)
        end
      when 4
        # occasional small transaction
        pt.apply_transaction do
          2.times do
            idx = rng.rand(0..pt.length)
            txt = "x" * rng.rand(1..3)
            pt.insert(idx, txt)
          end
        end
      when 5
        if rng.rand(10) == 0
          pt.compact_prefix!(rng.rand(0..[pt.add.bytesize, 1].max)) rescue nil
        end
      end

      if i % 50 == 0
        markers_before = pt.marker_snapshot
        doc_before = pt.to_s

        while pt.undo_available?
          pt.undo
        end
        while pt.redo_available?
          pt.redo
        end

        doc_before.should eq(pt.to_s)
        markers_before.each do |id, off|
          next unless pt.marker_snapshot.has_key?(id)
          pt.marker_offset(id).should eq(off)
        end
      end
    end
  end
end
