# frozen_string_literal: true

require 'pathname'

module KamalBackupDocs
  module VersionLabel
    module_function

    AUTO_VALUES = %w[auto kamal_backup_auto].freeze
    VERSION_FILE = 'lib/kamal_backup/version.rb'

    def apply(site)
      versions = site.data['versions']
      return unless versions.is_a?(Hash)

      current = versions['current'] || versions[:current]
      return unless auto_value?(current)

      resolved = resolve_version(site)
      return unless resolved

      resolved_label = "v#{resolved}"
      versions['current'] = resolved_label
      versions[:current] = resolved_label if versions.key?(:current)

      items = versions['items'] || versions[:items]
      return unless items.is_a?(Array) && items.first.is_a?(Hash)

      items.first['title'] = "#{resolved_label} (current)"
      items.first['url'] = '/' if items.first['url'].to_s.strip.empty?
    rescue StandardError => e
      Jekyll.logger.warn('kamal-backup-version', "Unable to resolve version: #{e.message}")
    end

    def auto_value?(value)
      AUTO_VALUES.include?(value.to_s.strip.downcase)
    end

    def resolve_version(site)
      from_loaded_constant || from_version_file(site)
    end

    def from_loaded_constant
      return nil unless defined?(::KamalBackup::VERSION)

      normalize_version(::KamalBackup::VERSION)
    end

    def from_version_file(site)
      candidate_version_files(site).each do |version_file|
        next unless version_file.file?

        extracted = version_file.read[/VERSION\s*=\s*["']([^"']+)["']/, 1]
        normalized = normalize_version(extracted)
        return normalized if normalized
      end

      nil
    rescue StandardError
      nil
    end

    def candidate_version_files(site)
      roots = []
      configured_root = site.config['kamal_backup_root']
      roots << Pathname.new(configured_root) if configured_root && !configured_root.to_s.strip.empty?

      env_root = ENV['KAMAL_BACKUP_ROOT']
      roots << Pathname.new(env_root) if env_root && !env_root.strip.empty?

      cursor = Pathname.new(site.source).expand_path
      loop do
        roots << cursor
        break if cursor.root?

        cursor = cursor.parent
      end

      roots.uniq.map { |root| root.join(VERSION_FILE) }
    end

    def normalize_version(value)
      version = value.to_s.strip
      return nil if version.empty?

      version.sub(/\Av/i, '')
    end
  end
end

Jekyll::Hooks.register :site, :pre_render do |site|
  KamalBackupDocs::VersionLabel.apply(site)
end
