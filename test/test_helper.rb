$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "fileutils"
require "minitest/autorun"
require "rbconfig"
require "tmpdir"
require "kamal_backup"

module TestHelpers
  def base_env(overrides = {})
    {
      "APP_NAME" => "test-app",
      "RESTIC_REPOSITORY" => "/tmp/restic-repo",
      "RESTIC_PASSWORD" => "restic-secret",
      "BACKUP_PATHS" => "/tmp/files"
    }.merge(overrides)
  end
end

class Minitest::Test
  include TestHelpers
end
