require "./spec_helper"

describe "Delete & Marker Undo" do
  it "undo restores markers to original offsets after delete" do
    pt = Vyx::PieceTable.new("abcdef")
    m1 = pt.add_marker(2, undoable: true)

    # delete range that includes marker => marker should move to delete index
    pt.delete(1, 3) # deletes bcd
    pt.marker_offset(m1).should eq(1)

    # undo should restore marker to original absolute offset
    pt.undo.should eq(true)
    pt.marker_offset(m1).should eq(2)
  end
end
