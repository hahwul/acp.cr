# ACP Protocol — Tool Call Content Helper
#
# Provides a mixin for session update types that include tool call
# content and location arrays (ToolCallUpdate, ToolCallStatusUpdate).
# Both types store `content` and `locations` as `Array(JSON::Any)?`
# for wire compatibility; this helper provides typed accessors.

require "json"
require "./tool_call_content"
require "./raw_json"

module ACP
  module Protocol
    module ToolCallContentHelper
      # Attempts to parse `content` items as typed `ToolCallContent` values.
      # Entries that fail to deserialize are silently skipped.
      def typed_content : Array(ToolCallContent)
        return [] of ToolCallContent unless items = tool_call_content_entries
        items.compact_map do |item|
          ToolCallContent.from_json(item.to_json) rescue nil
        end
      end

      # Attempts to parse `locations` items as typed `ToolCallLocation` values.
      # Entries that fail to deserialize are silently skipped.
      def typed_locations : Array(ToolCallLocation)
        return [] of ToolCallLocation unless items = tool_call_location_entries
        items.compact_map do |item|
          ToolCallLocation.from_json(item.to_json) rescue nil
        end
      end

      protected def tool_call_content_entries
        @content
      end

      protected def tool_call_location_entries
        @locations
      end
    end

    # :nodoc:
    module OptionalToolCallCollection
      def self.from_json(pull : JSON::PullParser) : PreservedJson?
        unless pull.kind.begin_array?
          pull.skip
          return nil
        end

        wire = RawJson.new(pull)
        PreservedJson.new(wire, project_array_objects: true, project_nested_objects: true)
      end

      def self.to_json(values : PreservedJson, json : JSON::Builder) : Nil
        values.to_json(json)
      end
    end

    # :nodoc:
    module ToolCallCollections
      include ToolCallContentHelper

      macro collection(field, entries)
        @[JSON::Field(key: {{field.stringify}}, converter: ::ACP::Protocol::OptionalToolCallCollection)]
        @{{field.id}}_wire : PreservedJson?

        # The collection as editable JSON::Any values, when present.
        def {{field.id}} : Array(JSON::Any)?
          @{{field.id}}_wire.try(&.value).try(&.as_a?)
        end

        # Replaces the collection. Assign nil to omit it.
        def {{field.id}}=(values : Array(JSON::Any)?) : Array(JSON::Any)?
          @{{field.id}}_wire = values.try { |items| PreservedJson.new(JSON::Any.new(items)) }
          values
        end

        # The collection as exact JSON, including unrecognized entries and extension values.
        def {{field.id}}_raw : RawJson?
          @{{field.id}}_wire.try(&.raw)
        end

        protected def {{field.id}}_comparison
          {{field.id}}_raw.try { |wire| wire.to_json_any? || wire }
        end

        protected def {{entries.id}}
          {{field.id}}_raw.try(&.elements?)
        end
      end

      collection content, tool_call_content_entries
      collection locations, tool_call_location_entries
    end
  end
end
