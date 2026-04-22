require_relative "test_helper"

class ResticTest < Minitest::Test
  class FakeRestic < KamalBackup::Restic
    def initialize(config, json)
      super(config, redactor: KamalBackup::Redactor.new(env: {}))
      @json = json
    end

    def run(_args)
      KamalBackup::CommandResult.new(stdout: @json, stderr: "", status: 0)
    end
  end

  def test_snapshots_json_requires_all_requested_tags
    config = KamalBackup::Config.new(env: base_env("APP_NAME" => "demo"))
    json = [
      { "short_id" => "db", "tags" => ["kamal-backup", "app:demo", "type:database"] },
      { "short_id" => "files", "tags" => ["kamal-backup", "app:demo", "type:files"] },
      { "short_id" => "other", "tags" => ["kamal-backup", "app:other", "type:database"] }
    ].to_json
    restic = FakeRestic.new(config, json)

    snapshots = restic.snapshots_json(tags: ["kamal-backup", "app:demo", "type:database"])

    assert_equal ["db"], snapshots.map { |snapshot| snapshot["short_id"] }
  end
end
