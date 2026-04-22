require "json"
require "time"
require_relative "command"
require_relative "version"

module KamalBackup
  class Evidence
    def initialize(config, restic:, redactor:)
      @config = config
      @restic = restic
      @redactor = redactor
    end

    def to_h
      {
        app_name: @config.app_name,
        generated_at: Time.now.utc.iso8601,
        database_adapter: @config.database_adapter,
        restic_repository: @redactor.redact_string(@config.restic_repository.to_s),
        backup_paths: @config.backup_paths,
        retention: @config.retention,
        latest_database_backup: latest_snapshot_summary(["type:database"]),
        latest_file_backup: latest_snapshot_summary(["type:files"]),
        last_restic_check: last_check,
        image_version: ENV.fetch("KAMAL_BACKUP_IMAGE_VERSION", VERSION),
        tool_versions: tool_versions
      }
    end

    def to_json(*args)
      JSON.pretty_generate(to_h, *args)
    end

    private

    def latest_snapshot_summary(tags)
      snapshot = @restic.latest_snapshot(tags: tags)
      return nil unless snapshot

      {
        id: snapshot["short_id"] || snapshot["id"],
        time: snapshot["time"],
        tags: snapshot["tags"]
      }
    rescue Error => e
      { error: @redactor.redact_string(e.message) }
    end

    def last_check
      return nil unless File.file?(@config.last_check_path)

      JSON.parse(File.read(@config.last_check_path))
    rescue JSON::ParserError, SystemCallError => e
      { error: @redactor.redact_string(e.message) }
    end

    def tool_versions
      {
        pg_dump: version_for(["pg_dump", "--version"]),
        pg_restore: version_for(["pg_restore", "--version"]),
        mysql_dump: version_for(["mariadb-dump", "--version"], ["mysqldump", "--version"]),
        mysql_client: version_for(["mariadb", "--version"], ["mysql", "--version"]),
        sqlite3: version_for(["sqlite3", "--version"]),
        restic: version_for(["restic", "version"])
      }
    end

    def version_for(*commands)
      commands.each do |argv|
        result = Command.capture(CommandSpec.new(argv: argv), redactor: @redactor)
        output = result.stdout.empty? ? result.stderr : result.stdout
        return @redactor.redact_string(output.strip)
      rescue CommandError
        next
      end
      "unavailable"
    end
  end
end
