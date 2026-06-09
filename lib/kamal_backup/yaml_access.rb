# frozen_string_literal: true

module KamalBackup
  # Kamal and Rails YAML configs mix string and symbol keys depending on how
  # they were rendered, so look up both.
  module YamlAccess
    private

    def fetch(hash, key)
      hash[key] || hash[key.to_s] || hash[key.to_sym]
    end
  end
end
