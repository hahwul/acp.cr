require "../patch_fields"

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
    end
  end
end
