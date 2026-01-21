require "./spec_helper"

describe Vyx::BufferActor do
  it "applies inserts and deletes sequentially" do
    actor = Vyx::BufferActor.new("test")
    actor.insert(0, "hello")
    actor.insert(5, " world")
    # small sleep to allow actor to process messages
    sleep 0.01
    actor.text.should eq("hello world")

    actor.delete(5, 1)
    sleep 0.01
    actor.text.should eq("helloworld")

    actor.stop
  end
end
