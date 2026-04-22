require "json"
require "optparse"
require "time"
require_relative "config"
require_relative "databases/postgres"
require_relative "databases/mysql"
require_relative "databases/sqlite"
require_relative "evidence"
require_relative "redactor"
require_relative "restic"
require_relative "scheduler"

module KamalBackup
  class CLI
    HELP = <<~TEXT
      Usage:
        kamal-backup backup
        kamal-backup restore-db [snapshot-or-latest]
        kamal-backup restore-files [snapshot-or-latest] [target-dir]
        kamal-backup list
        kamal-backup check
        kamal-backup evidence
        kamal-backup schedule

      Environment is used for configuration. See README.md for Kamal accessory examples.
    TEXT

    def self.start(argv = ARGV, env: ENV)
      new(env: env).run(argv)
    rescue Error => e
      warn("kamal-backup: #{e.message}")
      exit(1)
    rescue Interrupt
      warn("kamal-backup: interrupted")
      exit(130)
    end

    def initialize(env: ENV)
      @config = Config.new(env: env)
      @redactor = Redactor.new(env: env)
    end

    def run(argv)
      argv = argv.dup
      command = argv.shift
      return puts(HELP) if command.nil? || %w[-h --help help].include?(command)

      case command
      when "backup"
        backup
      when "restore-db"
        restore_db(argv[0] || "latest")
      when "restore-files"
        restore_files(argv[0] || "latest", argv[1] || "/restore/files")
      when "list"
        list
      when "check"
        check
      when "evidence"
        evidence
      when "schedule"
        schedule
      else
        raise ConfigurationError, "unknown command: #{command}\n\n#{HELP}"
      end
    end

    def backup
      @config.validate_for_backup!
      timestamp = Time.now.utc.strftime("%Y%m%dT%H%M%SZ")
      restic.ensure_repository!
      database.backup(restic, timestamp)
      @config.backup_paths.each do |path|
        restic.backup_path(path, tags: ["type:files", "path:#{@config.backup_path_label(path)}", "run:#{timestamp}"])
      end
      restic.forget_after_success!
      restic.check! if @config.check_after_backup?
      true
    end

    def restore_db(snapshot)
      @config.validate_for_restic!
      @config.validate_restore_allowed!
      adapter = database
      resolved_snapshot = resolve_snapshot(snapshot, ["type:database", "adapter:#{adapter.adapter_name}"])
      filename = restic.database_file(resolved_snapshot, adapter.adapter_name)
      raise ConfigurationError, "could not find database backup file in snapshot #{resolved_snapshot}" unless filename

      adapter.restore(restic, resolved_snapshot, filename)
      true
    end

    def restore_files(snapshot, target)
      @config.validate_for_restic!
      @config.validate_restore_allowed!
      target = @config.validate_file_restore_target!(target)
      resolved_snapshot = resolve_snapshot(snapshot, ["type:files"])
      restic.restore_snapshot(resolved_snapshot, target)
      true
    end

    def list
      @config.validate_for_restic!
      puts restic.snapshots.stdout
      true
    end

    def check
      @config.validate_for_restic!
      puts restic.check!.stdout
      true
    end

    def evidence
      @config.validate_for_restic!
      puts Evidence.new(@config, restic: restic, redactor: @redactor).to_json
      true
    end

    def schedule
      @config.validate_for_backup!
      Scheduler.new(@config) { backup }.run
    end

    private

    def restic
      @restic ||= Restic.new(@config, redactor: @redactor)
    end

    def database
      @database ||= begin
        case @config.database_adapter
        when "postgres"
          Databases::Postgres.new(@config, redactor: @redactor)
        when "mysql"
          Databases::Mysql.new(@config, redactor: @redactor)
        when "sqlite"
          Databases::Sqlite.new(@config, redactor: @redactor)
        else
          raise ConfigurationError, "unsupported DATABASE_ADAPTER: #{@config.database_adapter.inspect}"
        end
      end
    end

    def resolve_snapshot(argument, tags)
      return argument unless argument == "latest"

      snapshot = restic.latest_snapshot(tags: tags)
      raise ConfigurationError, "no restic snapshot found for #{tags.join(", ")}" unless snapshot

      snapshot["short_id"] || snapshot["id"]
    end
  end
end
