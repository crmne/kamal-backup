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

  def test_publish_without_overwrite_copies_when_hard_links_are_unsupported
    Dir.mktmpdir do |dir|
      target = File.join(dir, 'database.dump')

      with_umask(0) do
        file = KamalBackup::PrivateTempfile.open(target)
        file.write('dump-bytes')
        File.stub(:link, ->(*) { raise Errno::ENOTSUP }) do
          KamalBackup::PrivateTempfile.publish(file, target, overwrite: false)
        end
        KamalBackup::PrivateTempfile.discard(file)
      end

      assert_equal 'dump-bytes', File.binread(target)
      assert_equal 0o600, File.stat(target).mode & 0o777
      assert_empty Dir.glob("#{target}*.tmp")
    end
  end

  def test_unsupported_link_still_refuses_a_file_created_during_the_download
    Dir.mktmpdir do |dir|
      target = File.join(dir, 'database.dump')
      file = KamalBackup::PrivateTempfile.open(target)
      file.write('downloaded')
      File.write(target, 'winner')

      error = assert_raises(KamalBackup::ConfigurationError) do
        File.stub(:link, ->(*) { raise Errno::EOPNOTSUPP }) do
          KamalBackup::PrivateTempfile.publish(file, target, overwrite: false)
        end
      end

      assert_includes error.message, 'output file already exists'
      assert_equal 'winner', File.binread(target)
    ensure
      KamalBackup::PrivateTempfile.discard(file)
    end
  end

  def test_unsupported_link_removes_a_partial_copy_when_the_copy_fails
    Dir.mktmpdir do |dir|
      target = File.join(dir, 'database.dump')
      file = KamalBackup::PrivateTempfile.open(target)
      file.write('downloaded')

      assert_raises(IOError) do
        File.stub(:link, ->(*) { raise Errno::EXDEV }) do
          IO.stub(:copy_stream, ->(*) { raise IOError, 'disk full' }) do
            KamalBackup::PrivateTempfile.publish(file, target, overwrite: false)
          end
        end
      end

      refute_path_exists target
    ensure
      KamalBackup::PrivateTempfile.discard(file)
    end
  end

  def test_unsupported_link_removes_a_partial_copy_when_the_copy_is_interrupted
    Dir.mktmpdir do |dir|
      target = File.join(dir, 'database.dump')
      file = KamalBackup::PrivateTempfile.open(target)
      file.write('downloaded')

      assert_raises(Interrupt) do
        File.stub(:link, ->(*) { raise Errno::ENOTSUP }) do
          IO.stub(:copy_stream, ->(*) { raise Interrupt }) do
            KamalBackup::PrivateTempfile.publish(file, target, overwrite: false)
          end
        end
      end

      refute_path_exists target
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
