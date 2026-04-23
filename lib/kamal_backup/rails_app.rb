require "erb"
require "uri"
require "yaml"

module KamalBackup
  class RailsApp
    DEVELOPMENT_ENV = "development"

    def initialize(cwd:)
      @cwd = File.expand_path(cwd)
    end

    def defaults
      return {} unless rails_app?

      {}.tap do |defaults|
        defaults.merge!(deploy_defaults)
        defaults.merge!(database_defaults)

        if local_storage_path
          defaults["BACKUP_PATHS"] = local_storage_path
        end

        defaults["KAMAL_BACKUP_STATE_DIR"] = File.join(@cwd, "tmp", "kamal-backup")
      end
    end

    private
      def rails_app?
        File.file?(database_config_path)
      end

      def deploy_defaults
        service = fetch(parsed_yaml(deploy_config_path), :service)

        if service
          { "APP_NAME" => service.to_s }
        else
          {}
        end
      end

      def database_defaults
        config = local_database_config
        return {} unless config

        if url = fetch(config, :url)
          adapter = adapter_from_url(url)

          {
            "DATABASE_ADAPTER" => adapter,
            "DATABASE_URL" => url.to_s
          }.compact
        else
          case normalize_adapter(fetch(config, :adapter))
          when "postgres"
            {
              "DATABASE_ADAPTER" => "postgres",
              "PGHOST" => fetch(config, :host),
              "PGPORT" => fetch(config, :port)&.to_s,
              "PGUSER" => fetch(config, :username),
              "PGDATABASE" => fetch(config, :database)
            }.compact
          when "mysql"
            {
              "DATABASE_ADAPTER" => "mysql",
              "MYSQL_HOST" => fetch(config, :host),
              "MYSQL_PORT" => fetch(config, :port)&.to_s,
              "MYSQL_USER" => fetch(config, :username),
              "MYSQL_DATABASE" => fetch(config, :database)
            }.compact
          when "sqlite"
            database = fetch(config, :database)
            if database
              {
                "DATABASE_ADAPTER" => "sqlite",
                "SQLITE_DATABASE_PATH" => File.expand_path(database.to_s, @cwd)
              }
            else
              {}
            end
          else
            {}
          end
        end
      end

      def local_storage_path
        File.join(@cwd, "storage")
      end

      def local_database_config
        environment = fetch(parsed_yaml(database_config_path), DEVELOPMENT_ENV)
        return nil unless environment.is_a?(Hash)

        if database_entry?(environment)
          environment
        else
          primary = fetch(environment, :primary)
          primary if primary.is_a?(Hash)
        end
      end

      def database_entry?(config)
        fetch(config, :adapter) || fetch(config, :database) || fetch(config, :url)
      end

      def adapter_from_url(url)
        normalize_adapter(URI.parse(url.to_s).scheme)
      rescue URI::InvalidURIError
        nil
      end

      def parsed_yaml(path)
        return {} unless File.file?(path)

        rendered = ERB.new(File.read(path), trim_mode: "-").result
        data = YAML.safe_load(rendered, permitted_classes: [], aliases: true)

        if data.is_a?(Hash)
          data
        else
          {}
        end
      rescue Psych::SyntaxError => e
        raise ConfigurationError, "invalid YAML in #{path}: #{e.message}"
      end

      def fetch(hash, key)
        hash[key] || hash[key.to_s] || hash[key.to_sym]
      end

      def normalize_adapter(value)
        case value.to_s.downcase
        when "postgres", "postgresql"
          "postgres"
        when "mysql", "mysql2", "mariadb"
          "mysql"
        when "sqlite", "sqlite3"
          "sqlite"
        end
      end

      def database_config_path
        File.join(@cwd, "config", "database.yml")
      end

      def deploy_config_path
        File.join(@cwd, "config", "deploy.yml")
      end
  end
end
