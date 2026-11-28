# frozen_string_literal: true

require_relative 'test_helper'

class RcloneTest < Minitest::Test
  def test_copy_runs_rclone_copy_with_rclone_environment
    config = KamalBackup::Config.new(
      env: base_env(
        'RCLONE_CONFIG_R2_TYPE' => 's3',
        'RCLONE_CONFIG_R2_SECRET_ACCESS_KEY' => 'r2-secret',
        'DATABASE_PASSWORD' => 'db-secret'
      ),
      load_project_defaults: false
    )
    calls = []
    rclone = KamalBackup::Rclone.new(config, redactor: KamalBackup::Redactor.new(env: {}),
                                             runner: lambda { |args, env:|
                                               calls << { args: args, env: env }
                                             })
    rclone.define_singleton_method(:log) { |_message| nil }

    rclone.copy('r2:production', 's3:app-files-backups/production')

    assert_equal([%w[copy r2:production s3:app-files-backups/production --fast-list]], calls.map { |call| call[:args] })
    env = calls.first.fetch(:env)
    assert_equal 's3', env['RCLONE_CONFIG_R2_TYPE']
    assert_equal 'r2-secret', env['RCLONE_CONFIG_R2_SECRET_ACCESS_KEY']
    refute env.key?('DATABASE_PASSWORD')
  end
end
