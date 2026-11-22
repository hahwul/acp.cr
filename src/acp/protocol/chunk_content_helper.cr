# ACP Protocol — Chunk Content Helper
#
# Provides a mixin for session update types that wrap a content block
# in a message chunk (user_message_chunk, agent_message_chunk,
# agent_thought_chunk).

require "json"
require "./content_block"

module ACP
  module Protocol
    module ChunkContentHelper
      # Helper to get the actual text content regardless of wrapping.
      def text : String
        value = content
        if text = value.as_h?.try(&.[]?("text")).try(&.as_s?)
          text
        else
          value.as_s? || chunk_content_json(value)
        end
      end

      protected def chunk_content_json(value : JSON::Any) : String
        value.to_json
      end

      # Attempts to parse the content as a typed ContentBlock.
      # Returns nil if parsing fails.
      def content_block : ContentBlock?
        if @content.as_h?
          ContentBlock.from_json(@content.to_json) rescue nil
        end
      end

      # Returns a ContentChunk wrapping the parsed content block, if possible.
      def to_content_chunk : ContentChunk?
        if block = content_block
          ContentChunk.new(block, @meta, @message_id)
        end
      end
    end

    # :nodoc:
    module LosslessMessageChunk
      include ChunkContentHelper
      include LosslessContentField
      include LosslessMetadata
      include WireValueEquality

      # Optional ID correlating chunks of the same logical message.
      @[JSON::Field(key: "messageId", converter: ::ACP::Protocol::OptionalContentValue(String))]
      property message_id : String?

      # Reads the typed block from the exact content.
      def content_block : ContentBlock?
        wire = content_raw
        ContentBlock.from_json(wire.json) if wire.object?
      rescue JSON::Error
        nil
      end

      # Wraps the typed block with its message ID and exact chunk metadata.
      def to_content_chunk : ContentChunk?
        if block = content_block
          ContentChunk.new(block, metadata_wire: @metadata_wire, message_id: @message_id)
        end
      end

      protected def chunk_content_json(_value : JSON::Any) : String
        content_raw.json
      end
    end
  end
end
