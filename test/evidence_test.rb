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
end
