require "./spec_helper"

describe Vyx::TextBuffer do
  it "wraps PieceTable insert/delete and exposes to_s" do
    tb = Vyx::TextBuffer.new("hello")
    tb.insert(5, " world")
    tb.to_s.should eq("hello world")

    tb.delete(5, 1)
    tb.to_s.should eq("helloworld")
  end

  it "marker operations delegate to PieceTable and snapshot works" do
    tb = Vyx::TextBuffer.new("abcdef")
    id = tb.add_marker(2)
    snap = tb.marker_snapshot
    snap[id].should eq(2)
  end

  it "transaction helpers delegate and group edits" do
    tb = Vyx::TextBuffer.new("abcdef")
    tb.apply_transaction do
      tb.insert(1, "X")
      tb.insert(3, "Y")
    end
    # Transactions apply sequentially: later ops see effects of earlier ops
    tb.to_s.should eq("aXbcYdef")
    tb.rollback_transaction.should eq(false) # already committed
  end
end
