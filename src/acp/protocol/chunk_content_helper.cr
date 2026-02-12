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
        if (h = @content.as_h?) && h["text"]?
          h["text"].as_s
        elsif s = @content.as_s?
          s
        else
          @content.to_json
        end
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
          ContentChunk.new(block, @meta)
        end
      end
    end
  end
end
