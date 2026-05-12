require_relative "test_helper"
require "json"

class EvidenceTest < Minitest::Test
  class FakeRestic
    def latest_snapshot(tags:)
      case tags
      when ["type:database"]
        { "short_id" => "db123", "time" => "2026-04-23T11:00:00Z", "tags" => tags }
      when ["type:files"]
        { "short_id" => "files123", "time" => "2026-04-23T11:00:00Z", "tags" => tags }
      end
    end
  end

  class ErrorRestic
    def latest_snapshot(tags:)
      raise KamalBackup::CommandError.new(
        "restic failed",
        command: KamalBackup::CommandSpec.new(argv: ["restic", "snapshots"]),
        status: 1,
        stderr: "connection refused"
      )
    end
  end

  def test_evidence_includes_the_last_restore_drill
    Dir.mktmpdir do |dir|
      config = KamalBackup::Config.new(env: base_env(
        "DATABASE_ADAPTER" => "sqlite",
        "BACKUP_PATHS" => "/tmp/storage",
        "KAMAL_BACKUP_STATE_DIR" => dir
      ))
      File.write(
        config.last_restore_drill_path,
        JSON.pretty_generate({ schema_version: 1, kind: "drill_result", status: "ok", scope: "local", finished_at: "2026-04-23T11:00:00Z" })
      )

      evidence = KamalBackup::Evidence.new(
        config,
        restic: FakeRestic.new,
        redactor: KamalBackup::Redactor.new(env: {})
      ).to_h

      assert_equal 1, evidence.fetch(:schema_version)
      assert_equal "evidence", evidence.fetch(:kind)
      assert_equal "ok", evidence.fetch(:last_restore_drill).fetch("status")
      assert_equal "local", evidence.fetch(:last_restore_drill).fetch("scope")
    end
  end

  def test_evidence_without_drill_or_check_files
    Dir.mktmpdir do |dir|
      config = KamalBackup::Config.new(env: base_env(
        "DATABASE_ADAPTER" => "sqlite",
        "BACKUP_PATHS" => "/tmp/storage",
        "KAMAL_BACKUP_STATE_DIR" => dir
      ))

      evidence = KamalBackup::Evidence.new(
        config,
        restic: FakeRestic.new,
        redactor: KamalBackup::Redactor.new(env: {})
      ).to_h

      assert_equal 1, evidence.fetch(:schema_version)
      assert_equal "evidence", evidence.fetch(:kind)
      assert_nil evidence.fetch(:last_restore_drill)
      assert_nil evidence.fetch(:last_restic_check)
    end
  end

  def test_evidence_includes_last_check
    Dir.mktmpdir do |dir|
      config = KamalBackup::Config.new(env: base_env(
        "DATABASE_ADAPTER" => "sqlite",
        "BACKUP_PATHS" => "/tmp/storage",
        "KAMAL_BACKUP_STATE_DIR" => dir
      ))
      File.write(
        config.last_check_path,
        JSON.pretty_generate({ status: "ok", started_at: "2026-04-23T10:00:00Z", finished_at: "2026-04-23T10:01:00Z", output: "no errors" })
      )

      evidence = KamalBackup::Evidence.new(
        config,
        restic: FakeRestic.new,
        redactor: KamalBackup::Redactor.new(env: {})
      ).to_h

      assert_equal "ok", evidence.fetch(:last_restic_check).fetch("status")
      assert_equal "no errors", evidence.fetch(:last_restic_check).fetch("output")
    end
  end

  def test_evidence_handles_corrupt_check_json
    Dir.mktmpdir do |dir|
      config = KamalBackup::Config.new(env: base_env(
        "DATABASE_ADAPTER" => "sqlite",
        "BACKUP_PATHS" => "/tmp/storage",
        "KAMAL_BACKUP_STATE_DIR" => dir
      ))
      File.write(config.last_check_path, "not valid json{{{")

      evidence = KamalBackup::Evidence.new(
        config,
        restic: FakeRestic.new,
        redactor: KamalBackup::Redactor.new(env: {})
      ).to_h

      check = evidence.fetch(:last_restic_check)
      assert check.key?("error") || check.key?(:error)
    end
  end

  def test_evidence_handles_corrupt_drill_json
    Dir.mktmpdir do |dir|
      config = KamalBackup::Config.new(env: base_env(
        "DATABASE_ADAPTER" => "sqlite",
        "BACKUP_PATHS" => "/tmp/storage",
        "KAMAL_BACKUP_STATE_DIR" => dir
      ))
      File.write(config.last_restore_drill_path, "broken json!")

      evidence = KamalBackup::Evidence.new(
        config,
        restic: FakeRestic.new,
        redactor: KamalBackup::Redactor.new(env: {})
      ).to_h

      drill = evidence.fetch(:last_restore_drill)
      assert drill.key?("error") || drill.key?(:error)
    end
  end

  def test_evidence_snapshot_error_returns_error_hash
    Dir.mktmpdir do |dir|
      config = KamalBackup::Config.new(env: base_env(
        "DATABASE_ADAPTER" => "sqlite",
        "BACKUP_PATHS" => "/tmp/storage",
        "KAMAL_BACKUP_STATE_DIR" => dir
      ))

      evidence = KamalBackup::Evidence.new(
        config,
        restic: ErrorRestic.new,
        redactor: KamalBackup::Redactor.new(env: {})
      ).to_h

      assert evidence.fetch(:latest_database_backup).key?(:error)
      assert evidence.fetch(:latest_file_backup).key?(:error)
    end
  end

  def test_evidence_includes_snapshot_summaries
    Dir.mktmpdir do |dir|
      config = KamalBackup::Config.new(env: base_env(
        "DATABASE_ADAPTER" => "sqlite",
        "BACKUP_PATHS" => "/tmp/storage",
        "KAMAL_BACKUP_STATE_DIR" => dir
      ))

      evidence = KamalBackup::Evidence.new(
        config,
        restic: FakeRestic.new,
        redactor: KamalBackup::Redactor.new(env: {})
      ).to_h

      db_backup = evidence.fetch(:latest_database_backup)
      assert_equal "db123", db_backup.fetch(:id)
      assert_equal "2026-04-23T11:00:00Z", db_backup.fetch(:time)

      file_backup = evidence.fetch(:latest_file_backup)
      assert_equal "files123", file_backup.fetch(:id)
    end
  end

  def test_evidence_redacts_restic_repository
    Dir.mktmpdir do |dir|
      config = KamalBackup::Config.new(env: base_env(
        "DATABASE_ADAPTER" => "sqlite",
        "BACKUP_PATHS" => "/tmp/storage",
        "KAMAL_BACKUP_STATE_DIR" => dir,
        "RESTIC_REPOSITORY" => "s3:https://user:secret@s3.example.com/bucket"
      ))

      evidence = KamalBackup::Evidence.new(
        config,
        restic: FakeRestic.new,
        redactor: KamalBackup::Redactor.new(env: config.env)
      ).to_h

      refute_includes evidence.fetch(:restic_repository), "secret"
      assert_includes evidence.fetch(:restic_repository), "[REDACTED]"
    end
  end

end
