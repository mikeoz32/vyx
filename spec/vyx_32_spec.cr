require "./spec_helper"

describe "VYX-32: markers_in_range" do
  it "returns markers within a range (simple)" do
    pt = Vyx::PieceTable.new("abcdefghij")

    ids = [] of Int32
    10.times do |i|
      ids << pt.add_marker(i)
    end

    res = pt.markers_in_range(2, 4) # covers offsets [2,6)
    offsets = res.map { |t| t[1] }
    offsets.should eq([2, 3, 4, 5])
  end

  it "reflects updates after insert/delete" do
    pt = Vyx::PieceTable.new("abcd")
    a = pt.add_marker(0)
    b = pt.add_marker(1)
    c = pt.add_marker(3)

    # insert at 1 (shifts b and c right by 2)
    pt.insert(1, "xx")
    pt.marker_offset(a).should eq(0)
    pt.marker_offset(b).should eq(3)
    pt.marker_offset(c).should eq(5)

    res = pt.markers_in_range(2, 3) # [2,5)
    found_b = res.any? { |t| t[0] == b }
    found_a = res.any? { |t| t[0] == a }
    found_b.should eq(true)
    found_a.should eq(false)
  end
end
