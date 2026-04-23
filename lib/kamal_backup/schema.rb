module KamalBackup
  module Schema
    VERSION = 1

    def self.record(kind:, **attributes)
      {
        schema_version: VERSION,
        kind: kind
      }.merge(attributes)
    end
  end
end
