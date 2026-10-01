# frozen_string_literal: true

require 'fileutils'
require 'tempfile'

module KamalBackup
  # Same-directory dump output that is created exclusively and kept owner-only.
  # A predictable path opened with truncation follows a pre-created symlink and
  # inherits the process umask.
  class PrivateTempfile
    MODE = 0o600

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

    def self.publish(file, target_path)
      file.flush
      file.close
      File.rename(file.path, target_path)
    end

    def self.discard(file)
      return unless file

      file.close unless file.closed?
      FileUtils.rm_f(file.path) if file.path
    end
  end
end
