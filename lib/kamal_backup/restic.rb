require "fileutils"
require "json"
require "open3"
require "time"
require_relative "command"

module KamalBackup
  class Restic
    attr_reader :config, :redactor

    def initialize(config, redactor:)
      @config = config
      @redactor = redactor
    end

    def ensure_repository!
      run(%w[snapshots --json])
    rescue CommandError => e
      raise e unless config.restic_init_if_missing?

      log("restic repository not ready, running restic init")
      run(%w[init])
    end

    def backup_command_output(command, filename:, tags:)
      restic_command = CommandSpec.new(argv: ["restic", "backup", "--stdin", "--stdin-filename", filename] + tag_args(common_tags + tags))
      log("backing up stream as #{filename}")
      pipe_commands(command, restic_command, producer_label: "dump", consumer_label: "restic backup")
    end

    def backup_file_content(path, filename:, tags:)
      command = CommandSpec.new(argv: ["restic", "backup", "--stdin", "--stdin-filename", filename] + tag_args(common_tags + tags))
      log("backing up file content as #{filename}")

      File.open(path, "rb") do |file|
        Open3.popen3(command.env, *command.argv) do |stdin, stdout, stderr, wait_thread|
          stdout_reader = Thread.new { stdout.read }
          stderr_reader = Thread.new { stderr.read }
          IO.copy_stream(file, stdin)
          stdin.close
          out = stdout_reader.value
          err = stderr_reader.value
          status = wait_thread.value
          raise_command_error(command, status, out, err) unless status.success?

          CommandResult.new(stdout: out, stderr: err, status: status.exitstatus)
        end
      end
    rescue Errno::ENOENT => e
      raise CommandError.new("command not found: #{command.argv.first}", command: command, status: 127, stderr: e.message)
    end

    def backup_path(path, tags:)
      log("backing up path #{path}")
      run(["backup", path] + tag_args(common_tags + tags))
    end

    def forget_after_success!
      args = ["forget", "--prune"] + config.retention_args + tag_args(common_tags)
      log("running restic forget/prune with retention policy")
      run(args)
    end

    def check!
      args = %w[check]
      args.concat(["--read-data-subset", config.check_read_data_subset]) if config.check_read_data_subset
      started_at = Time.now.utc
      result = run(args)
      write_last_check(status: "ok", started_at: started_at, finished_at: Time.now.utc, output: result.stdout)
      result
    rescue CommandError => e
      write_last_check(status: "failed", started_at: started_at || Time.now.utc, finished_at: Time.now.utc, error: e.message)
      raise
    end

    def snapshots(tags: common_tags)
      run(["snapshots"] + tag_args(tags))
    end

    def snapshots_json(tags: common_tags)
      output = run(["snapshots", "--json"] + tag_args(tags)).stdout
      snapshots = JSON.parse(output)
      required_tags = tags.compact
      snapshots.select do |snapshot|
        snapshot_tags = Array(snapshot["tags"])
        required_tags.all? { |tag| snapshot_tags.include?(tag) }
      end
    end

    def latest_snapshot(tags:)
      snapshots = snapshots_json(tags: common_tags + tags)
      snapshots.max_by { |snapshot| Time.parse(snapshot.fetch("time")) }
    rescue JSON::ParserError
      nil
    end

    def ls_json(snapshot)
      output = run(["ls", "--json", snapshot]).stdout
      output.lines.filter_map do |line|
        JSON.parse(line)
      rescue JSON::ParserError
        nil
      end
    end

    def database_file(snapshot, adapter)
      legacy_prefix = "databases/#{config.app_name}/#{adapter}/"
      flat_prefix = "databases-#{config.app_name.gsub(/[^A-Za-z0-9_.-]+/, "-")}-#{adapter}-"
      ls_json(snapshot).find do |entry|
        next false unless entry["type"] == "file"

        normalized = entry["path"].to_s.sub(%r{\A/+}, "")
        normalized.start_with?(legacy_prefix) || File.basename(normalized).start_with?(flat_prefix)
      end&.fetch("path")
    end

    def dump_file_to_command(snapshot, filename, command)
      restic_command = CommandSpec.new(argv: ["restic", "dump", snapshot, filename])
      pipe_commands(restic_command, command, producer_label: "restic dump", consumer_label: command.argv.first)
    end

    def dump_file_to_path(snapshot, filename, target_path)
      command = CommandSpec.new(argv: ["restic", "dump", snapshot, filename])
      target_path = File.expand_path(target_path)
      FileUtils.mkdir_p(File.dirname(target_path))
      temp_path = "#{target_path}.kamal-backup-#{$$}.tmp"

      Open3.popen3(command.env, *command.argv) do |stdin, stdout, stderr, wait_thread|
        stdin.close
        stderr_reader = Thread.new { stderr.read }
        File.open(temp_path, "wb") { |file| IO.copy_stream(stdout, file) }
        err = stderr_reader.value
        status = wait_thread.value
        raise_command_error(command, status, "", err) unless status.success?
      end
      File.rename(temp_path, target_path)
      target_path
    rescue Errno::ENOENT => e
      FileUtils.rm_f(temp_path) if temp_path
      raise CommandError.new("command not found: #{command.argv.first}", command: command, status: 127, stderr: e.message)
    rescue StandardError
      FileUtils.rm_f(temp_path) if temp_path
      raise
    end

    def restore_snapshot(snapshot, target)
      log("restoring file snapshot #{snapshot} to #{target}")
      run(["restore", snapshot, "--target", target])
    end

    def run(args)
      Command.capture(CommandSpec.new(argv: ["restic"] + args), redactor: redactor)
    end

    def common_tags
      ["kamal-backup", "app:#{config.app_name}"]
    end

    private

    def tag_args(tags)
      tags.compact.each_with_object([]) { |tag, args| args.concat(["--tag", tag]) }
    end

    def pipe_commands(producer, consumer, producer_label:, consumer_label:)
      Open3.popen3(producer.env, *producer.argv) do |producer_stdin, producer_stdout, producer_stderr, producer_wait|
        producer_stdin.close

        Open3.popen3(consumer.env, *consumer.argv) do |consumer_stdin, consumer_stdout, consumer_stderr, consumer_wait|
          producer_err_reader = Thread.new { producer_stderr.read }
          consumer_out_reader = Thread.new { consumer_stdout.read }
          consumer_err_reader = Thread.new { consumer_stderr.read }

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

          raise_command_error(producer, producer_status, "", producer_err) unless producer_status.success?
          raise_command_error(consumer, consumer_status, consumer_out, consumer_err) unless consumer_status.success?

          CommandResult.new(stdout: consumer_out, stderr: consumer_err, status: consumer_status.exitstatus)
        end
      end
    rescue Errno::ENOENT => e
      command = e.message.include?(producer.argv.first) ? producer : consumer
      raise CommandError.new("command not found: #{command.argv.first}", command: command, status: 127, stderr: e.message)
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

    def write_last_check(payload)
      FileUtils.mkdir_p(config.state_dir)
      File.write(config.last_check_path, JSON.pretty_generate(payload.transform_values { |value| value.respond_to?(:iso8601) ? value.iso8601 : redactor.redact_string(value.to_s) }))
    rescue SystemCallError
      nil
    end

    def log(message)
      $stdout.puts("[kamal-backup] #{redactor.redact_string(message)}")
    end
  end
end
