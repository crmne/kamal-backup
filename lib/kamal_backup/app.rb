# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'time'
require 'tmpdir'
require_relative 'command'
require_relative 'config'
require_relative 'databases/base'
require_relative 'databases/mysql'
require_relative 'databases/postgres'
require_relative 'databases/sqlite'
require_relative 'evidence'
require_relative 'redactor'
require_relative 'restic'
require_relative 'scheduler'
require_relative 'schema'

module KamalBackup
  class App
    FRESH_BACKUP_GRACE_SECONDS = 5

    attr_reader :config, :redactor

    def initialize(env: ENV, config: nil, redactor: nil, restic: nil, database: nil)
      @config = config || Config.new(env: env)
      @redactor = redactor || Redactor.new(env: @config.env)
      @restic = restic
      @database = database
    end

    def backup(force: false)
      started_at = Time.now.utc
      config.validate_backup
      return disabled_backup_result(started_at) unless config.backup_enabled? || force
      return skipped_backup_result(started_at) unless force || backup_due?(started_at)

      restic.ensure_repository
      databases.each { |database| database.backup(restic) }
      restic.backup_paths(config.backup_paths, tags: ['type:files'])

      restic.prune if config.forget_after_backup?

      restic.check if config.check_after_backup?

      backup_summary(started_at: started_at, finished_at: Time.now.utc).tap do |summary|
        validate_fresh_backup_summary!(summary, started_at: started_at)
        write_last_backup(summary)
      end
    end

    def validate(check_files: true)
      config.validate_backup(check_files: check_files)
      true
    end

    def restore_to_local_machine(snapshot = 'latest')
      validate_local_machine_restore

      build_restore_result('local', snapshot) do |result|
        databases.each { |adapter| validate_local_machine_database_target(adapter) }
        result[:files] = perform_replacement_file_restore(snapshot, production_source: false)
        result[:databases] = perform_database_restores_to_current(snapshot)
      end
    end

    def restore_to_production(snapshot = 'latest')
      validate_production_restore

      build_restore_result('production', snapshot) do |result|
        result[:files] = perform_replacement_file_restore(snapshot, production_source: true)
        result[:databases] = perform_database_restores_to_current(snapshot)
      end
    end

    def drill_on_local_machine(snapshot = 'latest', check_command: nil)
      validate_local_machine_restore

      run_drill('local', snapshot, check_command: check_command) do |result|
        databases.each { |adapter| validate_local_machine_database_target(adapter) }
        result[:files] = perform_replacement_file_restore(snapshot, production_source: false)
        result[:databases] = perform_database_restores_to_current(snapshot)
      end
    end

    def drill_on_production(snapshot = 'latest', database_name: nil, sqlite_path: nil, file_target: '/restore/files',
                            check_command: nil)
      validate_production_drill(file_target, database_name, sqlite_path)

      run_drill('production', snapshot, check_command: check_command) do |result|
        result[:files] = perform_file_restore(snapshot, target: file_target)
        result[:databases] = databases.map do |adapter|
          perform_database_restore_to_scratch(
            snapshot,
            adapter: adapter,
            database_name: database_name,
            sqlite_path: sqlite_path
          )
        end
      end
    end

    def snapshots
      config.validate_restic
      restic.snapshots.stdout
    end

    def check
      config.validate_restic
      restic.check.stdout
    end

    def unlock
      config.validate_restic
      restic.unlock.stdout
    end

    def prune
      config.validate_backup(check_files: false)
      restic.prune
    end

    def evidence
      config.validate_restic
      Evidence.new(config, restic: restic, redactor: redactor).to_json
    end

    def schedule
      config.validate_backup
      Scheduler.new(config) { backup(force: true) }.run
    end

    private

    def backup_due?(now)
      due_at = next_backup_at
      due_at.nil? || now >= due_at
    end

    def disabled_backup_result(now)
      Schema.record(
        kind: 'backup_result',
        status: 'skipped',
        reason: 'disabled',
        last_backup_at: last_backup_finished_at&.iso8601,
        next_backup_at: nil,
        force_command: 'kamal-backup backup --force',
        finished_at: now.iso8601
      )
    end

    def skipped_backup_result(now)
      Schema.record(
        kind: 'backup_result',
        status: 'skipped',
        reason: 'not_due',
        last_backup_at: last_backup_finished_at&.iso8601,
        next_backup_at: next_backup_at&.iso8601,
        force_command: 'kamal-backup backup --force',
        finished_at: now.iso8601
      )
    end

    def next_backup_at
      last_backup_finished_at + config.backup_schedule_seconds if last_backup_finished_at
    end

    def last_backup_finished_at
      @last_backup_finished_at ||= begin
        value = last_backup_record['finished_at']
        value ? Time.parse(value.to_s).utc : nil
      rescue ArgumentError
        nil
      end
    end

    def last_backup_record
      @last_backup_record ||= begin
        JSON.parse(File.read(config.last_backup_path))
      rescue JSON::ParserError, SystemCallError
        {}
      end
    end

    def backup_summary(started_at:, finished_at:)
      Schema.record(
        kind: 'backup_result',
        status: 'ok',
        started_at: started_at.iso8601,
        finished_at: finished_at.iso8601,
        databases: databases.map { |adapter| backup_snapshot_summary(adapter) },
        files: backup_file_snapshot_summary
      )
    end

    def backup_snapshot_summary(adapter)
      snapshot = restic.latest_snapshot(tags: database_snapshot_tags(adapter))
      snapshot_summary(snapshot).merge(
        database: database_config_name(adapter),
        adapter: adapter.adapter_name
      )
    end

    def backup_file_snapshot_summary
      return nil if config.backup_paths.empty?

      snapshot_summary(restic.latest_snapshot(tags: ['type:files']))
    end

    def snapshot_summary(snapshot)
      {
        snapshot: snapshot && (snapshot['short_id'] || snapshot['id']),
        time: snapshot && snapshot['time']
      }
    end

    def validate_fresh_backup_summary!(summary, started_at:)
      stale_databases = summary.fetch(:databases).reject { |entry| fresh_snapshot?(entry, started_at) }

      unless stale_databases.empty?
        names = stale_databases.map { |entry| entry.fetch(:database) }.join(', ')
        raise ConfigurationError, "backup did not create a fresh database snapshot for #{names}"
      end

      files = summary[:files]
      return unless files && !fresh_snapshot?(files, started_at)

      raise ConfigurationError, 'backup did not create a fresh file snapshot'
    end

    def fresh_snapshot?(entry, started_at)
      snapshot_time = Time.parse(entry[:time].to_s)
      snapshot_time >= started_at - FRESH_BACKUP_GRACE_SECONDS
    rescue ArgumentError
      false
    end

    def write_last_backup(result)
      FileUtils.mkdir_p(config.state_dir)
      File.write(config.last_backup_path, JSON.pretty_generate(result))
      @last_backup_record = result.transform_keys(&:to_s)
      @last_backup_finished_at = Time.parse(result.fetch(:finished_at)).utc
    rescue SystemCallError, ArgumentError
      nil
    end

    def build_restore_result(scope, snapshot)
      started_at = Time.now.utc
      result = Schema.record(
        kind: 'restore_result',
        status: 'ok',
        scope: scope,
        requested_snapshot: snapshot,
        started_at: started_at.iso8601,
        finished_at: nil,
        error: nil,
        databases: [],
        files: nil
      )
      yield(result)
      result[:finished_at] = Time.now.utc.iso8601
      result
    end

    def run_drill(scope, snapshot, check_command:)
      started_at = Time.now.utc
      result = Schema.record(
        kind: 'drill_result',
        status: 'ok',
        scope: scope,
        operator: drill_operator,
        requested_snapshot: snapshot,
        started_at: started_at.iso8601,
        finished_at: nil,
        error: nil,
        databases: [],
        files: nil,
        check: nil
      )

      begin
        yield(result)

        if check_command
          result[:check] = run_drill_check(check_command)

          if result[:check][:status] == 'failed'
            result[:status] = 'failed'
            result[:error] = result[:check][:error]
          end
        end
      rescue StandardError => e
        result[:status] = 'failed'
        result[:error] = redactor.redact_string(e.message)
      ensure
        result[:finished_at] = Time.now.utc.iso8601
        write_last_restore_drill(result)
      end

      result
    end

    def drill_operator
      config.value('USER') || config.value('USERNAME')
    end

    def run_drill_check(command)
      result = Command.capture(
        CommandSpec.new(argv: ['sh', '-lc', command]),
        redactor: redactor
      )
      output = result.stdout.empty? ? result.stderr : result.stdout

      {
        status: 'ok',
        command: redactor.redact_string(command),
        output: redactor.redact_string(output.strip)
      }
    rescue CommandError => e
      {
        status: 'failed',
        command: redactor.redact_string(command),
        error: redactor.redact_string(e.message)
      }
    end

    def write_last_restore_drill(payload)
      FileUtils.mkdir_p(config.state_dir)
      File.write(config.last_restore_drill_path, JSON.pretty_generate(payload))
    rescue SystemCallError
      nil
    end

    def perform_database_restores_to_current(snapshot)
      databases.map { |adapter| perform_database_restore_to_current(snapshot, adapter: adapter) }
    end

    def perform_database_restore_to_current(snapshot, adapter:)
      resolved_snapshot = resolve_snapshot(snapshot, tags: database_snapshot_tags(adapter))
      filename = restic.database_file(resolved_snapshot, adapter.adapter_name,
                                      database_name: database_config_name(adapter))

      raise ConfigurationError, "could not find database backup file in snapshot #{resolved_snapshot}" unless filename

      adapter.restore_to_current(restic, resolved_snapshot, filename)
      summarize_database_restore(adapter, resolved_snapshot, filename, adapter.current_target_identifier)
    end

    def perform_database_restore_to_scratch(snapshot, adapter:, database_name:, sqlite_path:)
      target = scratch_database_target(adapter, database_name, sqlite_path)
      resolved_snapshot = resolve_snapshot(snapshot, tags: database_snapshot_tags(adapter))
      filename = restic.database_file(resolved_snapshot, adapter.adapter_name,
                                      database_name: database_config_name(adapter))

      raise ConfigurationError, "could not find database backup file in snapshot #{resolved_snapshot}" unless filename

      adapter.restore_to_scratch(restic, resolved_snapshot, filename, target: target)
      summarize_database_restore(adapter, resolved_snapshot, filename, adapter.scratch_target_identifier(target))
    end

    def scratch_database_target(adapter, database_name, sqlite_path)
      case adapter.adapter_name
      when 'sqlite'
        target = sqlite_path || raise(ConfigurationError, 'scratch SQLite path is required')
        databases.size > 1 ? File.join(target, "#{database_config_name(adapter)}.sqlite3") : target
      else
        target = database_name || raise(ConfigurationError, 'scratch database name is required')
        databases.size > 1 ? "#{target}_#{database_config_name(adapter)}" : target
      end
    end

    def summarize_database_restore(adapter, snapshot, filename, target)
      {
        snapshot: snapshot,
        adapter: adapter.adapter_name,
        filename: filename,
        target: redactor.redact_string(target.to_s)
      }
    end

    def database_snapshot_tags(adapter)
      ['type:database', "database:#{database_config_name(adapter)}", "adapter:#{adapter.adapter_name}"]
    end

    def database_config_name(adapter)
      adapter.config.database_name
    end

    def perform_replacement_file_restore(snapshot, production_source:)
      return nil if config.backup_paths.empty?

      source_paths = production_source ? config.backup_paths : config.local_restore_source_paths
      target_paths = config.backup_paths
      resolved_snapshot = resolve_snapshot(snapshot, tags: ['type:files'])
      Dir.mktmpdir('kamal-backup-restore-') do |stage_dir|
        restic.restore_snapshot(resolved_snapshot, stage_dir)
        replace_target_paths(stage_dir, source_paths: source_paths, target_paths: target_paths)
      end

      {
        snapshot: resolved_snapshot,
        source_paths: source_paths,
        target_paths: target_paths.map { |path| File.expand_path(path) }
      }
    end

    def replace_target_paths(stage_dir, source_paths:, target_paths:)
      path_pairs = source_paths.zip(target_paths)
      validate_replacement_paths(stage_dir, path_pairs)

      path_pairs.each do |source_path, target_path|
        replace_target_path(stage_dir, source_path, target_path)
      end
    end

    def validate_replacement_paths(stage_dir, path_pairs)
      path_pairs.each do |source_path, target_path|
        source = staged_backup_path(stage_dir, source_path)
        raise ConfigurationError, "restored file snapshot is missing #{source_path}" unless File.exist?(source)

        ensure_writable_restore_target(target_path)
      end
    end

    def replace_target_path(stage_dir, source_path, target_path)
      source = staged_backup_path(stage_dir, source_path)
      target = File.expand_path(target_path)

      raise ConfigurationError, "restored file snapshot is missing #{source_path}" unless File.exist?(source)

      if File.directory?(source) && File.directory?(target) && !File.symlink?(target)
        replace_directory_contents(source, target)
      else
        FileUtils.remove_entry(target) if File.exist?(target) || File.symlink?(target)
        FileUtils.mkdir_p(File.dirname(target))
        FileUtils.mv(source, target)
      end
    rescue Errno::EACCES, Errno::EPERM, Errno::EROFS => e
      raise ConfigurationError, "cannot restore files to #{target}: target must be writable (#{e.message})"
    end

    def ensure_writable_restore_target(target_path)
      target = File.expand_path(target_path)
      return unless File.directory?(target) && !File.symlink?(target)

      Dir.mktmpdir('.kamal-backup-write-test-', target) {}
    rescue Errno::EACCES, Errno::EPERM, Errno::EROFS => e
      raise ConfigurationError, "cannot restore files to #{target}: target must be writable (#{e.message})"
    end

    def replace_directory_contents(source, target)
      Dir.children(target).each { |entry| FileUtils.remove_entry(File.join(target, entry)) }
      Dir.children(source).each { |entry| FileUtils.mv(File.join(source, entry), target) }
    end

    def staged_backup_path(stage_dir, path)
      File.join(stage_dir, path.to_s.sub(%r{\A/+}, ''))
    end

    def perform_file_restore(snapshot, target:)
      return nil if config.backup_paths.empty?

      resolved_snapshot = resolve_snapshot(snapshot, tags: ['type:files'])
      validated_target = config.validate_file_restore_target(target)
      restic.restore_snapshot(resolved_snapshot, validated_target)

      {
        snapshot: resolved_snapshot,
        target: validated_target
      }
    end

    def validate_local_machine_restore
      config.validate_restic
      config.validate_database_backup
      config.validate_local_machine_restore
    end

    def validate_production_restore
      config.validate_restic
      config.validate_database_backup
      config.validate_backup_paths
    end

    def validate_production_drill(file_target, database_name, sqlite_path)
      config.validate_restic
      config.validate_database_backup
      config.validate_file_restore_target(file_target) if config.backup_paths.any?

      databases.each do |adapter|
        case adapter.adapter_name
        when 'sqlite'
          raise ConfigurationError, 'scratch SQLite path is required' if sqlite_path.to_s.strip.empty?
        else
          raise ConfigurationError, 'scratch database name is required' if database_name.to_s.strip.empty?
        end
      end
    end

    def validate_local_machine_database_target(adapter)
      config.validate_local_database_restore_target(adapter.current_target_identifier)
    end

    def restic
      @restic ||= begin
        unless Command.available?('restic')
          raise ConfigurationError,
                'restic is required on PATH for commands that run on this machine. Install restic locally and try again.'
        end

        Restic.new(config, redactor: redactor)
      end
    end

    def databases
      @databases ||= if @database
                       Array(@database)
                     else
                       config.databases.map { |database_config| Databases::Base.build(database_config, redactor: redactor) }
                     end
    end

    def resolve_snapshot(argument, tags:)
      if argument == 'latest'
        snapshot = restic.latest_snapshot(tags: tags)

        raise ConfigurationError, "no restic snapshot found for #{tags.join(', ')}" unless snapshot

        snapshot['short_id'] || snapshot['id']
      else
        argument
      end
    end
  end
end
