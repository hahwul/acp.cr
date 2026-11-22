require "./protocol/v2/updates"

module ACP
  module V2
    # Separate ID scopes within an ACP v2 session transcript.
    enum MessageKind
      User
      Agent
      Thought
      Session
    end

    # A detached view of a transcript message and its exact content in receive order.
    struct MessageSnapshot
      # Session containing this message's view.
      getter session_id : String

      # The message's ID scope within the transcript.
      getter kind : MessageKind

      # Opaque ID of this message in its scope.
      getter message_id : String

      # Exact message-scoped metadata after applying patches.
      getter meta_raw : Protocol::RawJson?

      # Whether the store exceeded its budget for part of this message's content.
      getter? content_incomplete : Bool

      # Sender session, when reported for a session-directed message.
      getter sender_session_id : String?

      # Recipient session, when reported for a session-directed message.
      getter recipient_session_id : String?

      # Message ID in the sender's transcript, when reported.
      getter sender_message_id : String?

      # Message ID in the recipient's transcript, when reported.
      getter recipient_message_id : String?

      # :nodoc:
      def initialize(@session_id, @kind, @message_id, @content_base : Protocol::RawJson?, @chunks : Array(Protocol::RawJson),
                     @meta_raw, @content_incomplete, @sender_session_id, @recipient_session_id, @sender_message_id, @recipient_message_id)
      end

      # Returns exact content blocks in receive order.
      def content_raw : Array(Protocol::RawJson)
        blocks = @content_base.try(&.elements?) || [] of Protocol::RawJson
        blocks.concat(@chunks)
      end

      # Decodes the usable display blocks, including custom and future types.
      def content_blocks : Array(Protocol::ContentBlock)
        Protocol::ContentBlock.decode_v2_array(content_raw)
      end

      # Returns well-formed draft skill references in a user message.
      def skill_references : Array(Protocol::V2::SkillReference)
        return [] of Protocol::V2::SkillReference unless kind.user?

        content_raw.compact_map { |block| Protocol::V2::SkillReference.from_content_block(block) }
      end
    end

    # Retains message upserts and streamed content from ACP v2 session updates.
    class MessageStore
      private alias Wire = Protocol::V2

      # Default number of messages retained across sessions in a store.
      DEFAULT_MESSAGE_LIMIT = 512

      # Default byte budget for the retained content, metadata, and IDs of a message.
      DEFAULT_MESSAGE_BYTE_LIMIT = 256 * 1024

      private record Links,
        sender_session_id : String? = nil,
        recipient_session_id : String? = nil,
        sender_message_id : String? = nil,
        recipient_message_id : String? = nil do
        def apply(patch : Wire::SessionMessageUpdate) : self
          Links.new(
            patch.sender_session_id_present? ? patch.sender_session_id : sender_session_id,
            patch.recipient_session_id_present? ? patch.recipient_session_id : recipient_session_id,
            patch.sender_message_id_present? ? patch.sender_message_id : sender_message_id,
            patch.recipient_message_id_present? ? patch.recipient_message_id : recipient_message_id,
          )
        end

        def bytesize : Int64
          {sender_session_id, recipient_session_id, sender_message_id, recipient_message_id}.sum(0_i64) do |id|
            id.try(&.bytesize) || 0
          end
        end
      end

      private class Entry
        @content_base : Protocol::RawJson?
        @chunks = [] of Protocol::RawJson
        @content_bytes = 0_i64
        @content_incomplete = false
        @field_bytes : Int64
        @identity_bytes : Int64
        @meta_raw : Protocol::RawJson?
        @links = Links.new

        # Reserve storage for the raw block's string and the array's element capacity.
        private CHUNK_OVERHEAD = instance_sizeof(String) + 2 * sizeof(Protocol::RawJson) + 1

        def initialize(@session_id : String, @kind : MessageKind, @message_id : String, @byte_limit : Int32?)
          @identity_bytes = @session_id.bytesize.to_i64 + @message_id.bytesize
          @field_bytes = @identity_bytes
        end

        def apply(patch : Wire::MessageUpdate | Wire::SessionMessageUpdate) : Bool
          links = patch.is_a?(Wire::SessionMessageUpdate) ? @links.apply(patch) : @links
          metadata = patch.apply_metadata_raw(@meta_raw)
          field_bytes = @identity_bytes + links.bytesize + (metadata.try(&.json.bytesize) || 0)

          replacement = patch.content_present?
          content = patch.content_raw if replacement
          content = nil if content.try(&.json) == "[]"
          content_bytes = replacement ? (content.try(&.json.bytesize.to_i64) || 0_i64) : @content_bytes
          # A fitting replacement supersedes earlier content even when new links or metadata are too large.
          if (limit = @byte_limit) && field_bytes + content_bytes > limit
            return false unless replacement
            return mark_content_gap(clear: true) if @field_bytes + content_bytes > limit
          else
            @links = links
            @meta_raw = metadata
            @field_bytes = field_bytes
          end
          replace_content(content, content_bytes) if replacement
          true
        end

        def apply(chunk : Wire::MessageChunkUpdate) : Bool
          return false if @content_incomplete

          block = chunk.content_raw
          content_bytes = @content_bytes + block.json.bytesize.to_i64 + CHUNK_OVERHEAD
          if (limit = @byte_limit) && @field_bytes + content_bytes > limit
            return mark_content_gap(clear: false)
          end

          @chunks << block
          @content_bytes = content_bytes
          true
        end

        def fits_identity? : Bool
          (limit = @byte_limit) ? @identity_bytes <= limit : true
        end

        def snapshot : MessageSnapshot
          MessageSnapshot.new(@session_id, @kind, @message_id, @content_base, @chunks.dup, @meta_raw, @content_incomplete,
            @links.sender_session_id, @links.recipient_session_id, @links.sender_message_id, @links.recipient_message_id)
        end

        private def mark_content_gap(*, clear : Bool) : Bool
          changed = !@content_incomplete
          if clear && @content_bytes > 0
            replace_content(nil, 0_i64)
            changed = true
          end
          @content_incomplete = true
          changed
        end

        private def replace_content(base : Protocol::RawJson?, bytes : Int64) : Nil
          @content_base = base
          @chunks = [] of Protocol::RawJson
          @content_bytes = bytes
          @content_incomplete = false
        end
      end

      @messages = {} of {String, MessageKind, String} => Entry
      @mutex = Mutex.new

      # Creates a store with configurable count and byte limits. Nil removes that limit.
      def initialize(*, @message_limit : Int32? = DEFAULT_MESSAGE_LIMIT, @message_byte_limit : Int32? = DEFAULT_MESSAGE_BYTE_LIMIT)
        if (limit = @message_limit) && limit <= 0
          raise ArgumentError.new("Message limit must be positive")
        end
        if (limit = @message_byte_limit) && limit <= 0
          raise ArgumentError.new("Message byte limit must be positive")
        end
      end

      # Applies an update in receive order. Returns true when an update is applied or records a content gap.
      def observe(params : Wire::SessionUpdateParams) : Bool
        kind = case params.update.session_update
               when "user_message", "user_message_chunk"       then MessageKind::User
               when "agent_message", "agent_message_chunk"     then MessageKind::Agent
               when "agent_thought", "agent_thought_chunk"     then MessageKind::Thought
               when "session_message", "session_message_chunk" then MessageKind::Session
               else                                                 return false
               end

        case update = params.update.typed
        when Wire::MessageUpdate, Wire::MessageChunkUpdate, Wire::SessionMessageUpdate
          @mutex.synchronize do
            key = {params.session_id, kind, update.message_id}
            if entry = @messages[key]?
              entry.apply(update)
            elsif (limit = @message_limit) && @messages.size >= limit
              false
            else
              entry = Entry.new(params.session_id, kind, update.message_id, @message_byte_limit)
              return false unless entry.fits_identity? && entry.apply(update)

              @messages[key] = entry
              true
            end
          end
        else
          false
        end
      end

      # Returns a message by its session, kind, and ID.
      def message(session_id : String, kind : MessageKind, message_id : String) : MessageSnapshot?
        @mutex.synchronize { @messages[{session_id, kind, message_id}]?.try(&.snapshot) }
      end

      # Returns this session's retained messages in first-seen order.
      def messages(session_id : String) : Array(MessageSnapshot)
        @mutex.synchronize do
          @messages.compact_map { |key, entry| entry.snapshot if key[0] == session_id }
        end
      end

      # Drops the message history for one session.
      def forget_session(session_id : String) : Bool
        @mutex.synchronize do
          before = @messages.size
          @messages.reject! { |key, _| key[0] == session_id }
          @messages.size < before
        end
      end
    end
  end
end
