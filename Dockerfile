FROM ruby:3.3-slim

ARG RESTIC_VERSION=0.18.1
ARG RESTIC_SHA256_AMD64=680838f19d67151adba227e1570cdd8af12c19cf1735783ed1ba928bc41f363d
ARG RESTIC_SHA256_ARM64=87f53fddde38764095e9c058a3b31834052c37e5826d2acf34e18923c006bd45
ARG TARGETARCH

ENV KAMAL_BACKUP_STATE_DIR=/var/lib/kamal-backup

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    bzip2 \
    ca-certificates \
    curl \
    mariadb-client \
    openssh-client \
    postgresql-client-common \
    sqlite3 \
    tini \
  && /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh -y \
  && apt-get install -y --no-install-recommends postgresql-client-18 \
  && case "${TARGETARCH}" in \
    amd64) restic_arch=amd64; restic_sha="${RESTIC_SHA256_AMD64}" ;; \
    arm64) restic_arch=arm64; restic_sha="${RESTIC_SHA256_ARM64}" ;; \
    *) echo "unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
  esac \
  && curl -fsSL -o /tmp/restic.bz2 "https://github.com/restic/restic/releases/download/v${RESTIC_VERSION}/restic_${RESTIC_VERSION}_linux_${restic_arch}.bz2" \
  && echo "${restic_sha}  /tmp/restic.bz2" | sha256sum -c - \
  && bunzip2 /tmp/restic.bz2 \
  && install -m 0755 /tmp/restic /usr/local/bin/restic \
  && restic version \
  && ssh -V \
  && rm -rf /var/lib/apt/lists/* /tmp/restic

WORKDIR /app

COPY Gemfile Gemfile.lock kamal-backup.gemspec ./
COPY lib/kamal_backup/version.rb ./lib/kamal_backup/version.rb

RUN bundle config set without "development test" \
  && bundle install

COPY README.md LICENSE ./
COPY exe ./exe
COPY lib ./lib

RUN ln -s /app/exe/kamal-backup /usr/local/bin/kamal-backup \
  && mkdir -p -m 0700 /root/.ssh \
  && mkdir -p /var/lib/kamal-backup /restore/files

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["kamal-backup", "schedule"]
