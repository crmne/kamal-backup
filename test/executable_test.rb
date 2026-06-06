# frozen_string_literal: true

require_relative 'test_helper'

class ExecutableTest < Minitest::Test
  def test_executable_runs_without_a_gemfile
    Dir.mktmpdir do |dir|
      exe_dir = File.join(dir, 'exe')
      lib_dir = File.join(dir, 'lib')

      FileUtils.mkdir_p(exe_dir)
      FileUtils.cp_r(File.join(__dir__, '..', 'lib', '.'), lib_dir)
      FileUtils.cp(File.join(__dir__, '..', 'exe', 'kamal-backup'), exe_dir)

      out, err = capture_subprocess(
        RbConfig.ruby,
        File.join(exe_dir, 'kamal-backup'),
        '--version'
      )

      refute_includes err, 'Gemfile not found'
      assert_equal "#{KamalBackup::VERSION}\n", out
    end
  end

  private

  def capture_subprocess(*argv)
    stdout, stderr, status = Open3.capture3(
      {
        'BUNDLE_GEMFILE' => nil,
        'RUBYLIB' => nil,
        'RUBYOPT' => nil
      },
      *argv
    )

    assert status.success?, "command failed: #{argv.join(' ')}\nstdout: #{stdout}\nstderr: #{stderr}"

    [stdout, stderr]
  end
end
