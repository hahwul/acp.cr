require "./protocol/v2/updates"
require "./v2_transcript_content"

module ACP
  module V2
    # A detached view of a context compaction reported in a session.
    struct CompactionSnapshot
      # Session containing this compaction.
      getter session_id : String

      # Agent-owned ID scoped to the session.
      getter compaction_id : String

      # Current open status string, initially `in_progress`.
      getter status : String

      # Reported error description, when available.
      getter error : String?

      # Exact compaction metadata after applying patches.
      getter meta_raw : Protocol::RawJson?

      # :nodoc:
      def initialize(@session_id, @compaction_id, @status, @error, @meta_raw, @summary : TranscriptContent::Snapshot)
      end

      # Returns exact summary blocks in receive order.
      def summary_raw : Array(Protocol::RawJson)
        @summary.blocks
      end

      # Decodes the usable display blocks, including custom and future types.
      def summary_blocks : Array(Protocol::ContentBlock)
        Protocol::ContentBlock.decode_v2_array(summary_raw)
      end

      # Whether part of the summary exceeded the store's byte limit.
      def summary_incomplete? : Bool
        @summary.incomplete?
      end
    end

    # Retains ACP v2 compaction patches and streamed summaries in receive order.
    class CompactionStore
      private alias Wire = Protocol::V2

      # Default number of compactions retained across sessions in a store.
      DEFAULT_COMPACTION_LIMIT = 128

      # Default byte budget for each compaction's IDs, fields, and summary.
      DEFAULT_COMPACTION_BYTE_LIMIT = 256 * 1024

      private class Entry
        private DEFAULT_STATUS = "in_progress"

        @status = DEFAULT_STATUS
        @error : String?
        @meta_raw : Protocol::RawJson?
        @summary = TranscriptContent.new
        @identity_bytes : Int64
        @field_bytes : Int64

        def initialize(@session_id : String, @compaction_id : String, @byte_limit : Int32?)
          @identity_bytes = @session_id.bytesize.to_i64 + @compaction_id.bytesize
          @field_bytes = @identity_bytes + @status.bytesize
        end

        def apply(patch : Wire::CompactionUpdate) : Bool
          status = patch.status_present? ? (patch.status || DEFAULT_STATUS) : @status
          error = patch.error_present? ? patch.error : @error
          metadata = patch.apply_metadata_raw(@meta_raw)
          field_bytes = @identity_bytes + status.bytesize + (error.try(&.bytesize) || 0) + (metadata.try(&.json.bytesize) || 0)

          replacement = patch.summary_present?
          summary = patch.summary_raw if replacement
          summary_bytes = replacement ? TranscriptContent.replacement_bytesize(summary) : @summary.bytesize
          if (limit = @byte_limit) && field_bytes + summary_bytes > limit
            # Keep a fitting status even when new error details or metadata exceed the budget.
            status_only_bytes = @field_bytes - @status.bytesize + status.bytesize
            if status_only_bytes + summary_bytes <= limit
              return false unless replacement || status != @status

              error = @error
              metadata = @meta_raw
              field_bytes = status_only_bytes
            elsif !replacement
              return false
            elsif @field_bytes + summary_bytes <= limit || field_bytes > limit
              # A fitting summary still replaces the previous summary if the new fields cannot be retained.
              return @summary.replace(summary, summary_room)
            end
          end

          @status = status
          @error = error
          @meta_raw = metadata
          @field_bytes = field_bytes
          @summary.replace(summary, summary_room) if replacement
          true
        end

        def apply(chunk : Protocol::CompactionSummaryChunkUpdate) : Bool
          @summary.append(chunk.content_raw, summary_room)
        end

        def within_budget? : Bool
          (limit = @byte_limit) ? @field_bytes + @summary.bytesize <= limit : true
        end

        def snapshot : CompactionSnapshot
          CompactionSnapshot.new(@session_id, @compaction_id, @status, @error, @meta_raw, @summary.snapshot)
        end

        private def summary_room : Int64?
          @byte_limit.try { |limit| limit.to_i64 - @field_bytes }
        end
      end

      @compactions = {} of {String, String} => Entry
      @mutex = Mutex.new

      # Creates a store with configurable count and byte limits. Nil removes that limit.
      def initialize(*, @compaction_limit : Int32? = DEFAULT_COMPACTION_LIMIT, @compaction_byte_limit : Int32? = DEFAULT_COMPACTION_BYTE_LIMIT)
        if (limit = @compaction_limit) && limit <= 0
          raise ArgumentError.new("Compaction limit must be positive")
        end
        if (limit = @compaction_byte_limit) && limit <= 0
          raise ArgumentError.new("Compaction byte limit must be positive")
        end
      end

      # Applies an update in receive order. Returns true when it is applied or records a summary gap.
      def observe(params : Wire::SessionUpdateParams) : Bool
        return false unless params.update.session_update.in?("compaction_update", "compaction_summary_chunk")

        case update = params.update.typed
        when Wire::CompactionUpdate, Protocol::CompactionSummaryChunkUpdate
          @mutex.synchronize do
            key = {params.session_id, update.compaction_id}
            if entry = @compactions[key]?
              entry.apply(update)
            elsif (limit = @compaction_limit) && @compactions.size >= limit
              false
            else
              entry = Entry.new(params.session_id, update.compaction_id, @compaction_byte_limit)
              return false unless entry.apply(update) && entry.within_budget?

              @compactions[key] = entry
              true
            end
          end
        else
          false
        end
      end

      # Returns a compaction by its session and ID.
      def compaction(session_id : String, compaction_id : String) : CompactionSnapshot?
        @mutex.synchronize { @compactions[{session_id, compaction_id}]?.try(&.snapshot) }
      end

      # Returns the session's retained compactions in first-seen order.
      def compactions(session_id : String) : Array(CompactionSnapshot)
        @mutex.synchronize do
          @compactions.compact_map { |key, entry| entry.snapshot if key[0] == session_id }
        end
      end

      # Drops the retained compactions for one session.
      def forget_session(session_id : String) : Bool
        @mutex.synchronize do
          before = @compactions.size
          @compactions.reject! { |key, _| key[0] == session_id }
          @compactions.size < before
        end
      end
    end
  end
end
