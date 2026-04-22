require "uri"

module KamalBackup
  class Redactor
    SECRET_KEY_PATTERN = /(pass|password|secret|token|key|credential|authorization)/i
    REDACTED = "[REDACTED]"

    def initialize(secret_values: [], env: ENV)
      @secret_values = Array(secret_values).compact.map(&:to_s).reject { |value| value.empty? || value.length < 4 }
      @env = env
    end

    def redact_hash(hash)
      hash.each_with_object({}) do |(key, value), result|
        result[key] = redact_value(key, value)
      end
    end

    def redact_value(key, value)
      return nil if value.nil?
      return REDACTED if key.to_s.match?(SECRET_KEY_PATTERN)

      redact_string(value.to_s)
    end

    def redact_string(value)
      redacted = redact_url_credentials(value.to_s)
      known_secret_values.each do |secret|
        redacted = redacted.gsub(secret, REDACTED)
      end
      redacted
    end

    private

    def known_secret_values
      @known_secret_values ||= begin
        env_secrets = @env.each_with_object([]) do |(key, value), values|
          values << value.to_s if key.to_s.match?(SECRET_KEY_PATTERN)
        end
        (@secret_values + env_secrets).compact.uniq.reject { |value| value.empty? || value.length < 4 }
      end
    end

    def redact_url_credentials(value)
      value.gsub(%r{(://)([^/\s:@]+)(?::([^/\s@]*))?@}) do
        "#{$1}#{REDACTED}@"
      end.gsub(/([?&](?:password|token|secret|key|access_key_id|secret_access_key)=)[^&\s]+/i) do
        "#{$1}#{REDACTED}"
      end
    end
  end
end
