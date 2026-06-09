# frozen_string_literal: true

unless ENV['SKIP_COVERAGE']
  require 'simplecov'
  require 'simplecov-cobertura'

  SimpleCov.start do
    add_filter '/test/'

    enable_coverage :branch

    formatter SimpleCov::Formatter::MultiFormatter.new(
      [
        SimpleCov::Formatter::SimpleFormatter,
        SimpleCov::Formatter::CoberturaFormatter
      ]
    )
  end
end

$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))

require 'fileutils'
require 'minitest/autorun'
require 'minitest/mock'
require 'open3'
require 'rbconfig'
require 'tmpdir'
require 'kamal_backup'

module TestHelpers
  def base_env(overrides = {})
    {
      'APP_NAME' => 'test-app',
      'RESTIC_REPOSITORY' => '/tmp/restic-repo',
      'RESTIC_PASSWORD' => 'restic-secret',
      'BACKUP_PATHS' => '/tmp/files'
    }.merge(overrides)
  end
end

module Minitest
  class Test
    include TestHelpers
  end
end
