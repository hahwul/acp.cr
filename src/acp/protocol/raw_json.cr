require "deque"
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

      # Reads a patch with unambiguous required fields and drops repeated optional fields.
      # :nodoc:
      def self.patch_parser(pull : JSON::PullParser, *, required : Tuple, optional : Tuple) : JSON::PullParser
        location = pull.location
        wire = new(pull).unambiguous_patch(required: required, optional: optional, location: location)
        JSON::PullParser.new(wire.json)
      end

      # Rejects repeated identity fields and removes conflicting optional fields.
      # :nodoc:
      def unambiguous_patch(*, required : Tuple, optional : Tuple, location : {Int32, Int32} = {1, 1}) : RawJson
        repeated = WireFrame.repeated_members(@json, *required, *optional)
        if required.any? { |field| repeated.includes?(field) }
          raise JSON::ParseException.new("Ambiguous JSON patch fields: #{repeated.join(", ")}", *location)
        end
        repeated.reduce(self) { |wire, field| wire.without_field(field) }
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
      private alias ArrayView = Array(JSON::Any)
      private alias ContainerChild = ObjectChild | ArrayChild
      private alias ObjectChildren = Hash(String, ContainerChild)
      private alias ArrayChildren = Hash(UInt64, {Int32, ContainerChild})
      private alias WireValue = WireObject | WireArray | String

      private record WireObject, members : Array({String, WireValue})
      private record WireArray, entries : Array(WireValue)

      private record ObjectChild, view : ObjectView, children : ObjectChildren do
        def same_view?(value : JSON::Any) : Bool
          value.as_h?.try(&.same?(view)) == true
        end

        def same_tree?(value : JSON::Any?) : Bool
          if object = value.try(&.as_h?)
            object.same?(view) && children.all? { |key, child| child.same_tree?(object[key]?) }
          else
            false
          end
        end
      end

      private record ArrayChild, view : ArrayView, children : ArrayChildren do
        def same_view?(value : JSON::Any) : Bool
          value.as_a?.try(&.same?(view)) == true
        end

        def same_tree?(value : JSON::Any?) : Bool
          if array = value.try(&.as_a?)
            array.same?(view) && children.each_value.all? { |(index, child)| child.same_tree?(array[index]?) }
          else
            false
          end
        end
      end

      private record ObjectSource, view : ObjectView, raw : RawJson, projected : String, partial : Bool,
        nested_views : ObjectChildren? = nil do
        def same_nested_objects? : Bool
          return true unless objects = nested_views

          objects.all? { |key, child| child.same_tree?(view[key]?) }
        end
      end

      getter value : JSON::Any?
      getter? partial = false
      @source : RawJson?
      @projected : String?
      @block_sources : Hash(UInt64, ObjectSource)?
      @block_order : Array(UInt64?)?
      @object_source : ObjectSource?
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
        if @project_nested_objects && !project_array_objects && (view = @value.try(&.as_h?))
          @object_source = ObjectSource.new(view, source, @projected.not_nil!, partial?, nested_object_views(view))
        end
      end

      private def project_members(source : RawJson, *, nested : Bool = @project_nested_objects) : JSON::Any?
        return unless source.object?

        project_members(JSON::PullParser.new(source.json), nested: nested)
      end

      private def project_members(pull : JSON::PullParser, *, nested : Bool) : JSON::Any
        projection = {} of String => JSON::Any
        pull.read_object do |key|
          projected = nested ? project_nested_value(pull) : RawJson.new(pull).to_json_any?
          if projected
            projection[key] = projected
          else
            projection.delete(key)
          end
        end
        JSON::Any.new(projection)
      end

      private def project_nested_value(pull : JSON::PullParser) : JSON::Any?
        return project_members(pull, nested: true) if pull.kind.begin_object?
        return RawJson.new(pull).to_json_any? unless pull.kind.begin_array?

        entries = [] of JSON::Any
        complete = true
        pull.read_array do
          if entry = project_nested_value(pull)
            entries << entry
          else
            # A hidden scalar must not shift position in the editable array.
            complete = false
          end
        end
        JSON::Any.new(entries) if complete
      end

      private def project_blocks(elements : Array(RawJson)) : JSON::Any
        sources = {} of UInt64 => ObjectSource
        blocks = elements.compact_map do |element|
          projection = element.to_json_any?
          partial = projection.nil?
          projection ||= project_members(element)
          if projection && (object = projection.as_h?)
            encoded = WireFrame.encode(projection)
            if element.json != encoded
              nested_views = nested_object_views(object) if @project_nested_objects
              sources[object.object_id] = ObjectSource.new(object, element, encoded, partial, nested_views)
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

      private def nested_object_views(object : ObjectView) : ObjectChildren
        views = ObjectChildren.new
        object.each do |key, member|
          if child = nested_view(member)
            views[key] = child
          end
        end
        views
      end

      private def nested_view(value : JSON::Any) : ContainerChild?
        if object = value.as_h?
          ObjectChild.new(object, nested_object_views(object))
        elsif array = value.as_a?
          children = ArrayChildren.new
          array.each_with_index do |entry, index|
            if child = nested_view(entry)
              children[child.view.object_id] = {index, child}
            end
          end
          ArrayChild.new(array, children)
        end
      end

      private def retained_block(block : JSON::Any) : ObjectSource?
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

      private def patch_projected_object(wire : String, baseline : ObjectView, view : ObjectView,
                                         nested_views : ObjectChildren? = nil) : String
        pull = JSON::PullParser.new(wire)
        # Read the source once. Containers hold references to their children so
        # an edit does not copy or re-encode the same value at every ancestor.
        source = read_wire_value(pull).as(WireObject)
        JSON.build do |builder|
          builder.max_nesting = pull.max_nesting
          write_patched_object(source, baseline, view, nested_views, builder)
        end
      end

      private def read_wire_value(pull : JSON::PullParser) : WireValue
        case pull.kind
        when .begin_object?
          members = [] of {String, WireValue}
          pull.read_object { |key| members << {key, read_wire_value(pull)} }
          WireObject.new(members)
        when .begin_array?
          entries = [] of WireValue
          pull.read_array { entries << read_wire_value(pull) }
          WireArray.new(entries)
        else
          pull.read_raw
        end
      end

      private def write_wire_value(value : WireValue, builder : JSON::Builder) : Nil
        case value
        when WireObject
          builder.object do
            value.members.each { |key, member| builder.field(key) { write_wire_value(member, builder) } }
          end
        when WireArray
          builder.array { value.entries.each { |entry| write_wire_value(entry, builder) } }
        else
          builder.raw(value)
        end
      end

      # Apply edits against the original visible keys. Keep hidden fields and
      # earlier repeated members when their projected container is edited.
      private def write_patched_object(source : WireObject, baseline : ObjectView, view : ObjectView,
                                       nested_views : ObjectChildren?, builder : JSON::Builder) : Nil
        last_members = {} of String => Int32
        source.members.each_with_index { |(key, _), index| last_members[key] = index }
        edits = {} of String => String?
        nested_edits = {} of Int32 => {JSON::Any, ContainerChild}
        baseline.each_key { |key| edits[key] = nil unless view.has_key?(key) }

        view.each do |key, member|
          original = baseline[key]?
          if child = nested_views.try(&.[key]?)
            if child.same_view?(member)
              nested_edits[last_members[key]] = {original.not_nil!, child}
            else
              edits[key] = WireFrame.encode(member)
            end
          else
            rendered = WireFrame.encode(member)
            edits[key] = rendered unless original && rendered == WireFrame.encode(original)
          end
        end

        written = Set(String).new
        builder.object do
          source.members.each_with_index do |(key, value), index|
            if nested = nested_edits[index]?
              builder.field(key) { write_patched_child(value, nested[0], nested[1], builder) }
            elsif edits.has_key?(key)
              if written.add?(key) && (replacement = edits[key])
                builder.field(key) { builder.raw(replacement) }
              end
            else
              builder.field(key) { write_wire_value(value, builder) }
            end
          end
          edits.each do |key, replacement|
            builder.field(key) { builder.raw(replacement) } if replacement && written.add?(key)
          end
        end
      end

      private def write_patched_child(source : WireValue, baseline : JSON::Any,
                                      child : ObjectChild, builder : JSON::Builder) : Nil
        write_patched_object(source.as(WireObject), baseline.as_h, child.view, child.children, builder)
      end

      private def write_patched_child(source : WireValue, baseline : JSON::Any,
                                      child : ArrayChild, builder : JSON::Builder) : Nil
        members = source.as(WireArray).entries
        original = baseline.as_a
        prior_scalars = original.map { |value| scalar_json(value) }
        scalars = child.view.map { |value| scalar_json(value) }
        moved_scalars = {} of String => Deque(Int32)
        prior_scalars.each_with_index do |scalar, index|
          if scalar && scalars[index]? != scalar
            (moved_scalars[scalar] ||= Deque(Int32).new) << index
          end
        end

        builder.array do
          child.view.each_with_index do |value, index|
            if container = value.as_h? || value.as_a?
              if (entry = child.children[container.object_id]?) && entry[1].same_view?(value)
                source_index, nested = entry
                write_patched_child(members[source_index], original[source_index], nested, builder)
              else
                value.to_json(builder)
              end
            elsif scalar = scalars[index]
              source_index = prior_scalars[index]? == scalar ? index : moved_scalars[scalar]?.try(&.shift?)
              source_index ? write_wire_value(members[source_index], builder) : builder.raw(scalar)
            end
          end
        end
      end

      private def scalar_json(value : JSON::Any) : String?
        WireFrame.encode(value) unless value.as_h? || value.as_a?
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
            if object = @object_source
              return source if rendered.json == object.projected && object.same_nested_objects?

              baseline = JSON.parse(object.projected).as_h
              merged = patch_projected_object(source.json, baseline, object.view, object.nested_views)
              return RawJson.new(JSON::PullParser.new(merged))
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
        wrap(RawJson.new(pull))
      end

      def self.wrap(source : RawJson) : PreservedJson
        if (value = source.to_json_any?) && WireFrame.encode(value) == source.json
          PreservedJson.new(value)
        else
          PreservedJson.new(source, project_object_members: true, project_nested_objects: true)
        end
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

      # Replaces the extension metadata with an exact JSON object.
      # Pass nil or JSON null to clear it.
      def meta_raw=(value : RawJson?) : RawJson?
        @metadata_wire = if value && !value.null?
                           raise ArgumentError.new("Extension metadata must be an object or null") unless value.object?

                           PreservedMetadata.wrap(value)
                         end
        value
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
