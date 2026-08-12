# frozen_string_literal: true

require 'json'
require 'time'
require_relative 'command'
require_relative 'schema'
require_relative 'version'

module KamalBackup
  class Evidence
    def initialize(config, restic:, redactor:)
      @config = config
      @restic = restic
      @redactor = redactor
    end

    def to_h
      Schema.record(
        kind: 'evidence',
        app_name: @config.app_name,
        generated_at: Time.now.utc.iso8601,
        databases: @config.databases.map do |database|
          { name: database.database_name, adapter: database.database_adapter }
        end,
        restic_repository: @redactor.redact_string(@config.restic_repository.to_s),
        paths: @config.backup_paths,
        forget_after_backup: @config.forget_after_backup?,
        retention: @config.retention,
        latest_database_backups: latest_database_backups,
        latest_file_backup: latest_snapshot_summary(['type:files']),
        last_restic_check: last_check,
        last_restore_drill: last_restore_drill,
        image_version: VERSION,
        tool_versions: tool_versions
      )
    end

    def to_json(*args)
      JSON.pretty_generate(to_h, *args)
    end

    private

    def latest_snapshot_summary(tags)
      snapshot = @restic.latest_snapshot(tags: tags)

      if snapshot
        {
          id: snapshot['short_id'] || snapshot['id'],
          time: snapshot['time'],
          tags: snapshot['tags']
        }
      end
    rescue Error => e
      { error: @redactor.redact_string(e.message) }
    end

    def latest_database_backups
      @config.databases.each_with_object({}) do |database, backups|
        backups[database.database_name] = latest_snapshot_summary([
                                                                    'type:database',
                                                                    "database:#{database.database_name}",
                                                                    "adapter:#{database.database_adapter}"
                                                                  ])
      end
    end

    def last_check
      JSON.parse(File.read(@config.last_check_path)) if File.file?(@config.last_check_path)
    rescue JSON::ParserError, SystemCallError => e
      { error: @redactor.redact_string(e.message) }
    end

    def last_restore_drill
      JSON.parse(File.read(@config.last_restore_drill_path)) if File.file?(@config.last_restore_drill_path)
    rescue JSON::ParserError, SystemCallError => e
      { error: @redactor.redact_string(e.message) }
    end

    def tool_versions
      {
        pg_dump: version_for(['pg_dump', '--version']),
        pg_restore: version_for(['pg_restore', '--version']),
        mysql_dump: version_for(['mariadb-dump', '--version'], ['mysqldump', '--version']),
        mysql_client: version_for(['mariadb', '--version'], ['mysql', '--version']),
        sqlite3: version_for(['sqlite3', '--version']),
        restic: version_for(%w[restic version]),
        rclone: version_for(%w[rclone version])
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

      'unavailable'
    end
  end
end
