require "./spec_helper"

describe "Transactions & Markers" do
  it "undo/redo restores markers added inside transaction" do
    pt = Vyx::PieceTable.new("abcdef")
    m1 = pt.add_marker(2, undoable: true)

    pt.apply_transaction do
      pt.insert(1, "XX")
      pt.add_marker(4, undoable: true)
    end

    s = pt.to_s
    snap = pt.marker_snapshot

    pt.undo.should eq(true)
    pt.to_s.should eq("abcdef")
    pt.marker_offset(m1).should eq(2)

    pt.redo.should eq(true)
    pt.to_s.should eq(s)
    pt.marker_snapshot.should eq(snap)
  end

  it "rollback restores markers to pre-transaction state" do
    pt = Vyx::PieceTable.new("abc")
    m = pt.add_marker(1, undoable: true)
    pt.begin_transaction
    pt.insert(0, "X")
    pt.add_marker(2, undoable: true)
    pt.rollback_transaction.should eq(true)
    pt.to_s.should eq("abc")
    pt.marker_offset(m).should eq(1)
  end

  it "compaction preserves markers across undo/redo of transactions" do
    pt = Vyx::PieceTable.new("a" * 100)
    m = pt.add_marker(50, undoable: true)
    pt.apply_transaction do
      pt.insert(10, "xxx")
      pt.insert(20, "yyy")
    end

    pt.compact_prefix!(50)

    s = pt.to_s
    snap = pt.marker_snapshot

    pt.undo.should eq(true)
    pt.to_s.should eq("a" * 100)

    pt.redo.should eq(true)
    pt.to_s.should eq(s)
    pt.marker_snapshot.should eq(snap)
  end
end
