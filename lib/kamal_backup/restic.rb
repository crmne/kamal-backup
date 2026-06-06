# frozen_string_literal: true

require 'English'
require 'fileutils'
require 'json'
require 'open3'
require 'time'
require_relative 'command'

module KamalBackup
  class Restic
    RESTIC_ENV_PATTERN = /\A(?:RESTIC_|AWS_|B2_|AZURE_|GOOGLE_|RCLONE_|OS_|ST_|HP_|HTTP_|HTTPS_|NO_PROXY)/i

    attr_reader :config, :redactor

    def initialize(config, redactor:)
      @config = config
      @redactor = redactor
    end

    def ensure_repository
      run(%w[snapshots --json], log_output: false)
    rescue CommandError => e
      raise e unless config.restic_init_if_missing?

      log('restic repository not ready, running restic init')
      run(%w[init])
    end

    def backup_stream(command, filename:, tags:)
      restic_command = CommandSpec.new(
        argv: %w[restic
                 backup] + host_args + ['--stdin', '--stdin-filename', filename] + tag_args(common_tags + tags),
        env: restic_env
      )
      log("backing up stream as #{filename}")
      pipe_commands(command, restic_command, producer_label: 'dump', consumer_label: 'restic backup')
    end

    def backup_file(path, filename:, tags:)
      command = CommandSpec.new(
        argv: %w[restic
                 backup] + host_args + ['--stdin', '--stdin-filename', filename] + tag_args(common_tags + tags),
        env: restic_env
      )
      log("backing up file content as #{filename}")

      File.open(path, 'rb') do |file|
        output = Command.output
        context = output&.command_start(command, redactor: redactor)
        Open3.popen3(command.env, *command.argv) do |stdin, stdout, stderr, wait_thread|
          stdout_reader = Thread.new do
            Command.collect_stream(stdout, command_output: output, context: context, stream: :stdout,
                                           redactor: redactor)
          end
          stderr_reader = Thread.new do
            Command.collect_stream(stderr, command_output: output, context: context, stream: :stderr,
                                           redactor: redactor)
          end
          copy_error = nil
          begin
            IO.copy_stream(file, stdin)
          rescue Errno::EPIPE => e
            copy_error = e
          ensure
            stdin.close unless stdin.closed?
          end
          out = stdout_reader.value
          err = stderr_reader.value
          status = wait_thread.value
          output&.command_exit(context, status.exitstatus)
          raise_command_error(command, status, out, err) unless status.success?
          raise_stream_error(command, copy_error, out, err) if copy_error

          CommandResult.new(stdout: out, stderr: err, status: status.exitstatus)
        end
      end
    rescue Errno::ENOENT => e
      raise CommandError.new("command not found: #{command.argv.first}", command: command, status: 127,
                                                                         stderr: e.message)
    end

    def backup_paths(paths, tags:)
      paths = Array(paths).compact.map(&:to_s).reject(&:empty?)

      return unless paths.any?

      path_tags = paths.map { |path| "path:#{config.backup_path_label(path)}" }
      excludes = config.backup_path_excludes(paths)
      log("backing up #{paths.size} file path(s): #{paths.join(', ')}")
      run(['backup'] + host_args + exclude_args(excludes) + paths + tag_args(common_tags + tags + path_tags))
    end

    def backup_path(path, tags:)
      backup_paths([path], tags: tags)
    end

    def forget_after_success
      prune
    end

    def prune
      retention_tag_sets.map do |tags|
        args = ['forget', '--prune', '--group-by', 'host'] + config.retention_args + filter_tag_args(tags)
        log("running restic forget/prune with retention policy for #{retention_scope(tags)}")
        run(args)
      end
    end

    def check
      args = %w[check]
      args.concat(['--read-data-subset', config.check_read_data_subset]) if config.check_read_data_subset
      started_at = Time.now.utc
      result = run(args)
      write_last_check(status: 'ok', started_at: started_at, finished_at: Time.now.utc, output: result.stdout)
      result
    rescue CommandError => e
      write_last_check(status: 'failed', started_at: started_at || Time.now.utc, finished_at: Time.now.utc,
                       error: e.message)
      raise
    end

    def snapshots(tags: common_tags)
      run(['snapshots'] + filter_tag_args(tags))
    end

    def snapshots_json(tags: common_tags)
      output = run(['snapshots', '--json'] + filter_tag_args(tags), log_output: false).stdout
      snapshots = JSON.parse(output)
      required_tags = tags.compact
      snapshots.select do |snapshot|
        snapshot_tags = Array(snapshot['tags'])
        required_tags.all? { |tag| snapshot_tags.include?(tag) }
      end
    end

    def latest_snapshot(tags:)
      snapshots = snapshots_json(tags: common_tags + tags)
      snapshots.max_by { |snapshot| Time.parse(snapshot.fetch('time')) }
    rescue JSON::ParserError
      nil
    end

    def ls_json(snapshot)
      output = run(['ls', '--json', snapshot], log_output: false).stdout
      output.lines.filter_map do |line|
        JSON.parse(line)
      rescue JSON::ParserError
        nil
      end
    end

    def database_file(snapshot, adapter, database_name: nil)
      legacy_prefix = "databases/#{config.app_name}/#{adapter}/"
      app = config.app_name.gsub(/[^A-Za-z0-9_.-]+/, '-')
      database = database_name.to_s.gsub(/[^A-Za-z0-9_.-]+/, '-')
      stable_prefix = database.empty? ? nil : "databases/#{app}/#{database}/#{adapter}."
      flat_prefix = "databases-#{app}-#{adapter}-"
      named_flat_prefix = database.empty? ? nil : "databases-#{app}-#{database}-#{adapter}-"
      ls_json(snapshot).find do |entry|
        next false unless entry['type'] == 'file'

        normalized = entry['path'].to_s.sub(%r{\A/+}, '')
        (stable_prefix && normalized.start_with?(stable_prefix)) ||
          normalized.start_with?(legacy_prefix) ||
          File.basename(normalized).start_with?(flat_prefix) ||
          (named_flat_prefix && File.basename(normalized).start_with?(named_flat_prefix))
      end&.fetch('path')
    end

    def pipe_dump_to_command(snapshot, filename, command)
      restic_command = CommandSpec.new(argv: ['restic', 'dump', snapshot, filename], env: restic_env)
      pipe_commands(restic_command, command, producer_label: 'restic dump', consumer_label: command.argv.first)
    end

    def write_dump_to_path(snapshot, filename, target_path)
      command = CommandSpec.new(argv: ['restic', 'dump', snapshot, filename], env: restic_env)
      target_path = File.expand_path(target_path)
      FileUtils.mkdir_p(File.dirname(target_path))
      temp_path = "#{target_path}.kamal-backup-#{$PROCESS_ID}.tmp"

      output = Command.output
      context = output&.command_start(command, redactor: redactor)
      Open3.popen3(command.env, *command.argv) do |stdin, stdout, stderr, wait_thread|
        stdin.close
        stderr_reader = Thread.new do
          Command.collect_stream(stderr, command_output: output, context: context, stream: :stderr, redactor: redactor)
        end
        File.open(temp_path, 'wb') { |file| IO.copy_stream(stdout, file) }
        err = stderr_reader.value
        status = wait_thread.value
        output&.command_exit(context, status.exitstatus)
        raise_command_error(command, status, '', err) unless status.success?
      end
      File.rename(temp_path, target_path)
      target_path
    rescue Errno::ENOENT => e
      FileUtils.rm_f(temp_path) if temp_path
      raise CommandError.new("command not found: #{command.argv.first}", command: command, status: 127,
                                                                         stderr: e.message)
    rescue StandardError
      FileUtils.rm_f(temp_path) if temp_path
      raise
    end

    def restore_snapshot(snapshot, target)
      log("restoring file snapshot #{snapshot} to #{target}")
      run(['restore', snapshot, '--target', target])
    end

    def run(args, log_output: true)
      Command.capture(
        CommandSpec.new(argv: ['restic'] + args, env: restic_env),
        redactor: redactor,
        log_output: log_output
      )
    end

    def common_tags
      ['kamal-backup', "app:#{config.app_name}"]
    end

    private

    def retention_tag_sets
      database_retention_tag_sets + file_retention_tag_sets
    end

    def database_retention_tag_sets
      config.databases.group_by(&:database_adapter).flat_map do |adapter, databases|
        if databases.one?
          # Pre-0.3 database snapshots did not include database:<name>, so keep
          # the single-database filter broad enough for retention to prune them.
          [common_tags + ['type:database', "adapter:#{adapter}"]]
        else
          databases.map do |database|
            common_tags + ['type:database', "database:#{database.database_name}", "adapter:#{adapter}"]
          end
        end
      end
    end

    def file_retention_tag_sets
      config.backup_paths.any? ? [common_tags + ['type:files']] : []
    end

    def retention_scope(tags)
      tags.reject { |tag| tag == 'kamal-backup' || tag.start_with?('app:') }.join(', ')
    end

    def tag_args(tags)
      tags.compact.each_with_object([]) { |tag, args| args.concat(['--tag', tag]) }
    end

    def exclude_args(patterns)
      patterns.compact.each_with_object([]) { |pattern, args| args.concat(['--exclude', pattern]) }
    end

    def host_args
      ['--host', restic_host]
    end

    def restic_host
      normalize_restic_host([config.app_name, config.accessory_name || 'backup'].compact.join('-'))
    end

    def normalize_restic_host(value)
      normalized = value.to_s.gsub(/[^A-Za-z0-9_.-]+/, '-').gsub(/\A-+|-+\z/, '')
      normalized.empty? ? 'kamal-backup' : normalized
    end

    def filter_tag_args(tags)
      tags = tags.compact
      tags.empty? ? [] : ['--tag', tags.join(',')]
    end

    def restic_env
      config.env.each_with_object({}) do |(key, value), env|
        env[key] = value if key.to_s.match?(RESTIC_ENV_PATTERN)
      end
    end

    def pipe_commands(producer, consumer, producer_label:, consumer_label:)
      output = Command.output
      producer_context = output&.command_start(producer, redactor: redactor)
      Open3.popen3(producer.env, *producer.argv) do |producer_stdin, producer_stdout, producer_stderr, producer_wait|
        producer_stdin.close

        consumer_context = output&.command_start(consumer, redactor: redactor)
        Open3.popen3(consumer.env,
                     *consumer.argv) do |consumer_stdin, consumer_stdout, consumer_stderr, consumer_wait|
          producer_err_reader = Thread.new do
            Command.collect_stream(producer_stderr, command_output: output, context: producer_context, stream: :stderr,
                                                    redactor: redactor)
          end
          consumer_out_reader = Thread.new do
            Command.collect_stream(consumer_stdout, command_output: output, context: consumer_context, stream: :stdout,
                                                    redactor: redactor)
          end
          consumer_err_reader = Thread.new do
            Command.collect_stream(consumer_stderr, command_output: output, context: consumer_context, stream: :stderr,
                                                    redactor: redactor)
          end

          copy_error = nil
          copy_thread = Thread.new do
            IO.copy_stream(producer_stdout, consumer_stdin)
          rescue StandardError => e
            copy_error = e
          ensure
            consumer_stdin.close unless consumer_stdin.closed?
          end

          copy_thread.join
          producer_status = producer_wait.value
          consumer_status = consumer_wait.value
          output&.command_exit(producer_context, producer_status.exitstatus)
          output&.command_exit(consumer_context, consumer_status.exitstatus)

          producer_err = producer_err_reader.value
          consumer_out = consumer_out_reader.value
          consumer_err = consumer_err_reader.value

          if copy_error
            raise CommandError.new(
              "failed to pipe #{producer_label} to #{consumer_label}: #{copy_error.message}",
              command: consumer,
              stderr: copy_error.message
            )
          end

          raise_command_error(producer, producer_status, '', producer_err) unless producer_status.success?
          raise_command_error(consumer, consumer_status, consumer_out, consumer_err) unless consumer_status.success?

          CommandResult.new(stdout: consumer_out, stderr: consumer_err, status: consumer_status.exitstatus)
        end
      end
    rescue Errno::ENOENT => e
      command = e.message.include?(producer.argv.first) ? producer : consumer
      raise CommandError.new("command not found: #{command.argv.first}", command: command, status: 127,
                                                                         stderr: e.message)
    end

    def raise_command_error(command, status, stdout, stderr)
      raise CommandError.new(
        "command failed (#{status.exitstatus}): #{command.display(redactor)}\n#{redactor.redact_string(stderr)}",
        command: command,
        status: status.exitstatus,
        stdout: redactor.redact_string(stdout),
        stderr: redactor.redact_string(stderr)
      )
    end

    def raise_stream_error(command, error, stdout, stderr)
      raise CommandError.new(
        "failed to stream file to #{command.display(redactor)}: #{error.message}\n#{redactor.redact_string(stderr)}",
        command: command,
        stdout: redactor.redact_string(stdout),
        stderr: redactor.redact_string(stderr)
      )
    end

    def write_last_check(payload)
      FileUtils.mkdir_p(config.state_dir)
      File.write(config.last_check_path, JSON.pretty_generate(payload.transform_values do |value|
        value.respond_to?(:iso8601) ? value.iso8601 : redactor.redact_string(value.to_s)
      end))
    rescue SystemCallError
      nil
    end

    def log(message)
      if Command.output
        Command.output.info(message, redactor: redactor)
      else
        $stdout.puts("[kamal-backup] #{redactor.redact_string(message)}")
      end
    end
  end
end
