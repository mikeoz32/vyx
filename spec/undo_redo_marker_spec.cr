require "./spec_helper"

describe "Undo/Redo: marker add/remove" do
  it "undoes add_marker and redoes it" do
    pt = Vyx::PieceTable.new("abcdef")
    id = pt.add_marker(2, :after, undoable: true)
    pt.marker_offset(id).should eq(2)

    pt.undo.should eq(true)
    begin
      pt.marker_offset(id)
      raise "expected ArgumentError"
    rescue e : ArgumentError
    end

    pt.redo.should eq(true)
    pt.marker_offset(id).should eq(2)
  end

  it "undoes remove_marker and redoes it" do
    pt = Vyx::PieceTable.new("abcdef")
    id = pt.add_marker(3, :after, undoable: true)
    pt.remove_marker(id, undoable: true)
    begin
      pt.marker_offset(id)
      raise "expected ArgumentError"
    rescue e : ArgumentError
    end

    pt.undo.should eq(true)
    pt.marker_offset(id).should eq(3)

    pt.redo.should eq(true)
    begin
      pt.marker_offset(id)
      raise "expected ArgumentError"
    rescue e : ArgumentError
    end
  end
end
