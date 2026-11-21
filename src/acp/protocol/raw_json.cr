require "./wire_frame"

module ACP
  module Protocol
    # JSON retained without rounding numbers or dropping explicit nulls.
    struct RawJson
      # JSON text, compacted for newline-delimited transport.
      getter json : String

      private def initialize(@json : String)
      end

      # Wraps a representable JSON value.
      def self.new(value : JSON::Any) : self
        new(WireFrame.encode(value))
      end

      # Parses exact JSON, including numeric values beyond JSON::Any.
      def self.from_json(value : String) : self
        WireFrame.new(value)
        new(JSON::PullParser.new(value))
      end

      # Reads one JSON value without narrowing its numbers.
      def self.new(pull : JSON::PullParser) : self
        new(WireFrame.read_raw(pull))
      end

      # Whether the value is a JSON object.
      def object? : Bool
        @json.starts_with?('{')
      end

      # Whether the value is a JSON array.
      def array? : Bool
        @json.starts_with?('[')
      end

      # Reads the elements of an array without narrowing numbers.
      def elements? : Array(RawJson)?
        return unless array?

        elements = [] of RawJson
        pull = JSON::PullParser.new(@json)
        pull.read_array { elements << RawJson.new(pull) }
        elements
      end

      # Whether the value is JSON null.
      def null? : Bool
        @json == "null"
      end

      # Reads a signed JSON integer in the Int64 range.
      def as_i64? : Int64?
        @json.to_i64?
      end

      # Reads a string or returns nil for other JSON values.
      def as_s? : String?
        JSON.parse(@json).as_s if @json.starts_with?('"')
      end

      # Reads an object's members without narrowing their values.
      def members? : Hash(String, RawJson)?
        return unless object?

        members = {} of String => RawJson
        pull = JSON::PullParser.new(@json)
        pull.read_object { |key| members[key] = RawJson.new(pull) }
        members
      end

      # Reads a member without projecting the rest of the object.
      def field(name : String) : RawJson?
        if object? && (value = WireFrame.field(@json, name))
          RawJson.new(JSON::PullParser.new(value))
        end
      end

      # Decodes values that fit within JSON::Any.
      def to_json_any : JSON::Any
        JSON.parse(@json)
      end

      # Projects representable values into JSON::Any.
      def to_json_any? : JSON::Any?
        to_json_any
      rescue JSON::ParseException
        nil
      end

      # Writes the JSON value directly.
      def to_json(builder : JSON::Builder) : Nil
        builder.raw(@json)
      end

      # Replaces an object member, preserving the other fields as exact JSON.
      def with_field(name : String, value : RawJson) : RawJson
        replace_field(name, value)
      end

      # Removes an object member, preserving the other fields as exact JSON.
      def without_field(name : String) : RawJson
        replace_field(name, nil)
      end

      private def replace_field(name : String, value : RawJson?) : RawJson
        raise ArgumentError.new("JSON value must be an object") unless object?

        pull = JSON::PullParser.new(@json)
        wire = JSON.build do |builder|
          builder.max_nesting = pull.max_nesting
          builder.object do
            pull.read_object do |key|
              if key == name
                pull.skip
              else
                builder.field(key) { pull.read_raw(builder) }
              end
            end
            builder.field(name, value) if value
          end
        end
        RawJson.new(JSON::PullParser.new(wire))
      end
    end

    # :nodoc:
    module LosslessOpenObject
      include LosslessUnmapped

      protected def keep_exact_unmapped?(_key : String) : Bool
        true
      end

      # The complete object, including exact extension values.
      def raw : RawJson
        RawJson.new(JSON::PullParser.new(WireFrame.encode(self)))
      end

      # Extension metadata scoped to the object.
      def meta : Hash(String, JSON::Any)?
        @json_unmapped["_meta"]?.try(&.as_h?)
      end

      # Exact extension metadata scoped to the object.
      def meta_raw : RawJson?
        if metadata = exact_unmapped_json("_meta")
          RawJson.new(JSON::PullParser.new(metadata)) if metadata.starts_with?('{')
        end
      end
    end

    # :nodoc:
    # Keeps exact JSON behind an existing mutable JSON::Any accessor.
    struct PreservedJson
      private alias ObjectView = Hash(String, JSON::Any)

      private record BlockSource, view : ObjectView, raw : RawJson, projected : String, partial : Bool,
        nested_views : Hash(String, ObjectView)? = nil do
        def same_nested_objects? : Bool
          return true unless objects = nested_views

          objects.all? { |key, original| view[key]?.try(&.as_h?).try(&.same?(original)) == true }
        end
      end

      getter value : JSON::Any?
      getter? partial = false
      @source : RawJson?
      @projected : String?
      @block_sources : Hash(UInt64, BlockSource)?
      @block_order : Array(UInt64?)?
      @project_nested_objects = false

      def initialize(@value : JSON::Any)
      end

      def initialize(pull : JSON::PullParser, *, project_object_members : Bool = false, project_array_objects : Bool = false)
        initialize(RawJson.new(pull), project_object_members: project_object_members, project_array_objects: project_array_objects)
      end

      def initialize(source : RawJson, *, project_object_members : Bool = false, project_array_objects : Bool = false,
                     object_entries_only : Bool = false, @project_nested_objects : Bool = false)
        @source = source
        if project_array_objects && (elements = source.elements?)
          elements.select!(&.object?) if object_entries_only
          @value = project_blocks(elements)
        else
          @value = source.to_json_any?
          if @value.nil? && project_object_members && (object = project_members(source))
            @value = object
            @partial = true
          end
        end
        @projected = @value.try { |value| WireFrame.encode(value) }
      end

      private def project_members(source : RawJson, *, nested : Bool = @project_nested_objects) : JSON::Any?
        return unless members = source.members?

        projection = {} of String => JSON::Any
        members.each do |key, value|
          projected = value.to_json_any?
          projected ||= project_members(value, nested: false) if nested && value.object?
          projection[key] = projected if projected
        end
        JSON::Any.new(projection)
      end

      private def project_blocks(elements : Array(RawJson)) : JSON::Any
        sources = {} of UInt64 => BlockSource
        blocks = elements.compact_map do |element|
          projection = element.to_json_any?
          partial = projection.nil?
          projection ||= project_members(element)
          if projection && (object = projection.as_h?)
            encoded = WireFrame.encode(projection)
            if element.json != encoded
              if @project_nested_objects
                nested_views = {} of String => ObjectView
                object.each do |key, member|
                  if nested = member.as_h?
                    nested_views[key] = nested
                  end
                end
              end
              sources[object.object_id] = BlockSource.new(object, element, encoded, partial, nested_views)
            end
          end
          projection
        end
        unless sources.empty?
          @block_sources = sources
          @block_order = blocks.map { |block| retained_block(block).try(&.view.object_id) }
        end
        JSON::Any.new(blocks)
      end

      private def retained_block(block : JSON::Any) : BlockSource?
        if (view = block.as_h?) && (source = @block_sources.try(&.[view.object_id]?))
          source if source.view.same?(view)
        end
      end

      private def encode_blocks(blocks : Array(JSON::Any)) : String
        JSON.build do |builder|
          builder.max_nesting = 512
          builder.array do
            blocks.each do |block|
              if source = retained_block(block)
                if WireFrame.encode(block) == source.projected && source.same_nested_objects?
                  builder.raw(source.raw.json)
                elsif @project_nested_objects
                  baseline = JSON.parse(source.projected).as_h
                  builder.raw(patch_projected_object(source.raw.json, baseline, source.view, source.nested_views))
                else
                  builder.raw(WireFrame.merge_projection(source.raw.json, block, partial_object: source.partial))
                end
              else
                block.to_json(builder)
              end
            end
          end
        end
      end

      # Apply edits against the original visible keys. Untouched wire members keep
      # their original values, including hidden members and repeated keys.
      private def patch_projected_object(wire : String, baseline : ObjectView, view : ObjectView,
                                         nested_views : Hash(String, ObjectView)? = nil) : String
        pull = JSON::PullParser.new(wire)
        members = [] of {String, String}
        pull.read_object { |key| members << {key, WireFrame.read_raw(pull)} }
        edits = {} of String => String?
        nested_edits = {} of Int32 => String
        baseline.each_key { |key| edits[key] = nil unless view.has_key?(key) }

        view.each do |key, member|
          original = baseline[key]?
          rendered = WireFrame.encode(member)
          unchanged = original && rendered == WireFrame.encode(original)
          if original_nested = nested_views.try(&.[key]?)
            if (nested = member.as_h?) && nested.same?(original_nested)
              unless unchanged
                index = members.rindex { |name, _| name == key }.not_nil!
                nested_edits[index] = patch_projected_object(members[index][1], original.not_nil!.as_h, nested)
              end
            else
              edits[key] = rendered
            end
          elsif !unchanged
            edits[key] = rendered
          end
        end
        return wire if edits.empty? && nested_edits.empty?

        written = Set(String).new
        JSON.build do |json|
          json.max_nesting = pull.max_nesting
          json.object do
            members.each_with_index do |(key, value), index|
              if nested = nested_edits[index]?
                json.field(key) { json.raw(nested) }
              elsif edits.has_key?(key)
                if written.add?(key) && (replacement = edits[key])
                  json.field(key) { json.raw(replacement) }
                end
              else
                json.field(key) { json.raw(value) }
              end
            end
            edits.each do |key, replacement|
              json.field(key) { json.raw(replacement) } if replacement && written.add?(key)
            end
          end
        end
      end

      def raw : RawJson
        if value = @value
          rendered = RawJson.new(value)
          if source = @source
            if (order = @block_order) && (blocks = value.as_a?)
              if rendered.json == @projected
                sources = blocks.map { |block| retained_block(block) }
                if sources.map { |entry| entry.try(&.view.object_id) } == order &&
                   sources.all? { |entry| !entry || entry.same_nested_objects? }
                  return source
                end
              end

              return RawJson.new(JSON::PullParser.new(encode_blocks(blocks)))
            end
            return source if rendered.json == @projected

            merged = WireFrame.merge_projection(source.json, value, partial_object: partial?)
            return RawJson.new(JSON::PullParser.new(merged))
          end

          rendered
        else
          @source.not_nil!
        end
      end

      def to_json(builder : JSON::Builder) : Nil
        raw.to_json(builder)
      end
    end

    # :nodoc:
    module PreservedMetadata
      def self.from_json(pull : JSON::PullParser) : PreservedJson
        PreservedJson.new(pull, project_object_members: true)
      end

      def self.to_json(value : PreservedJson, builder : JSON::Builder) : Nil
        value.to_json(builder)
      end
    end

    # :nodoc:
    module OptionalPreservedMetadata
      def self.from_json(pull : JSON::PullParser) : PreservedJson?
        return PreservedMetadata.from_json(pull) if pull.kind.begin_object?

        pull.skip
        nil
      end

      def self.to_json(value : PreservedJson, json : JSON::Builder) : Nil
        PreservedMetadata.to_json(value, json)
      end
    end

    # :nodoc:
    module LosslessMetadata
      @[JSON::Field(key: "_meta", converter: ::ACP::Protocol::OptionalPreservedMetadata)]
      @metadata_wire : PreservedJson?

      # Metadata fields that can be represented as JSON::Any.
      def meta : Hash(String, JSON::Any)?
        @metadata_wire.try(&.value).try(&.as_h?)
      end

      # Replaces the extension metadata.
      def meta=(value : Hash(String, JSON::Any)?) : Hash(String, JSON::Any)?
        @metadata_wire = value.try { |fields| PreservedJson.new(JSON::Any.new(fields)) }
        value
      end

      # Extension metadata with its exact JSON values.
      def meta_raw : RawJson?
        @metadata_wire.try(&.raw)
      end
    end

    # :nodoc:
    module OptionalRawMetadata
      def self.from_json(pull : JSON::PullParser) : RawJson?
        return RawJson.new(pull) if pull.kind.begin_object?

        pull.skip
        nil
      end

      def self.to_json(value : RawJson, json : JSON::Builder) : Nil
        value.to_json(json)
      end
    end
  end
end
