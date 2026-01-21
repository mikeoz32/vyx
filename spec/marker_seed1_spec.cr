require "../src/vyx"

# Guarded regression test for the seed=1 marker mismatch (VYX-32)
# This test is skipped by default. To run it locally set:
#   RUN_MARKER_REPRO=1 crystal spec spec/marker_seed1_spec.cr

if ENV.has_key?("RUN_MARKER_REPRO") && ENV["RUN_MARKER_REPRO"] == "1"
  describe "marker seed=1 regression (VYX-32)" do
    it "reproduces failing sequence for seed=1" do
      ops = [
        "insert @0 'xxx'",
        "insert @3 'xxx'",
        "remove_marker 50",
        "remove_marker 17",
        "add_marker 101@6",
        "remove_marker 28",
        "insert @1 'xx'",
        "delete @0 len=8",
        "insert @0 'xxxx'",
        "insert @4 'xxxxx'",
        "add_marker 102@7",
        "insert @3 'x'",
        "remove_marker 14",
        "add_marker 103@7",
        "delete @9 len=1",
        "insert @0 'xxxxx'",
        "delete @1 len=8",
        "remove_marker 1",
        "delete @1 len=2",
        "insert @3 'xx'",
        "insert @2 'xx'",
        "remove_marker 62",
        "add_marker 104@2",
        "insert @3 'xxxxx'",
        "delete @5 len=7",
        "insert @1 'x'",
        "remove_marker 22",
        "insert @1 'x'",
        "add_marker 105@8",
        "delete @6 len=1"
      ]

      seed = 1
      rng = Random.new(seed)
      initial = String.build { 100.times { ('a'.ord + rng.rand(26)).chr } }
      pt = Vyx::PieceTable.new(initial)
      model = initial
      label_map = {} of Int32 => Int32
      expected = {} of Int32 => Int32

      # create initial 1..100 markers
      100.times do |i|
        off = rng.rand(0..pt.length)
        id = pt.add_marker(off)
        label_map[i + 1] = id
        expected[i + 1] = off
      end

      ops.each do |op|
        case op
        when /^insert @(\d+) '(.+)'/
          pos = $1.to_i
          text = $2
          pt.insert(pos, text)
          expected.each do |k, v|
            if v >= pos
              expected[k] = v + text.bytesize
            end
          end
          model = model[0, pos] + text + model[pos..-1]

        when /^delete @(\d+) len=(\d+)/
          pos = $1.to_i
          len = $2.to_i
          pt.delete(pos, len)
          expected.each do |k, v|
            if v >= pos && v < pos + len
              expected[k] = pos
            elsif v >= pos + len
              expected[k] = v - len
            end
          end
          model = model[0, pos] + model[pos + len..-1]

        when /^add_marker (\d+)@(\d+)/
          label = $1.to_i
          off = $2.to_i
          new_id = pt.add_marker(off)
          label_map[label] = new_id
          expected[label] = off

        when /^remove_marker (\d+)/
          label = $1.to_i
          id = label_map[label]
          if id
            pt.remove_marker(id)
            expected.delete(label)
          end
        end
      end

      # final assertions: every tracked marker must match expected offset
      expected.each do |lab, exp|
        id = label_map[lab]
        next unless id
        pt.marker_offset(id).should eq(exp)
      end
    end
  end
end
