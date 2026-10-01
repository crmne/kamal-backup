# frozen_string_literal: true

require_relative 'test_helper'

class PrivateTempfileTest < Minitest::Test
  def test_publish_replaces_the_target_with_an_owner_only_file
    Dir.mktmpdir do |dir|
      target = File.join(dir, 'database.dump')
      File.write(target, 'old')

      with_umask(0) do
        file = KamalBackup::PrivateTempfile.open(target)
        file.write('dump-bytes')
        KamalBackup::PrivateTempfile.publish(file, target, overwrite: true)
        KamalBackup::PrivateTempfile.discard(file)
      end

      assert_equal 'dump-bytes', File.read(target)
      assert_equal 0o600, File.stat(target).mode & 0o777
      refute File.symlink?(target)
      assert_empty Dir.glob("#{target}*.tmp")
    end
  end

  def test_open_does_not_follow_a_precreated_temp_symlink
    Dir.mktmpdir do |dir|
      target = File.join(dir, 'database.dump')
      victim = File.join(dir, 'victim')
      File.write(victim, 'keep-me')
      trap = "#{target}.kamal-backup-#{Process.pid}.tmp"
      File.symlink(victim, trap)

      file = nil
      with_umask(0) do
        file = KamalBackup::PrivateTempfile.open(target)
        file.write('dump-bytes')
        KamalBackup::PrivateTempfile.publish(file, target, overwrite: false)
      ensure
        KamalBackup::PrivateTempfile.discard(file)
      end

      assert_equal 'keep-me', File.read(victim)
      assert_equal 'dump-bytes', File.read(target)
      assert_equal 0o600, File.stat(target).mode & 0o777
      assert_equal [trap], Dir.glob("#{target}*.tmp")
      assert_equal victim, File.readlink(trap)
    end
  end

  def test_publish_without_overwrite_leaves_a_file_created_after_open
    Dir.mktmpdir do |dir|
      target = File.join(dir, 'database.dump')
      file = KamalBackup::PrivateTempfile.open(target)
      file.write('downloaded')
      File.write(target, 'winner')

      error = assert_raises(KamalBackup::ConfigurationError) do
        KamalBackup::PrivateTempfile.publish(file, target, overwrite: false)
      end

      assert_includes error.message, 'output file already exists'
      assert_includes error.message, 'pass --yes to overwrite'
      assert_equal 'winner', File.read(target)
    ensure
      KamalBackup::PrivateTempfile.discard(file)
    end
  end

  def test_discard_removes_an_unpublished_temp_file
    Dir.mktmpdir do |dir|
      target = File.join(dir, 'database.dump')
      file = KamalBackup::PrivateTempfile.open(target)
      file.write('partial')
      KamalBackup::PrivateTempfile.discard(file)

      refute_path_exists target
      assert_empty Dir.glob(File.join(dir, '*.tmp'))
    end
  end
end
