require "../vyx"

module Vyx
  # TextBuffer provides a thin, editor-facing wrapper around the PieceTable
  # implementation. It exposes a stable, well-documented API that the Editor
  # layer will consume (cursor/selection, command processor, etc.).
  
  class TextBuffer
    getter piece_table : PieceTable

    def initialize(initial : String = "")
      @piece_table = PieceTable.new(initial)
    end

    # Basic editing API
    def insert(index : Int32, text : String)
      @piece_table.insert(index, text)
      nil
    end

    def delete(index : Int32, len : Int32)
      @piece_table.delete(index, len)
      nil
    end

    def to_s : String
      @piece_table.to_s
    end

    # Marker API (delegated)
    def add_marker(offset : Int32, affinity : Symbol = :after, undoable : Bool = false) : Int32
      @piece_table.add_marker(offset, affinity, undoable)
    end

    def remove_marker(id : Int32, undoable : Bool = false) : Bool
      @piece_table.remove_marker(id, undoable)
    end

    def marker_snapshot : Hash(Int32, Int32)
      @piece_table.marker_snapshot
    end

    # Transaction helpers
    def begin_transaction
      @piece_table.begin_transaction
    end

    def commit_transaction
      @piece_table.commit_transaction
    end

    def rollback_transaction
      @piece_table.rollback_transaction
    end

    def apply_transaction(&blk : Proc(Nil))
      @piece_table.apply_transaction do
        blk.call
      end
      nil
    end

    # Expose some internals for tests
    def length : Int32
      @piece_table.length
    end
  end
end
