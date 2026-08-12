FROM ruby:3.3-slim

ARG RESTIC_VERSION=0.18.1
ARG RESTIC_SHA256_AMD64=680838f19d67151adba227e1570cdd8af12c19cf1735783ed1ba928bc41f363d
ARG RESTIC_SHA256_ARM64=87f53fddde38764095e9c058a3b31834052c37e5826d2acf34e18923c006bd45
ARG RCLONE_RELEASE=1.75.0
ARG RCLONE_SHA256_AMD64=aa2804e08f48250e71009c727124b6341cd0288465804a9a09d14663cabafbaa
ARG RCLONE_SHA256_ARM64=d0ad88ba4c8e285b7c9efa591e0ab643280a91741e13c27f3a9c0957ccfa5203
ARG TARGETARCH

ENV KAMAL_BACKUP_STATE_DIR=/var/lib/kamal-backup \
    KAMAL_BACKUP_POSTGRES_CLIENT_ROOT=/usr/lib/postgresql

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
    unzip \
  && /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh -y \
  && apt-get install -y --no-install-recommends \
    postgresql-client-14 \
    postgresql-client-15 \
    postgresql-client-16 \
    postgresql-client-17 \
    postgresql-client-18 \
  && case "${TARGETARCH}" in \
    amd64) restic_arch=amd64; restic_sha="${RESTIC_SHA256_AMD64}"; rclone_sha="${RCLONE_SHA256_AMD64}" ;; \
    arm64) restic_arch=arm64; restic_sha="${RESTIC_SHA256_ARM64}"; rclone_sha="${RCLONE_SHA256_ARM64}" ;; \
    *) echo "unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
  esac \
  && curl -fsSL -o /tmp/restic.bz2 "https://github.com/restic/restic/releases/download/v${RESTIC_VERSION}/restic_${RESTIC_VERSION}_linux_${restic_arch}.bz2" \
  && echo "${restic_sha}  /tmp/restic.bz2" | sha256sum -c - \
  && bunzip2 /tmp/restic.bz2 \
  && install -m 0755 /tmp/restic /usr/local/bin/restic \
  && curl -fsSL -o /tmp/rclone.zip "https://downloads.rclone.org/v${RCLONE_RELEASE}/rclone-v${RCLONE_RELEASE}-linux-${restic_arch}.zip" \
  && echo "${rclone_sha}  /tmp/rclone.zip" | sha256sum -c - \
  && unzip -q /tmp/rclone.zip -d /tmp/rclone \
  && install -m 0755 "/tmp/rclone/rclone-v${RCLONE_RELEASE}-linux-${restic_arch}/rclone" /usr/local/bin/rclone \
  && restic version \
  && rclone version \
  && ssh -V \
  && for version in 14 15 16 17 18; do test -x "/usr/lib/postgresql/${version}/bin/pg_dump"; done \
  && rm -rf /var/lib/apt/lists/* /tmp/restic /tmp/rclone /tmp/rclone.zip

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
