require "./spec_helper"

describe "Undo/Redo (VYX-32.2)" do
  it "undoes and redoes insert" do
    pt = Vyx::PieceTable.new("abc")
    pt.insert(1, "X")
    pt.to_s.should eq("aXbc")

    pt.undo_available?.should eq(true)
    pt.undo.should eq(true)
    pt.to_s.should eq("abc")

    pt.redo_available?.should eq(true)
    pt.redo.should eq(true)
    pt.to_s.should eq("aXbc")
  end

  it "undoes and redoes delete" do
    pt = Vyx::PieceTable.new("abcd")
    pt.delete(1, 2)
    pt.to_s.should eq("ad")

    pt.undo.should eq(true)
    pt.to_s.should eq("abcd")

    pt.redo.should eq(true)
    pt.to_s.should eq("ad")
  end

  it "undo restores marker positions" do
    pt = Vyx::PieceTable.new("abcde")
    m = pt.add_marker(2)
    pt.insert(1, "XX")
    pt.marker_offset(m).should eq(4)

    pt.undo.should eq(true)
    pt.marker_offset(m).should eq(2)
  end

  it "redo stack cleared when new op performed after undo" do
    pt = Vyx::PieceTable.new("abc")
    pt.insert(1, "X")
    pt.undo.should eq(true)
    pt.redo_available?.should eq(true)
    # perform new op
    pt.insert(0, "Y")
    pt.redo_available?.should eq(false)
  end
end
