FROM ruby:3.3-slim

ENV KAMAL_BACKUP_VERSION=0.1.0 \
    KAMAL_BACKUP_IMAGE_VERSION=0.1.0 \
    KAMAL_BACKUP_STATE_DIR=/var/lib/kamal-backup

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    ca-certificates \
    mariadb-client \
    postgresql-client \
    restic \
    sqlite3 \
    tini \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY Gemfile kamal-backup.gemspec README.md LICENSE ./
COPY exe ./exe
COPY lib ./lib

RUN gem build kamal-backup.gemspec \
  && gem install --no-document kamal-backup-*.gem \
  && rm -f kamal-backup-*.gem \
  && mkdir -p /var/lib/kamal-backup /restore/files

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["kamal-backup", "schedule"]
