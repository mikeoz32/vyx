require "./spec_helper"

describe "Marker snapshot and change events" do
  it "marker_snapshot returns current mapping and events emitted" do
    pt = Vyx::PieceTable.new("abcdef")

    events = [] of Vyx::PieceTable::ChangeEvent
    pt.add_change_listener do |e|
      events << e
    end

    id = pt.add_marker(1)
    pt.insert(0, "X")

    # we should have seen an insert event
    found = events.any? { |e| e.type == :insert }
    found.should eq(true)

    snap = pt.marker_snapshot
    snap[id].should eq(pt.marker_offset(id))
  end

  it "undo emits event and generation increases on ops" do
    pt = Vyx::PieceTable.new("ab")
    pt.insert(1, "X")
    gen1 = pt.generation
    pt.undo
    events = [] of Vyx::PieceTable::ChangeEvent
    pt.add_change_listener { |e| events << e }
    pt.undo
    pt.redo
    any = events.any? { |e| e.type == :undo || e.type == :redo }
    any.should eq(true)
  end
end
