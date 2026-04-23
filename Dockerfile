FROM ruby:3.3-slim

ENV KAMAL_BACKUP_STATE_DIR=/var/lib/kamal-backup

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

COPY Gemfile Gemfile.lock kamal-backup.gemspec ./
COPY lib/kamal_backup/version.rb ./lib/kamal_backup/version.rb

RUN bundle config set without "test" \
  && bundle install

COPY README.md LICENSE ./
COPY exe ./exe
COPY lib ./lib

RUN ln -s /app/exe/kamal-backup /usr/local/bin/kamal-backup \
  && mkdir -p /var/lib/kamal-backup /restore/files

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["kamal-backup", "schedule"]
