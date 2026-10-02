# frozen_string_literal: true

require 'fileutils'
require 'tempfile'
require_relative 'errors'

module KamalBackup
  # Same-directory dump output that is created exclusively and kept owner-only.
  # A predictable path opened with truncation follows a pre-created symlink and
  # inherits the process umask.
  class PrivateTempfile
    MODE = 0o600
    UNSUPPORTED_LINK_ERRORS = [Errno::EPERM, Errno::ENOTSUP, Errno::EOPNOTSUPP, Errno::EXDEV].uniq.freeze

    def self.open(target_path)
      directory = File.dirname(target_path)
      file = Tempfile.create(
        ["#{File.basename(target_path)}.kamal-backup-", '.tmp'],
        directory,
        mode: File::BINARY
      )
      file.chmod(MODE)
      file
    end

    # File.rename always replaces the destination. Without overwrite authorization,
    # File.link fails with EEXIST if that name already exists, including a file
    # created after the earlier confirmation check.
    def self.publish(file, target_path, overwrite:)
      file.flush
      file.close
      if overwrite
        File.rename(file.path, target_path)
      else
        link_exclusively(file.path, target_path)
      end
    end

    def self.discard(file)
      return unless file

      file.close unless file.closed?
      FileUtils.rm_f(file.path) if file.path
    end

    def self.link_exclusively(source, target_path)
      File.link(source, target_path)
      File.unlink(source)
    rescue Errno::EEXIST
      raise ConfigurationError, "output file already exists: #{target_path}; pass --yes to overwrite"
    rescue *UNSUPPORTED_LINK_ERRORS
      copy_exclusively(source, target_path)
    end

    # Exclusive create still refuses a name that appeared during the download.
    # A failed copy removes that new file so a partial dump is not left behind.
    def self.copy_exclusively(source, target_path)
      created = false
      copied = false
      File.open(target_path, File::WRONLY | File::CREAT | File::EXCL | File::BINARY, MODE) do |out|
        created = true
        out.chmod(MODE)
        File.open(source, File::RDONLY | File::BINARY) { |input| IO.copy_stream(input, out) }
        copied = true
      end
      File.unlink(source)
    rescue Errno::EEXIST
      raise ConfigurationError, "output file already exists: #{target_path}; pass --yes to overwrite"
    rescue StandardError
      remove_partial_copy(target_path) if created && !copied
      raise
    end

    def self.remove_partial_copy(path)
      File.unlink(path)
    rescue Errno::ENOENT
      nil
    end
    private_class_method :link_exclusively, :copy_exclusively, :remove_partial_copy
  end
end
