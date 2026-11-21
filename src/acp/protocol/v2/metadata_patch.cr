require "../patch_fields"
require "../raw_json"

module ACP
  module Protocol
    module V2
      # Applies key-level metadata patches on session upserts.
      module MetadataPatch
        # Applies this update's metadata patch to a previous snapshot.
        def apply_metadata(previous : Hash(String, JSON::Any)?) : Hash(String, JSON::Any)?
          return previous.try(&.dup) unless meta_present?
          return unless patch = meta

          result = previous.try(&.dup) || {} of String => JSON::Any
          patch.each do |key, value|
            if value.raw.nil?
              result.delete(key)
            else
              result[key] = value
            end
          end
          result
        end
      end

      # :nodoc:
      module LosslessMetadataPatch
        include MetadataPatch

        @[JSON::Field(key: "_meta", presence: true, emit_null: true, ignore_serialize: !meta_present?, converter: ::ACP::Protocol::PreservedMetadata)]
        @metadata_wire : PreservedJson?

        @[JSON::Field(ignore: true)]
        @metadata_wire_present = false

        # Extension metadata that can be represented as JSON::Any.
        def meta : Hash(String, JSON::Any)?
          @metadata_wire.try(&.value).try(&.as_h?)
        end

        # Replaces metadata. Assign nil to explicitly clear it.
        def meta=(value : Hash(String, JSON::Any)?) : Hash(String, JSON::Any)?
          @metadata_wire_present = true
          @metadata_wire = value.try { |fields| PreservedJson.new(JSON::Any.new(fields)) }
          value
        end

        # Whether this patch supplies metadata or explicitly clears it.
        def meta_present? : Bool
          @metadata_wire_present && (!@metadata_wire || !!meta_raw)
        end

        # Exact metadata object when the patch supplies one.
        def meta_raw : RawJson?
          if raw = @metadata_wire.try(&.raw)
            raw if raw.object?
          end
        end

        # Applies this patch to a metadata map representable as JSON::Any.
        def apply_metadata(previous : Hash(String, JSON::Any)?) : Hash(String, JSON::Any)?
          return super unless @metadata_wire.try(&.partial?) && (raw = meta_raw)

          result = previous.try(&.dup) || {} of String => JSON::Any
          raw.members?.not_nil!.each do |key, member|
            if !member.null? && (value = member.to_json_any?)
              result[key] = value
            else
              result.delete(key)
            end
          end
          result
        end
      end
    end
  end
end
