require "./spec_helper"

describe "Transactions (VYX-32.3)" do
  it "apply_transaction groups ops into one undo step" do
    pt = Vyx::PieceTable.new("abcdef")
    pt.apply_transaction do
      pt.insert(1, "XX")
      pt.insert(3, "YY")
    end

    pt.to_s.should eq("aXXbYYcdef")

    # undo should undo both inserts in one step
    pt.undo.should eq(true)
    pt.to_s.should eq("abcdef")
  end

  it "rollback_transaction undoes applied ops" do
    pt = Vyx::PieceTable.new("abc")
    pt.begin_transaction
    pt.insert(1, "X")
    pt.insert(2, "Y")
    pt.rollback_transaction.should eq(true)
    pt.to_s.should eq("abc")
  end

  it "nested transactions compose as single outer transaction" do
    pt = Vyx::PieceTable.new("abc")
    pt.begin_transaction
    pt.insert(1, "X")
    pt.begin_transaction
    pt.insert(2, "Y")
    pt.commit_transaction
    pt.commit_transaction

    # undo should undo both inserts in one undo
    pt.undo.should eq(true)
    pt.to_s.should eq("abc")
  end
end
