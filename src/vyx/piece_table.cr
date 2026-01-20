# Piece table implementation (simple piece table / piece sequence)
# Inspired by VSCode PieceTree approach (but simplified for first iteration)

require "./add_buffer"
require "benchmark"

module Vyx
  # A piece references a contiguous range in either the original buffer or the add buffer
  class Piece
    enum Source
      ORIGINAL
      ADD
    end

    getter source : Source
    getter start_bytes : Int32
    getter bytes_len : Int32

    def initialize(@source : Source, @start_bytes : Int32, @bytes_len : Int32)
    end
  end

  # Ephemeral view into a buffer slice (no allocation until requested)
  class PieceSlice
    getter source : Piece::Source
    getter start_bytes : Int32
    getter bytes_len : Int32
    getter generation : Int32

    def initialize(@source : Piece::Source, @start_bytes : Int32, @bytes_len : Int32, @generation : Int32)
    end

    # Write slice to a String::Builder without allocating an intermediate string when possible
    def write_to_builder(builder : String::Builder, original : String, add : AddBuffer)
      src = @source == Piece::Source::ORIGINAL ? original : add
      builder << src.byte_slice(@start_bytes, @bytes_len)
    end

    # Write slice directly to IO (streaming, allocates per piece slice)
    def write_to_io(io : IO, original : String, add : AddBuffer)
      src = @source == Piece::Source::ORIGINAL ? original : add
      io.write(src.byte_slice(@start_bytes, @bytes_len).to_slice)
    end

    # Convert slice to String (allocates)
    def to_s(original : String, add : AddBuffer)
      src = @source == Piece::Source::ORIGINAL ? original : add
      src.byte_slice(@start_bytes, @bytes_len)
    end

    # Validate slice against current piece table generation
    def valid?(current_generation : Int32)
      @generation == current_generation
    end
  end

  # Balanced PieceTable (Treap) for O(log n) edits
  class PieceTable
    getter original : String
    getter add : AddBuffer
    getter root : Node?

    class Node
      getter piece : Piece
      property left : Node?
      property right : Node?
      property priority : Int32
      getter subtree_bytes : Int32
      getter subtree_newlines : Int32
      getter last_line_bytes : Int32
      property parent : Node?
      # markers stored as sorted list of {offset_in_piece, marker_id}
      property markers : Array(Tuple(Int32, Int32))

      def initialize(piece : Piece)
        @piece = piece
        @left = nil
        @right = nil
        @parent = nil
        @priority = Random.new.rand(1_000_000_000).to_i32
        @subtree_bytes = piece.bytes_len
        @subtree_newlines = 0
        @last_line_bytes = piece.bytes_len
        @markers = [] of Tuple(Int32, Int32)
        # Note: call update!(original, add) from PieceTable after creating node
      end

      def update!(original : String, add : AddBuffer)
        left_bytes = @left.nil? ? 0 : @left.as(Node).subtree_bytes
        right_bytes = @right.nil? ? 0 : @right.as(Node).subtree_bytes
        @subtree_bytes = left_bytes + @piece.bytes_len + right_bytes

        left_newlines = @left.nil? ? 0 : @left.as(Node).subtree_newlines
        right_newlines = @right.nil? ? 0 : @right.as(Node).subtree_newlines
        piece_newlines = 0
        src = @piece.source == Piece::Source::ORIGINAL ? original : add
        if @piece.bytes_len > 0
          slice = src.byte_slice(@piece.start_bytes, @piece.bytes_len)
          slice.each_byte do |b|
            piece_newlines += 1 if b == 10
          end
        end
        @subtree_newlines = left_newlines + piece_newlines + right_newlines

        # compute last_line_bytes (bytes after last newline in subtree)
        if !@right.nil?
          @last_line_bytes = @right.as(Node).last_line_bytes
        else
          # compute tail in piece
          tail_in_piece = 0
          if @piece.bytes_len > 0
            slice = src.byte_slice(@piece.start_bytes, @piece.bytes_len)
            last = -1
            i = 0
            slice.each_byte do |b|
              last = i if b == 10
              i += 1
            end
            if last == -1
              tail_in_piece = slice.bytesize
            else
              tail_in_piece = slice.bytesize - (last + 1)
            end
          end

          if tail_in_piece > 0
            @last_line_bytes = tail_in_piece
          else
            @last_line_bytes = @left.nil? ? 0 : @left.as(Node).last_line_bytes
          end
        end
      end
    end

    # compaction_threshold: when add buffer bytesize exceeds this value compact! will be triggered automatically
    # compaction_chunk_limit: when number of chunks in add buffer exceeds this value compact! will be triggered automatically (0 = disabled)
    def initialize(original = "", compaction_threshold : Int32 = 64 * 1024, add_chunk_size : Int32 = 4096, compaction_chunk_limit : Int32 = 0)
      @original = original
      @add = AddBuffer.new(add_chunk_size)
      @root = nil
      @generation = 0
      @compaction_threshold = compaction_threshold
      @compaction_chunk_limit = compaction_chunk_limit
      @compaction_count = 0
      @total_compaction_time_ms = 0.0

      # marker state
      @next_marker_id = 1
      @markers = {} of Int32 => Marker
      @marker_lock = Mutex.new

      # Undo/Redo stacks (store original forward operations)
      @undo_stack = [] of Operation
      @redo_stack = [] of Operation
      @suppress_undo_record = false

      # change listeners for external sync (VYX-32)
      @change_listeners = [] of Proc(ChangeEvent, Nil)

      if @original.bytesize > 0
        node = Node.new(Piece.new(Piece::Source::ORIGINAL, 0, @original.bytesize))
        node.as(Node).update!(@original, @add)
        @root = node
      end
    end

    # generation number to validate ephemeral views
    property compaction_threshold : Int32
    property compaction_chunk_limit : Int32

    # Metrics
    getter compaction_count : Int32
    getter total_compaction_time_ms : Float64

    def generation : Int32
      @generation
    end

    def marker_count : Int32
      @markers.size
    end

    # Debug helper: return [global_offset, node_piece_start, node_piece_len, offset_in_piece]
    def debug_marker_info(id : Int32)
      unless @markers.has_key?(id)
        raise ArgumentError.new("unknown marker")
      end
      m = @markers[id]
      node = m.node
      off = m.offset_in_piece
      goff = marker_offset(id)
      if node
        return {goff, node.piece.start_bytes, node.piece.bytes_len, off}
      else
        return {goff, -1, -1, off}
      end
    end

    def debug_dump_markers : Array(String)
      lines = [] of String
      inorder_nodes(@root).each do |n|
        start = absolute_offset_by_node(n, 0)
        items = n.markers.map { |p| "(off=#{p[0]} id=#{p[1]})" }.join(", ")
        lines << "node[start=#{start} len=#{n.piece.bytes_len}] markers: [#{items}]"
      end
      # absolute-markers
      abs = [] of String
      @markers.each do |id, m|
        if m.node.nil?
          abs << "id=#{id} abs_off=#{m.offset_in_piece}"
        end
      end
      lines.concat(["absolute: [#{abs.join(", ")}]"])
      lines
    end

    # Marker APIs
    class Marker
      getter id : Int32
      getter affinity : Symbol
      property node : Node?
      property offset_in_piece : Int32

      def initialize(@id : Int32, @affinity : Symbol, @node : Node?, @offset_in_piece : Int32)
      end
    end

    # Operation representation for undo/redo (store forward-op)
    class Operation
      getter kind : Symbol
      getter index : Int32
      getter text : String
      getter meta : Hash(String, String)
      getter sub_ops : Array(Operation)?

      def initialize(@kind : Symbol, @index : Int32, @text : String = "", @meta = {} of String => String, @sub_ops : Array(Operation)? = nil)
      end
    end

    # Event type for clients to resync on edits or undo/redo
    class ChangeEvent
      getter type : Symbol
      getter generation : Int32
      getter details : Hash(String, String)

      def initialize(@type : Symbol, @generation : Int32, @details : Hash(String, String) = {} of String => String)
      end
    end

    private def internal_add_marker_with_id(id : Int32, abs_offset : Int32, affinity : Symbol = :after)
      abs = [[abs_offset, 0].max, length].min
      node, off = find_node_and_offset(abs)
      m = Marker.new(id, affinity, node, off)
      @markers[id] = m
      if node
        node_insert_marker(node, id, off)
      end
      if @next_marker_id <= id
        @next_marker_id = id + 1
      end
      id
    end

    # add/remove change listeners
    def add_change_listener(&block : Proc(ChangeEvent, Nil)) : Proc(ChangeEvent, Nil)
      @change_listeners << block
      block
    end

    def remove_change_listener(listener : Proc(ChangeEvent, Nil)) : Bool
      @change_listeners.delete(listener)
    end

    private def emit_change(type : Symbol, details = {} of String => String)
      evt = ChangeEvent.new(type, @generation, details)
      @change_listeners.each do |cb|
        begin
          cb.call(evt)
        rescue
          # swallow listener errors
        end
      end
    end

    def add_marker(offset : Int32, affinity : Symbol = :after, undoable : Bool = false) : Int32
      raise ArgumentError.new("offset out of bounds") if offset < 0 || offset > length
      node, off_in_piece = find_node_and_offset(offset)
      id = @next_marker_id
      @next_marker_id += 1
      m = Marker.new(id, affinity, node, off_in_piece)
      @markers[id] = m
      if node
        node_insert_marker(node, id, off_in_piece)
      end

      # record undo for marker add only if requested
      if undoable && !@suppress_undo_record
        aff_code = affinity == :after ? 0 : 1
        record_operation(Operation.new(:add_marker, offset, "", {"id" => id.to_s, "aff" => aff_code.to_s}))
      end

      validate_marker_invariants
      id
    end

    # Undo/Redo API
    def undo_available? : Bool
      !@undo_stack.empty?
    end

    def redo_available? : Bool
      !@redo_stack.empty?
    end

    def undo : Bool
      return false if @undo_stack.empty?
      op = @undo_stack.pop
      if ENV.has_key?("VYX_DEBUG") && ENV["VYX_DEBUG"] == "1"
        puts "UNDO apply op=#{op.kind} idx=#{op.index} text=#{op.text} meta=#{op.meta.inspect}"
      end
      @suppress_undo_record = true
      case op.kind
      when :insert
        # inverse is delete at same index and length
        delete(op.index, op.text.bytesize)
      when :delete
        insert(op.index, op.text)
      when :add_marker
        # undo an add_by removing the marker id
        id = op.meta["id"]
        if id
          remove_marker(id)
        end
      when :remove_marker
        id = op.meta["id"]
        if id
          aff = op.meta.has_key?("aff") && op.meta["aff"] == 1 ? :before : :after
          internal_add_marker_with_id(id, op.index, aff)
        end
      else
        @suppress_undo_record = false
        return false
      end
      @suppress_undo_record = false
      @redo_stack << op

      # emit undo change event
      emit_change(:undo, {"kind" => op.kind.to_s})

      true
    end

    def redo : Bool
      return false if @redo_stack.empty?
      op = @redo_stack.pop
      if ENV.has_key?("VYX_DEBUG") && ENV["VYX_DEBUG"] == "1"
        puts "REDO apply op=#{op.kind} idx=#{op.index} text=#{op.text} meta=#{op.meta.inspect}"
      end
      @suppress_undo_record = true
      case op.kind
      when :insert
        insert(op.index, op.text)
      when :delete
        delete(op.index, op.text.bytesize)
      when :add_marker
        id = op.meta["id"]
        if id
          aff = op.meta.has_key?("aff") && op.meta["aff"] == 1 ? :before : :after
          internal_add_marker_with_id(id, op.index, aff)
          if ENV.has_key?("VYX_DEBUG") && ENV["VYX_DEBUG"] == "1"
            puts "redo add_marker id=#{id} meta=#{op.meta} markers=#{@markers.keys.inspect}"
          end
        end
      when :remove_marker
        id = op.meta["id"]
        if id
          remove_marker(id)
        end
      else
        @suppress_undo_record = false
        return false
      end
      @suppress_undo_record = false
      @undo_stack << op

      # emit redo change event
      emit_change(:redo, {"kind" => op.kind.to_s})

      true
    end

    private def node_insert_marker(node : Node, id : Int32, offset_in_piece : Int32)
      # insert into sorted markers array
      idx = 0
      while idx < node.markers.size && node.markers[idx][0] < offset_in_piece
        idx += 1
      end
      node.markers.insert(idx, {offset_in_piece, id})
      # update global marker record
      if @markers[id]
        @markers[id].node = node
        @markers[id].offset_in_piece = offset_in_piece
      end
      if ENV.has_key?("VYX_DEBUG") && ENV["VYX_DEBUG"] == "1"
        puts "node_insert_marker id=#{id} node_start=#{absolute_offset_by_node(node, 0)} node_len=#{node.piece.bytes_len} offset_in_piece=#{offset_in_piece}"
      end
    end

    private def node_remove_marker(node : Node, id : Int32)
      i = 0
      while i < node.markers.size
        pair = node.markers[i]
        if pair[1] == id
          # set marker to absolute offset
          abs = absolute_offset_by_node(node, pair[0])
          node.markers.delete_at(i)
          if @markers[id]
            @markers[id].node = nil
            @markers[id].offset_in_piece = abs
          end
          if ENV.has_key?("VYX_DEBUG") && ENV["VYX_DEBUG"] == "1"
            puts "node_remove_marker id=#{id} orig_pair_offset=#{pair[0]} abs=#{abs}"
          end
          return true
        end
        i += 1
      end
      false
    end

    private def node_shift_markers(node : Node, start_offset : Int32, delta : Int32)
      # add delta to all markers with offset >= start_offset
      node.markers.each_with_index do |pair, i|
        if pair[0] >= start_offset
          node.markers[i] = {pair[0] + delta, pair[1]}
          # update global marker record
          mid = pair[1]
          if @markers[mid]
            @markers[mid].offset_in_piece = pair[0] + delta
            @markers[mid].node = node
          end
        end
      end
      if ENV.has_key?("VYX_DEBUG") && ENV["VYX_DEBUG"] == "1"
        puts "node_shift_markers node_start=#{absolute_offset_by_node(node,0)} start_offset=#{start_offset} delta=#{delta} new_markers=#{node.markers.inspect}"
      end
    end

    def remove_marker(id : Int32, undoable : Bool = false)
      unless @markers.has_key?(id)
        return false
      end
      m = @markers[id]

      # capture absolute offset and affinity for undo
      begin
        abs = marker_offset(id)
      rescue
        abs = [[m.offset_in_piece, 0].max, length].min
      end
      aff = m.affinity

      if m.node
        node_remove_marker(m.node.not_nil!, id)
      end

      @markers.delete(id)

      # record undo for marker remove only if requested
      if undoable && !@suppress_undo_record
        aff_code = aff == :after ? 0 : 1
        record_operation(Operation.new(:remove_marker, abs, "", {"id" => id.to_s, "aff" => aff_code.to_s}))
      end

      validate_marker_invariants
      true
    end

    def marker_offset(id : Int32) : Int32
      unless @markers.has_key?(id)
        raise ArgumentError.new("unknown marker")
      end
      m = @markers[id]
      if m.node.nil?
        # stored absolute offset
        return [[m.offset_in_piece, 0].max, length].min
      end
      global_offset_for_node(m.node, m.offset_in_piece)
    end

    # VYX-32: Return markers inside [start, start+len) as Array of {id, offset}
    def markers_in_range(start : Int32, len : Int32) : Array(Tuple(Int32, Int32))
      raise ArgumentError.new("start out of bounds") if start < 0 || start > length
      return [] of Tuple(Int32, Int32) if len <= 0
      end_off = [start + len, length].min

      res = [] of Tuple(Int32, Int32)
      @markers.each do |id, m|
        begin
          off = marker_offset(id)
        rescue
          next
        end
        if off >= start && off < end_off
          res << {id, off}
        end
      end

      # sort by offset for deterministic ordering
      res.sort_by { |t| t[1] }
    end

    private def global_offset_for_node(target : Node?, offset_in_piece : Int32) : Int32
      return 0 if target.nil?
      # start with offset in node: left subtree bytes + offset_in_piece
      offset = bytes_of(target.left) + offset_in_piece
      node = target
      while node.parent
        parent = node.parent.not_nil!
        # if node is right child, add left subtree bytes and parent's piece length
        if parent.left == node
          # node is left child: nothing additional
        else
          offset += bytes_of(parent.left) + parent.piece.bytes_len
        end
        node = parent
      end
      offset
    end

    private def compact_if_needed
      # Trigger compaction if bytesize threshold exceeded
      if @compaction_threshold > 0 && @add.bytesize > @compaction_threshold
        compact!
        return
      end

      # Trigger compaction if chunk count threshold exceeded (0 = disabled)
      if @compaction_chunk_limit > 0 && @add.chunks_count > @compaction_chunk_limit
        compact!
      end
    end

    # Find the node that contains the byte at global offset and return [node, offset_in_piece]
    private def find_node_and_offset(offset : Int32) : Tuple(Node?, Int32)
      raise ArgumentError.new("offset out of bounds") if offset < 0 || offset > length
      remaining = offset
      node = @root

      while node
        left = node.left
        left_bytes = bytes_of(left)
        if remaining < left_bytes
          node = left
          next
        end

        remaining -= left_bytes
        if remaining < node.piece.bytes_len
          return {node, remaining}
        end

        remaining -= node.piece.bytes_len
        node = node.right
      end

      # offset at end of document => place at rightmost node, offset at end
      if @root
        last = rightmost_node(@root)
        if last
          return {last, last.piece.bytes_len}
        end
      end

      return {nil, 0}
    end

    def length : Int32
      bytes_of(@root)
    end

    private def bytes_of(node : Node?) : Int32
      return 0 if node.nil?
      node.subtree_bytes
    end

    def to_s : String
      builder = String::Builder.new
      inorder_traverse(@root).each do |p|
        src = p.source == Piece::Source::ORIGINAL ? @original : @add
        builder << src.byte_slice(p.start_bytes, p.bytes_len)
      end
      builder.to_s
    end

    # Write a slice directly to an IO in streaming fashion (writes per piece-slice)
    def write_slice_to_io_streaming(io : IO, start_bytes : Int32, len : Int32)
      raise ArgumentError.new("start out of bounds") if start_bytes < 0 || start_bytes > length
      return if len <= 0
      views = slice_views(start_bytes, len)
      views.each do |v|
        src = v.source == Piece::Source::ORIGINAL ? @original : @add
        io.write(src.byte_slice(v.start_bytes, v.bytes_len).to_slice)
      end
    end

    # Convenience: write to IO using builder for a single write (may allocate intermediate string)
    def write_slice_to_io(io : IO, start_bytes : Int32, len : Int32)
      builder = String::Builder.new
      write_slice_to_builder(builder, start_bytes, len)
      io.write(builder.to_s)
    end

    def slice(start_bytes : Int32, len : Int32) : String
      raise ArgumentError.new("start out of bounds") if start_bytes < 0 || start_bytes > length
      return "" if len <= 0
      builder = String::Builder.new
      collect_write(@root, start_bytes, len, builder)
      builder.to_s
    end

    # Return ephemeral views covering the range (no allocation); views are tagged with current generation
    def slice_views(start_bytes : Int32, len : Int32) : Array(PieceSlice)
      raise ArgumentError.new("start out of bounds") if start_bytes < 0 || start_bytes > length
      return [] of PieceSlice if len <= 0
      views = [] of PieceSlice
      collect_views(@root, start_bytes, len, views)
      views
    end

    # Write bytes directly into a String::Builder (zero-copy mostly)
    def write_slice_to_builder(builder : String::Builder, start_bytes : Int32, len : Int32)
      raise ArgumentError.new("start out of bounds") if start_bytes < 0 || start_bytes > length
      return if len <= 0
      collect_write(@root, start_bytes, len, builder)
    end

    # Map byte offset -> (line, column) where line and column are zero-based and column is bytes since last newline
    def offset_to_position(offset : Int32) : Tuple(Int32, Int32)
      raise ArgumentError.new("offset out of bounds") if offset < 0 || offset > length
      remaining = offset
      node = @root
      line = 0

      while node
        left = node.left
        left_bytes = bytes_of(left)
        if remaining < left_bytes
          node = left
          next
        end

        remaining -= left_bytes
        left_newlines = left ? left.as(Node).subtree_newlines : 0

        if remaining < node.piece.bytes_len
          # inside piece at remaining
          newlines_in_piece = count_newlines_in_piece(node.piece, 0, remaining)
          line += left_newlines + newlines_in_piece

          last_nl = last_newline_pos_in_piece(node.piece, 0, remaining)
          if last_nl >= 0
            col = remaining - (last_nl + 1)
          else
            left_tail = left ? left.as(Node).last_line_bytes : 0
            col = left_tail + remaining
          end

          return {line, col}
        end

        # skip piece
        remaining -= node.piece.bytes_len
        line += left_newlines + count_newlines_in_piece(node.piece, 0, node.piece.bytes_len)
        node = node.right
      end

      # offset at end -> line is total newlines, column is last_line_bytes
      total_newlines = @root.nil? ? 0 : @root.as(Node).subtree_newlines
      last_col = @root.nil? ? 0 : @root.as(Node).last_line_bytes
      {total_newlines, last_col}
    end

    # Map (line, column) -> offset (bytes). Clamps column if exceeds line length.
    def position_to_offset(line : Int32, col : Int32) : Int32
      raise ArgumentError.new("line must be >= 0") if line < 0 || col < 0
      node = @root
      offset_acc = 0
      target_line = line

      while node
        left = node.left
        left_newlines = left ? left.as(Node).subtree_newlines : 0
        if target_line < left_newlines
          node = left
          next
        end

        target_line -= left_newlines
        offset_acc += bytes_of(left)

        piece_lines = count_newlines_in_piece(node.piece, 0, node.piece.bytes_len)
        if target_line < piece_lines
          # inside piece: find start of the target line
          nth = target_line
          start_of_line = if nth == 0
            0
          else
            prev_nl = nth_newline_position_in_piece(node.piece, nth - 1)
            prev_nl + 1
          end

          # clamp col to available bytes till next newline or end
          next_nl_pos = nth_newline_position_in_piece(node.piece, nth)
          line_len = if next_nl_pos >= 0
            next_nl_pos - start_of_line
          else
            node.piece.bytes_len - start_of_line
          end
          c = [col, line_len].min
          return offset_acc + start_of_line + c
        elsif target_line == piece_lines
          # the line immediately after piece's last newline - start at end of piece
          start_of_line_offset = offset_acc + node.piece.bytes_len
          # clamp column against (right subtree's first line length if exists) - but simple: add col
          return start_of_line_offset + col
        else
          target_line -= piece_lines
          offset_acc += node.piece.bytes_len
          node = node.right
        end
      end

      # if we walked off the end, position is after buffer
      length + col
    end

    # Helpers for piece newline counting
    private def count_newlines_in_piece(piece : Piece, start : Int32, len : Int32) : Int32
      return 0 if len <= 0
      src = piece.source == Piece::Source::ORIGINAL ? @original : @add
      slice = src.byte_slice(piece.start_bytes + start, len)
      cnt = 0
      slice.each_byte do |b|
        cnt += 1 if b == 10
      end
      cnt
    end

    private def last_newline_pos_in_piece(piece : Piece, start : Int32, len : Int32) : Int32
      return -1 if len <= 0
      src = piece.source == Piece::Source::ORIGINAL ? @original : @add
      slice = src.byte_slice(piece.start_bytes + start, len)
      last = -1
      i = 0
      slice.each_byte do |b|
        last = i if b == 10
        i += 1
      end
      last
    end

    private def piece_tail_len(piece : Piece) : Int32
      pos = last_newline_pos_in_piece(piece, 0, piece.bytes_len)
      if pos == -1
        piece.bytes_len
      else
        piece.bytes_len - (pos + 1)
      end
    end

    private def nth_newline_position_in_piece(piece : Piece, nth : Int32) : Int32
      # returns byte index of nth newline (0-based) or -1 if not found
      return -1 if nth < 0
      src = piece.source == Piece::Source::ORIGINAL ? @original : @add
      slice = src.byte_slice(piece.start_bytes, piece.bytes_len)
      cnt = 0
      i = 0
      slice.each_byte do |b|
        if b == 10
          return i if cnt == nth
          cnt += 1
        end
        i += 1
      end
      -1
    end
    def insert(index : Int32, text : String)
      raise ArgumentError.new("index out of bounds") if index < 0 || index > length
      return if text.empty?

      # snapshot marker absolute offsets BEFORE mutation and apply insert shift to snapshot
      snapshot = snapshot_all_marker_offsets

      add_len = text.bytesize
      snapshot.each do |id, off|
        if off >= index
          snapshot[id] = off + add_len
        end
      end

      add_start = @add.append(text)
      new_piece = Piece.new(Piece::Source::ADD, add_start, add_len)
      new_node = Node.new(new_piece)

      left, right = split(@root, index)
      # update new_node (it contains piece referencing add buffer)
      new_node.update!(@original, @add)
      @root = merge(merge(left, new_node), right)

      @generation += 1

      # apply shifts for absolute markers as before
      shift_absolute_markers(index, add_len)

      # remap all markers using the precomputed snapshot (already adjusted for insert)
      remap_all_markers(snapshot)
      validate_marker_invariants

      # record undo (store forward operation) unless this is an undo/redo application
      unless @suppress_undo_record
        record_operation(Operation.new(:insert, index, text))
      end

      # emit change event for external sync
      emit_change(:insert, {"index" => index.to_s, "len" => add_len.to_s})

      compact_if_needed
    end

    private def snapshot_all_marker_offsets : Hash(Int32, Int32)
      snap = {} of Int32 => Int32
      @markers.each do |id, m|
        begin
          snap[id] = marker_offset(id)
        rescue
          snap[id] = [[m.offset_in_piece, 0].max, length].min
        end
      end
      snap
    end

    private def remap_all_markers(snapshot : Hash(Int32, Int32)? = nil)
      # take snapshot of absolute offsets for all markers if not provided
      if snapshot.nil?
        snapshot = {} of Int32 => Int32
        @markers.each do |id, m|
          if m.node
            top = m.node.not_nil!
            while top.parent
              top = top.parent.not_nil!
            end
            if top == @root
              snapshot[id] = global_offset_for_node(m.node, m.offset_in_piece)
            else
              snapshot[id] = [[m.offset_in_piece, 0].max, length].min
            end
          else
            snapshot[id] = [[m.offset_in_piece, 0].max, length].min
          end
        end
      end

      # clear node marker lists
      inorder_nodes(@root).each do |n|
        n.markers = [] of Tuple(Int32, Int32)
      end

      if ENV.has_key?("VYX_DEBUG") && ENV["VYX_DEBUG"] == "1"
        puts "remap snapshot (clamped): #{snapshot.map { |id,abs| "#{id}->#{[[abs,0].max,length].min}" }.join(", ")}"
      end

      # re-insert markers based on absolute offsets (clamp before lookup)
      snapshot.each do |id, abs|
        abs_clamped = [[abs, 0].max, length].min
        node, off = find_node_and_offset(abs_clamped)
        if node
          node_insert_marker(node, id, off)
          @markers[id].node = node
          @markers[id].offset_in_piece = off
        else
          @markers[id].node = nil
          @markers[id].offset_in_piece = abs_clamped
        end
      end

      # debug: compare remapped offsets to the snapshot we used
      if ENV.has_key?("VYX_DEBUG") && ENV["VYX_DEBUG"] == "1"
        snapshot.each do |id, abs|
          expected = [[abs, 0].max, length].min
          begin
            got = marker_offset(id)
          rescue
            got = nil
          end
          if got != expected
            puts "REMAPPING DISCREPANCY id=#{id} snapshot=#{abs} expected_clamped=#{expected} got=#{got}"
            puts "marker debug: id=#{id} entry=#{@markers[id].inspect}"
            puts "node dump:\n  #{debug_dump_markers.join("\n  ")}"
            raise "Remap discrepancy for marker #{id}"
          end
        end
      end

    end

    # Snapshot of markers for clients (id -> absolute offset)
    def marker_snapshot : Hash(Int32, Int32)
      snap = {} of Int32 => Int32
      @markers.each do |id, m|
        begin
          snap[id] = marker_offset(id)
        rescue
          snap[id] = [[m.offset_in_piece, 0].max, length].min
        end
      end
      snap
    end

    private def validate_marker_invariants
      # no-op unless debugging enabled via ENV
      return true unless ENV.has_key?("VYX_DEBUG") && ENV["VYX_DEBUG"] == "1"

      # gather reachable nodes
      nodes = inorder_nodes(@root)
      node_set = {} of Node => Bool
      nodes.each { |n| node_set[n] = true }

      # ensure all markers referencing nodes point into current tree
      @markers.each do |id, m|
        if m.node
          n = m.node.not_nil!
          unless node_set.has_key?(n)
            raise "Invariant failed: marker id=#{id} references detached node"
          end
        end
      end

      # ensure node.marker lists are consistent with @markers and offsets
      nodes.each do |n|
        n.markers.each do |off_id|
          off = off_id[0]
          mid = off_id[1]
          m = @markers[mid]
          unless m
            raise "Invariant failed: node has marker id=#{mid} not present in @markers"
          end
          unless m.node == n
            raise "Invariant failed: marker id=#{mid} node mismatch (node list vs @markers)"
          end
          unless m.offset_in_piece == off
            raise "Invariant failed: marker id=#{mid} offset mismatch (node list=#{off} global=#{m.offset_in_piece})"
          end
          if off < 0 || off > n.piece.bytes_len
            raise "Invariant failed: marker id=#{mid} offset #{off} out of bounds for node (len=#{n.piece.bytes_len})"
          end
        end
      end

      true
    end

    private def shift_absolute_markers(index : Int32, delta : Int32)
      return if delta == 0
      @markers.each do |id, m|
        if m.node.nil?
          if m.offset_in_piece >= index
            m.offset_in_piece += delta
          end
        end
      end
    end

    def delete(index : Int32, len : Int32)
      raise ArgumentError.new("index out of bounds") if index < 0 || index >= length
      return if len <= 0
      to_delete = [len, length - index].min

      # snapshot marker offsets BEFORE mutation and apply delete transform to snapshot
      snapshot = snapshot_all_marker_offsets
      snapshot.each do |id, off|
        if off >= index && off < index + to_delete
          snapshot[id] = index
        elsif off >= index + to_delete
          snapshot[id] = off - to_delete
        end
      end

      # capture deleted text before discarding mid
      deleted = slice(index, to_delete)

      left, rest = split(@root, index)
      mid, right = split(rest, to_delete)



      # mid discarded
      @root = merge(left, right)

      @generation += 1

      # shift absolute markers for deleted range: markers in [index, index+to_delete) move to index, markers after shrink
      @markers.each do |id, m|
        if m.node.nil?
          if m.offset_in_piece >= index && m.offset_in_piece < index + to_delete
            m.offset_in_piece = index
          elsif m.offset_in_piece >= index + to_delete
            m.offset_in_piece -= to_delete
          end
        end
      end

      # final remap for absolute markers using precomputed snapshot
      remap_all_markers(snapshot)
      validate_marker_invariants

      # record undo (store forward operation) unless this is an undo/redo application
      unless @suppress_undo_record
        record_operation(Operation.new(:delete, index, deleted))
      end

      # emit change event
      emit_change(:delete, {"index" => index.to_s, "len" => to_delete.to_s})
    end

    # transaction & rollback helpers
    private def record_operation(op : Operation)
      if defined?(transaction_stack) && transaction_stack.size > 0
        transaction_stack.last << op
      else
        @undo_stack << op
        @redo_stack.clear
      end
    end

    # perform inverse of an operation (caller should set @suppress_undo_record = true)
    private def perform_inverse(op : Operation)
      case op.kind
      when :insert
        delete(op.index, op.text.bytesize)
      when :delete
        insert(op.index, op.text)
      when :add_marker
        id = (op.meta.has_key?("id") ? op.meta["id"].to_i : nil)
        remove_marker(id)
      when :remove_marker
        id = (op.meta.has_key?("id") ? op.meta["id"].to_i : nil)
        if id
          aff = op.meta.has_key?("aff") && op.meta["aff"].to_i == 1 ? :before : :after
          internal_add_marker_with_id(id, op.index, aff)
        end
      when :transaction
        if op.sub_ops
          op.sub_ops.reverse_each do |sub|
            perform_inverse(sub)
          end
        end
      else
        # no-op for unknown kinds
      end
    end

    private def transaction_stack : Array(Array(Operation))
      @transaction_stack ||= [] of Array(Operation)
    end

    def begin_transaction
      transaction_stack << [] of Operation
      nil
    end

    def rollback_transaction
      ops = transaction_stack.pop
      return false unless ops
      @suppress_undo_record = true
      ops.reverse_each do |op|
        perform_inverse(op)
      end
      @suppress_undo_record = false
      true
    end

    def commit_transaction
      ops = transaction_stack.pop
      return false unless ops
      trans = Operation.new(:transaction, 0, "", {} of String => String, ops)
      if transaction_stack.size > 0
        transaction_stack.last << trans
      else
        @undo_stack << trans
        @redo_stack.clear
        emit_change(:transaction, {"count" => ops.size.to_s})
      end
      true
    end

    def apply_transaction
      begin_transaction
      begin
        yield
      rescue
        rollback_transaction
        raise
      ensure
        if transaction_stack.size > 0
          commit_transaction
        end
      end
    end

    private def collect_marker_ids(node : Node?, arr : Array(Int32))
      return if node.nil?
      collect_marker_ids(node.left, arr)
      node.markers.each do |off_id|
        arr << off_id[1]
      end
      collect_marker_ids(node.right, arr)
    end

    # Compact: coalesce all current content into the original buffer and reset add buffer.
    # This will rebuild the tree as a single ORIGINAL piece and increment generation.
    def compact!
      # snapshot marker offsets
      marker_offsets = {} of Int32 => Int32
      @markers.each do |id, m|
        marker_offsets[id] = global_offset_for_node(m.node, m.offset_in_piece)
      end

      m = Benchmark.measure do
        doc = to_s
        @original = doc
        # preserve configured chunk size when resetting add buffer
        @add = AddBuffer.new(@add.chunk_size)

        if @original.bytesize > 0
          @root = Node.new(Piece.new(Piece::Source::ORIGINAL, 0, @original.bytesize))
          @root.as(Node).update!(@original, @add)
        else
          @root = nil
        end

        @generation += 1
      end
      dur_ms = m.real * 1000.0
      @compaction_count += 1
      @total_compaction_time_ms += dur_ms

      # remap markers by offset
      marker_offsets.each do |id, off|
        m = @markers[id]
        node, off_in_piece = find_node_and_offset(off)
        if m && m.node
          node_remove_marker(m.node.not_nil!, id)
        end
        if node
          node_insert_marker(node, id, off_in_piece)
          m.node = node
          m.offset_in_piece = off_in_piece
        else
          # no node found, place at end
          if @root
            last = rightmost_node(@root)
            if last
              node_insert_marker(last, id, last.piece.bytes_len)
              m.node = last
              m.offset_in_piece = last.piece.bytes_len
            end
          end
        end
      end

      # final remap for absolute markers
      remap_all_markers

      # emit compaction event for external listeners
      emit_change(:compact, {} of String => String)
    end

    private def rightmost_node(node : Node?) : Node?
      return nil if node.nil?
      cur = node
      while cur.right
        cur = cur.right.as(Node)
      end
      cur
    end

    private def leftmost_node(node : Node?) : Node?
      return nil if node.nil?
      cur = node
      while cur.left
        cur = cur.left.as(Node)
      end
      cur
    end

    private def inorder_nodes(node : Node?) : Array(Node)
      result = [] of Node
      return result if node.nil?
      result.concat(inorder_nodes(node.left))
      result << node
      result.concat(inorder_nodes(node.right))
      result
    end

    private def absolute_offset_by_node(target : Node, offset_in_piece : Int32) : Int32
      res = 0
      inorder_nodes(@root).each do |n|
        if n == target
          res += offset_in_piece
          return res
        end
        res += n.piece.bytes_len
      end
      res
    end

    # Incremental compaction: move first `bytes` bytes from add buffer into original
    # This is less disruptive than full compaction and can be used to amortize compaction work.
    def compact_prefix!(bytes : Int32)
      return if bytes <= 0 || @add.bytesize == 0
      take = [bytes, @add.bytesize].min

      m = Benchmark.measure do
        orig_len = @original.bytesize
        moved = @add.byte_slice(0, take)
        @original += moved

        # Drop moved bytes from add buffer
        @add.drop_prefix!(take)

        # Rebuild piece list with prefix moved to original
        pieces = inorder_traverse(@root)
        new_pieces = [] of Piece
        pieces.each do |p|
          if p.source == Piece::Source::ORIGINAL
            new_pieces << p
          else
            pstart = p.start_bytes
            plen = p.bytes_len
            if pstart >= take
              # entirely in remaining add buffer
              new_pieces << Piece.new(Piece::Source::ADD, pstart - take, plen)
            else
              # overlap
              moved_len = [take - pstart, plen].min
              # moved part -> ORIGINAL at orig_len + pstart
              new_pieces << Piece.new(Piece::Source::ORIGINAL, orig_len + pstart, moved_len)
              rem_len = plen - moved_len
              if rem_len > 0
                new_start = pstart + moved_len - take
                new_pieces << Piece.new(Piece::Source::ADD, new_start, rem_len)
              end
            end
          end
        end

        # coalesce adjacent pieces of same source and contiguous ranges
        coalesced = [] of Piece
        new_pieces.each do |p|
          if coalesced.empty?
            coalesced << p
          else
            last = coalesced.last
            if last.source == p.source && last.start_bytes + last.bytes_len == p.start_bytes
              # merge
              coalesced[coalesced.size - 1] = Piece.new(last.source, last.start_bytes, last.bytes_len + p.bytes_len)
            else
              coalesced << p
            end
          end
        end

        # rebuild tree from coalesced pieces
        new_root = nil
        coalesced.each do |p|
          n = Node.new(p)
          n.as(Node).update!(@original, @add)
          new_root = merge(new_root, n)
        end

        @root = new_root
        @generation += 1
      end

      dur_ms = m.real * 1000.0
      @compaction_count += 1
      @total_compaction_time_ms += dur_ms
    end

    private def inorder_traverse(node : Node?) : Array(Piece)
      result = [] of Piece
      return result if node.nil?
      result.concat(inorder_traverse(node.left))
      result << node.piece
      result.concat(inorder_traverse(node.right))
      result
    end

    private def collect_views(node : Node?, idx : Int32, remaining : Int32, views : Array(PieceSlice)) : Int32
      return 0 if node.nil? || remaining <= 0
      left_bytes = bytes_of(node.left)
      written = 0

      if idx < left_bytes
        # from left subtree
        w = collect_views(node.left, idx, remaining, views)
        written += w
        remaining -= w
        # from this node
        if remaining > 0
          take_here = [node.piece.bytes_len, remaining].min
          if take_here > 0
            views << PieceSlice.new(node.piece.source, node.piece.start_bytes, take_here, @generation)
            written += take_here
            remaining -= take_here
          end
        end
        if remaining > 0
          w2 = collect_views(node.right, 0, remaining, views)
          written += w2
        end
        return written
      elsif idx < left_bytes + node.piece.bytes_len
        # start in this piece
        offset_in_piece = idx - left_bytes
        take = [node.piece.bytes_len - offset_in_piece, remaining].min
        views << PieceSlice.new(node.piece.source, node.piece.start_bytes + offset_in_piece, take, @generation)
        written += take
        remaining -= take
        if remaining > 0
          w = collect_views(node.right, 0, remaining, views)
          written += w
        end
        return written
      else
        # skip left + piece
        new_idx = idx - (left_bytes + node.piece.bytes_len)
        return collect_views(node.right, new_idx, remaining, views)
      end
    end

    private def collect_write(node : Node?, idx : Int32, remaining : Int32, builder : String::Builder) : Int32
      return 0 if node.nil? || remaining <= 0
      left_bytes = bytes_of(node.left)
      written = 0

      if idx < left_bytes
        w = collect_write(node.left, idx, remaining, builder)
        written += w
        remaining -= w
        if remaining > 0
          take = [node.piece.bytes_len, remaining].min
          if take > 0
            src = node.piece.source == Piece::Source::ORIGINAL ? @original : @add
            builder << src.byte_slice(node.piece.start_bytes, take)
            written += take
            remaining -= take
          end
        end
        if remaining > 0
          w2 = collect_write(node.right, 0, remaining, builder)
          written += w2
        end
        return written
      elsif idx < left_bytes + node.piece.bytes_len
        offset_in_piece = idx - left_bytes
        take = [node.piece.bytes_len - offset_in_piece, remaining].min
        src = node.piece.source == Piece::Source::ORIGINAL ? @original : @add
        builder << src.byte_slice(node.piece.start_bytes + offset_in_piece, take)
        written += take
        remaining -= take
        if remaining > 0
          w = collect_write(node.right, 0, remaining, builder)
          written += w
        end
        return written
      else
        new_idx = idx - (left_bytes + node.piece.bytes_len)
        return collect_write(node.right, new_idx, remaining, builder)
      end
    end

    # split node into {left, right} where left contains first `bytes` bytes
    private def split(node : Node?, bytes : Int32) : Tuple(Node?, Node?)
      return {nil, nil} if node.nil?
      left_bytes = bytes_of(node.left)

      if bytes < left_bytes
        l, r = split(node.left, bytes)
        node.left = r
        if r
          r.not_nil!.parent = node
        end
        node.update!(@original, @add)
        return {l, node}
      elsif bytes > left_bytes + node.piece.bytes_len
        l, r = split(node.right, bytes - left_bytes - node.piece.bytes_len)
        node.right = l
        if l
          l.not_nil!.parent = node
        end
        node.update!(@original, @add)
        return {node, r}
      else
        # split inside this node's piece
        left_len = bytes - left_bytes
        right_len = node.piece.bytes_len - left_len

        left_node = nil
        right_node = nil

        if left_len > 0
          left_piece = Piece.new(node.piece.source, node.piece.start_bytes, left_len)
          left_node = Node.new(left_piece)
          left_node.left = node.left
          if left_node.left
            left_node.left.not_nil!.parent = left_node
          end
          left_node.update!(@original, @add)
        else
          left_node = node.left
        end

        if right_len > 0
          right_piece = Piece.new(node.piece.source, node.piece.start_bytes + left_len, right_len)
          right_node = Node.new(right_piece)
          right_node.right = node.right
          if right_node.right
            right_node.right.not_nil!.parent = right_node
          end
          right_node.update!(@original, @add)
        else
          right_node = node.right
        end

        # move markers from original node into left/right nodes appropriately
        if !node.markers.empty?
          # node.markers is Array(Tuple(offset, id))
          left_list = [] of Tuple(Int32, Int32)
          right_list = [] of Tuple(Int32, Int32)
          node.markers.each do |off_id|
            off = off_id[0]
            mid_id = off_id[1]
            m = @markers[mid_id]
            if off < left_len
              left_list << {off, mid_id}
              if left_node.is_a?(Node)
                m.node = left_node
                m.offset_in_piece = off
              else
                # attach to predecessor subtree's rightmost node
                pred = rightmost_node(node.left)
                if pred
                  node_insert_marker(pred, mid_id, pred.piece.bytes_len)
                  m.node = pred
                  m.offset_in_piece = pred.piece.bytes_len
                else
                  # no predecessor, save absolute offset and leave node nil; remap on next op
                  abs = absolute_offset_by_node(node, off)
                  m.node = nil
                  m.offset_in_piece = abs
                end
              end
            else
              new_off = off - left_len
              right_list << {new_off, mid_id}
              if right_node.is_a?(Node)
                m.node = right_node
                m.offset_in_piece = new_off
              else
                # attach to successor subtree's leftmost node
                succ = leftmost_node(node.right)
                if succ
                  node_insert_marker(succ, mid_id, 0)
                  m.node = succ
                  m.offset_in_piece = 0
                else
                  abs = absolute_offset_by_node(node, off)
                  m.node = nil
                  m.offset_in_piece = abs
                end
              end
            end
          end
          if left_node.is_a?(Node)
            left_node.markers = left_list
          end
          if right_node.is_a?(Node)
            right_node.markers = right_list
          end
        end

        return {left_node, right_node}
      end
    end

    private def merge(a : Node?, b : Node?) : Node?
      return b if a.nil?
      return a if b.nil?
      if a.priority < b.priority
        a.right = merge(a.right, b)
        if a.right
          a.right.not_nil!.parent = a
        end
        a.update!(@original, @add)
        a
      else
        b.left = merge(a, b.left)
        if b.left
          b.left.not_nil!.parent = b
        end
        b.update!(@original, @add)
        b
      end
    end
  end
end
