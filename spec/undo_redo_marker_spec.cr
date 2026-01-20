require "./spec_helper"

describe "Undo/Redo: marker add/remove" do
  it "undoes add_marker and redoes it" do
    pt = Vyx::PieceTable.new("abcdef")
    id = pt.add_marker(2)
    pt.marker_offset(id).should eq(2)

    pt.undo.should eq(true)
    { -> pt.marker_offset(id) }.should raise_error(ArgumentError)

    pt.redo.should eq(true)
    pt.marker_offset(id).should eq(2)
  end

  it "undoes remove_marker and redoes it" do
    pt = Vyx::PieceTable.new("abcdef")
    id = pt.add_marker(3)
    pt.remove_marker(id)
    { -> pt.marker_offset(id) }.should raise_error(ArgumentError)

    pt.undo.should eq(true)
    pt.marker_offset(id).should eq(3)

    pt.redo.should eq(true)
    { -> pt.marker_offset(id) }.should raise_error(ArgumentError)
  end
end
