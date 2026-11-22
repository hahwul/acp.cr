require "./protocol/raw_json"

module ACP
  module V2
    # Shared content retention for v2 messages and compaction summaries.
    private class TranscriptContent
      struct Snapshot
        getter? incomplete : Bool

        def initialize(@base : Protocol::RawJson?, @chunks : Array(Protocol::RawJson), @incomplete : Bool)
        end

        def blocks : Array(Protocol::RawJson)
          blocks = @base.try(&.elements?) || [] of Protocol::RawJson
          blocks.concat(@chunks)
        end
      end

      # Reserve storage for each raw block's string and backing array capacity.
      private CHUNK_OVERHEAD = instance_sizeof(String) + 2 * sizeof(Protocol::RawJson) + 1

      @base : Protocol::RawJson?
      @chunks = [] of Protocol::RawJson
      @incomplete = false
      getter bytesize = 0_i64

      def self.replacement_bytesize(base : Protocol::RawJson?) : Int64
        base && base.json != "[]" ? base.json.bytesize.to_i64 : 0_i64
      end

      def replace(base : Protocol::RawJson?, room : Int64?) : Bool
        size = self.class.replacement_bytesize(base)
        if room && size > room
          changed = !@incomplete || @bytesize > 0
          reset(nil, 0_i64)
          @incomplete = true
          return changed
        end

        reset(size.zero? ? nil : base, size)
        true
      end

      def append(block : Protocol::RawJson, room : Int64?) : Bool
        return false if @incomplete

        size = @bytesize + block.json.bytesize.to_i64 + CHUNK_OVERHEAD
        if room && size > room
          @incomplete = true
        else
          @chunks << block
          @bytesize = size
        end
        true
      end

      def snapshot : Snapshot
        Snapshot.new(@base, @chunks.dup, @incomplete)
      end

      private def reset(base : Protocol::RawJson?, bytes : Int64) : Nil
        @base = base
        @chunks = [] of Protocol::RawJson
        @bytesize = bytes
        @incomplete = false
      end
    end
  end
end
