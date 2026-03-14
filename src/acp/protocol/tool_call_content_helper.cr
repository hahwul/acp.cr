# ACP Protocol — Tool Call Content Helper
#
# Provides a mixin for session update types that include tool call
# content and location arrays (ToolCallUpdate, ToolCallStatusUpdate).
# Both types store `content` and `locations` as `Array(JSON::Any)?`
# for wire compatibility; this helper provides typed accessors.

require "json"
require "./tool_call_content"

module ACP
  module Protocol
    module ToolCallContentHelper
      # Attempts to parse `content` items as typed `ToolCallContent` values.
      # Entries that fail to deserialize are silently skipped.
      def typed_content : Array(ToolCallContent)
        return [] of ToolCallContent unless items = @content
        items.compact_map do |item|
          ToolCallContent.from_json(item.to_json) rescue nil
        end
      end

      # Attempts to parse `locations` items as typed `ToolCallLocation` values.
      # Entries that fail to deserialize are silently skipped.
      def typed_locations : Array(ToolCallLocation)
        return [] of ToolCallLocation unless items = @locations
        items.compact_map do |item|
          ToolCallLocation.from_json(item.to_json) rescue nil
        end
      end
    end
  end
end
