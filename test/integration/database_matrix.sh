#!/usr/bin/env bash

set -euo pipefail

IMAGE=${KAMAL_BACKUP_TEST_IMAGE:-kamal-backup:integration}
SELECTED_CASES=${KAMAL_BACKUP_DATABASE_CASES:-all}
PREFIX="kb-matrix-$$"
NETWORK="${PREFIX}-network"
if [[ -n "${KAMAL_BACKUP_LOG_DIR:-}" ]]; then
  LOG_DIR=$KAMAL_BACKUP_LOG_DIR
  mkdir -p "$LOG_DIR"
  REMOVE_LOG_DIR=false
else
  LOG_DIR=$(mktemp -d -t kamal-backup-matrix.XXXXXX)
  REMOVE_LOG_DIR=true
fi
DB_PASSWORD="matrix-db-secret-$$"
RESTIC_PASSWORD="matrix-restic-secret-$$"
MYSQL_ROOT_PASSWORD="matrix-root-secret-$$"
containers=()
volumes=()

cleanup() {
  set +e
  for container in "${containers[@]}"; do
    docker rm -f "$container" >/dev/null 2>&1
  done
  for volume in "${volumes[@]}"; do
    docker volume rm -f "$volume" >/dev/null 2>&1
  done
  docker network rm "$NETWORK" >/dev/null 2>&1
  if [[ "$REMOVE_LOG_DIR" == true ]]; then
    rm -rf "$LOG_DIR"
  fi
}
trap cleanup EXIT

fail() {
  echo "database matrix failed: $*" >&2
  exit 1
}

case_enabled() {
  local name=$1
  [[ "$SELECTED_CASES" == "all" || " $SELECTED_CASES " == *" $name "* ]]
}

create_volume() {
  local name=$1
  docker volume create "$name" >/dev/null
  volumes+=("$name")
}

wait_for_postgres() {
  local container=$1
  for _attempt in $(seq 1 90); do
    if docker exec "$container" pg_isready --host 127.0.0.1 --username app --dbname app_test >/dev/null 2>&1; then
      return
    fi
    sleep 1
  done
  docker logs "$container" >&2
  fail "$container did not become ready"
}

wait_for_mysql() {
  local container=$1
  local client=$2
  for _attempt in $(seq 1 120); do
    if docker exec --env "MYSQL_PWD=$DB_PASSWORD" "$container" \
      "$client" --protocol TCP --host 127.0.0.1 --user app --execute 'SELECT 1' app_test >/dev/null 2>&1; then
      return
    fi
    sleep 1
  done
  docker logs "$container" >&2
  fail "$container did not become ready"
}

assert_secret_redacted() {
  local log=$1
  local secret=$2
  if grep -Fq "$secret" "$log"; then
    fail "a database password appeared in $(basename "$log")"
  fi
  grep -Fq '[REDACTED]' "$log" || fail "$(basename "$log") did not contain a redacted credential"
}

run_postgres() {
  local major=$1
  local case_id="postgres-${major}"
  case_enabled "$case_id" || return 0

  local container="${PREFIX}-pg-${major}"
  local repository="${PREFIX}-pg-${major}-repo"
  local backup_log="$LOG_DIR/${case_id}-backup.log"
  local restore_log="$LOG_DIR/${case_id}-restore.log"

  echo "==> PostgreSQL ${major}"
  docker pull "postgres:${major}-bookworm" >/dev/null
  create_volume "$repository"
  docker run --detach --name "$container" --network "$NETWORK" \
    --env POSTGRES_USER=app \
    --env "POSTGRES_PASSWORD=$DB_PASSWORD" \
    --env POSTGRES_DB=app_test \
    "postgres:${major}-bookworm" >/dev/null
  containers+=("$container")
  wait_for_postgres "$container"

  docker exec --env "PGPASSWORD=$DB_PASSWORD" "$container" psql \
    --username app --dbname app_test --set ON_ERROR_STOP=1 --command \
    "CREATE TABLE items (name text NOT NULL);
     INSERT INTO items VALUES ('stored');
     CREATE FUNCTION stored_item_count() RETURNS bigint LANGUAGE sql AS 'SELECT COUNT(*) FROM items';
     CREATE VIEW stored_items AS SELECT name FROM items;
     CREATE SCHEMA stored_schema;
     CREATE TABLE stored_schema.items (name text NOT NULL);
     INSERT INTO stored_schema.items VALUES ('stored-schema');" >/dev/null

  docker run --rm --network "$NETWORK" --volume "$repository:/repo" \
    --env APP_NAME=matrix \
    --env DATABASE_ADAPTER=postgres \
    --env "DATABASE_URL=postgresql://app@${container}:5432/app_test" \
    --env "PGPASSWORD=$DB_PASSWORD" \
    --env RESTIC_REPOSITORY=/repo \
    --env "RESTIC_PASSWORD=$RESTIC_PASSWORD" \
    --env RESTIC_INIT_IF_MISSING=true \
    --env RESTIC_FORGET_AFTER_BACKUP=false \
    "$IMAGE" kamal-backup backup --force 2>&1 | tee "$backup_log"

  docker exec --env "PGPASSWORD=$DB_PASSWORD" "$container" psql \
    --username app --dbname app_test --set ON_ERROR_STOP=1 --command \
    "UPDATE items SET name = 'changed';
     CREATE TABLE target_only (id integer);
     CREATE VIEW target_only_view AS SELECT id FROM target_only;
     CREATE FUNCTION target_only_function() RETURNS integer LANGUAGE sql AS 'SELECT 1';
     CREATE SCHEMA target_only_schema;
     CREATE TABLE target_only_schema.items (id integer);" >/dev/null

  docker run --rm --network "$NETWORK" --volume "$repository:/repo" \
    --env APP_NAME=matrix \
    --env DATABASE_ADAPTER=postgres \
    --env "DATABASE_URL=postgresql://app@${container}:5432/app_test" \
    --env "PGPASSWORD=$DB_PASSWORD" \
    --env RESTIC_REPOSITORY=/repo \
    --env "RESTIC_PASSWORD=$RESTIC_PASSWORD" \
    "$IMAGE" kamal-backup restore production latest --confirm-production-restore 2>&1 | tee "$restore_log"

  local restored
  restored=$(docker exec --env "PGPASSWORD=$DB_PASSWORD" "$container" psql \
    --username app --dbname app_test --tuples-only --no-align --command \
    "SELECT name || ':' || stored_item_count() || ':' || (SELECT name FROM stored_schema.items) FROM stored_items")
  [[ "$restored" == 'stored:1:stored-schema' ]] || fail "PostgreSQL ${major} did not restore stored schemas, data, and routines"

  local leftovers
  leftovers=$(docker exec --env "PGPASSWORD=$DB_PASSWORD" "$container" psql \
    --username app --dbname app_test --tuples-only --no-align --command \
    "SELECT
       (SELECT COUNT(*) FROM pg_class WHERE relname IN ('target_only', 'target_only_view')) +
       (SELECT COUNT(*) FROM pg_proc WHERE proname = 'target_only_function') +
       (SELECT COUNT(*) FROM pg_namespace WHERE nspname = 'target_only_schema');")
  [[ "$leftovers" == '0' ]] || fail "PostgreSQL ${major} retained target-only objects: $leftovers"

  grep -Fq "/usr/lib/postgresql/${major}/bin/pg_dump" "$backup_log" || \
    fail "PostgreSQL ${major} backup did not select its matching pg_dump"
  grep -Fq "/usr/lib/postgresql/${major}/bin/pg_restore" "$restore_log" || \
    fail "PostgreSQL ${major} restore did not select its matching pg_restore"
  assert_secret_redacted "$backup_log" "$DB_PASSWORD"
  assert_secret_redacted "$restore_log" "$DB_PASSWORD"

  docker rm -f "$container" >/dev/null
  containers=("${containers[@]/$container}")
  docker volume rm -f "$repository" >/dev/null
  volumes=("${volumes[@]/$repository}")
}

mysql_exec() {
  local container=$1
  local client=$2
  local sql=$3
  docker exec --env "MYSQL_PWD=$DB_PASSWORD" "$container" "$client" \
    --protocol TCP --host 127.0.0.1 --user app --batch --skip-column-names --execute "$sql" app_test
}

run_mysql() {
  local family=$1
  local version=$2
  local image=$3
  local client=$4
  local case_id="${family}-${version//./-}"
  case_enabled "$case_id" || return 0

  local container="${PREFIX}-${case_id}"
  local repository="${PREFIX}-${case_id}-repo"
  local backup_log="$LOG_DIR/${case_id}-backup.log"
  local restore_log="$LOG_DIR/${case_id}-restore.log"

  echo "==> ${family} ${version}"
  docker pull "$image" >/dev/null
  create_volume "$repository"
  local server_args=()
  if [[ "$family" == 'mysql' ]]; then
    server_args+=(--log-bin-trust-function-creators=1)
  fi
  docker run --detach --name "$container" --network "$NETWORK" \
    --env MYSQL_DATABASE=app_test \
    --env MYSQL_USER=app \
    --env "MYSQL_PASSWORD=$DB_PASSWORD" \
    --env "MYSQL_ROOT_PASSWORD=$MYSQL_ROOT_PASSWORD" \
    "$image" "${server_args[@]}" >/dev/null
  containers+=("$container")
  wait_for_mysql "$container" "$client"

  mysql_exec "$container" "$client" \
    "CREATE TABLE items (name varchar(255) NOT NULL);
     CREATE TABLE audit_log (name varchar(255) NOT NULL);
     INSERT INTO items VALUES ('stored');
     CREATE VIEW stored_items AS SELECT name FROM items;
     CREATE TRIGGER stored_item_audit AFTER INSERT ON items FOR EACH ROW INSERT INTO audit_log VALUES (NEW.name);"
  mysql_exec "$container" "$client" \
    "CREATE PROCEDURE stored_item_count() SELECT COUNT(*) FROM items"
  mysql_exec "$container" "$client" \
    "CREATE FUNCTION stored_item_name() RETURNS varchar(255) DETERMINISTIC RETURN (SELECT MIN(name) FROM items)"
  mysql_exec "$container" "$client" \
    "CREATE EVENT stored_event ON SCHEDULE AT CURRENT_TIMESTAMP + INTERVAL 1 DAY DO INSERT INTO items VALUES ('event')"
  if [[ "$family" == 'mariadb' ]]; then
    mysql_exec "$container" "$client" 'CREATE SEQUENCE stored_sequence START WITH 41'
  fi

  docker run --rm --network "$NETWORK" --volume "$repository:/repo" \
    --env APP_NAME=matrix \
    --env DATABASE_ADAPTER=mysql \
    --env "DATABASE_URL=mysql2://app@${container}:3306/app_test" \
    --env "MYSQL_PWD=$DB_PASSWORD" \
    --env RESTIC_REPOSITORY=/repo \
    --env "RESTIC_PASSWORD=$RESTIC_PASSWORD" \
    --env RESTIC_INIT_IF_MISSING=true \
    --env RESTIC_FORGET_AFTER_BACKUP=false \
    "$IMAGE" kamal-backup backup --force 2>&1 | tee "$backup_log"

  mysql_exec "$container" "$client" \
    "UPDATE items SET name = 'changed';
     CREATE TABLE target_only (id integer);
     CREATE VIEW target_only_view AS SELECT id FROM target_only;"
  mysql_exec "$container" "$client" \
    "CREATE PROCEDURE target_only_procedure() SELECT 1"
  mysql_exec "$container" "$client" \
    "CREATE FUNCTION target_only_function() RETURNS integer DETERMINISTIC RETURN 1"
  mysql_exec "$container" "$client" \
    "CREATE EVENT target_only_event ON SCHEDULE AT CURRENT_TIMESTAMP + INTERVAL 1 DAY DO INSERT INTO target_only VALUES (1)"
  if [[ "$family" == 'mariadb' ]]; then
    mysql_exec "$container" "$client" 'CREATE SEQUENCE target_only_sequence START WITH 1'
  fi

  docker run --rm --network "$NETWORK" --volume "$repository:/repo" \
    --env APP_NAME=matrix \
    --env DATABASE_ADAPTER=mysql \
    --env "DATABASE_URL=mysql2://app@${container}:3306/app_test" \
    --env "MYSQL_PWD=$DB_PASSWORD" \
    --env RESTIC_REPOSITORY=/repo \
    --env "RESTIC_PASSWORD=$RESTIC_PASSWORD" \
    "$IMAGE" kamal-backup restore production latest --confirm-production-restore 2>&1 | tee "$restore_log"

  local restored
  restored=$(mysql_exec "$container" "$client" "SELECT name FROM stored_items; CALL stored_item_count()" | tr '\n' ':')
  [[ "$restored" == 'stored:1:' ]] || fail "${family} ${version} did not restore stored data and routines: $restored"
  local restored_function
  restored_function=$(mysql_exec "$container" "$client" 'SELECT stored_item_name()')
  [[ "$restored_function" == 'stored' ]] || fail "${family} ${version} did not restore its stored function"

  local stored_objects
  stored_objects=$(mysql_exec "$container" "$client" \
    "SELECT
       (SELECT COUNT(*) FROM information_schema.TRIGGERS
         WHERE TRIGGER_SCHEMA = DATABASE() AND TRIGGER_NAME = 'stored_item_audit') +
       (SELECT COUNT(*) FROM information_schema.EVENTS
         WHERE EVENT_SCHEMA = DATABASE() AND EVENT_NAME = 'stored_event')")
  [[ "$stored_objects" == '2' ]] || fail "${family} ${version} did not restore its trigger and event"
  mysql_exec "$container" "$client" "INSERT INTO items VALUES ('triggered')" >/dev/null
  local audit_entry
  audit_entry=$(mysql_exec "$container" "$client" "SELECT name FROM audit_log")
  [[ "$audit_entry" == 'triggered' ]] || fail "${family} ${version} restored a non-working trigger"

  local leftovers
  leftovers=$(mysql_exec "$container" "$client" \
    "SELECT
       (SELECT COUNT(*) FROM information_schema.TABLES
         WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME IN ('target_only', 'target_only_view', 'target_only_sequence')) +
       (SELECT COUNT(*) FROM information_schema.ROUTINES
         WHERE ROUTINE_SCHEMA = DATABASE() AND ROUTINE_NAME IN ('target_only_procedure', 'target_only_function')) +
       (SELECT COUNT(*) FROM information_schema.EVENTS
         WHERE EVENT_SCHEMA = DATABASE() AND EVENT_NAME = 'target_only_event')")
  [[ "$leftovers" == '0' ]] || fail "${family} ${version} retained target-only objects: $leftovers"

  if [[ "$family" == 'mariadb' ]]; then
    local stored_sequence
    stored_sequence=$(mysql_exec "$container" "$client" \
      "SELECT COUNT(*) FROM information_schema.TABLES
        WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'stored_sequence' AND TABLE_TYPE = 'SEQUENCE'")
    [[ "$stored_sequence" == '1' ]] || fail "${family} ${version} did not restore the stored sequence"
  fi

  if [[ "$family" == 'mysql' ]]; then
    docker exec --env "MYSQL_PWD=$MYSQL_ROOT_PASSWORD" "$container" "$client" \
      --protocol TCP --host 127.0.0.1 --user root --execute \
      'DROP DATABASE IF EXISTS compatibility_test; CREATE DATABASE compatibility_test' >/dev/null
    docker run --rm --volume "$repository:/repo" \
      --env RESTIC_REPOSITORY=/repo --env "RESTIC_PASSWORD=$RESTIC_PASSWORD" \
      --entrypoint restic "$IMAGE" dump latest /databases/matrix/app/mysql.sql |
      docker exec --interactive --env "MYSQL_PWD=$MYSQL_ROOT_PASSWORD" "$container" "$client" \
        --protocol TCP --host 127.0.0.1 --user root compatibility_test
    local compatible
    compatible=$(docker exec --env "MYSQL_PWD=$MYSQL_ROOT_PASSWORD" "$container" "$client" \
      --protocol TCP --host 127.0.0.1 --user root --batch --skip-column-names \
      --execute 'SELECT name FROM items' compatibility_test)
    [[ "$compatible" == 'stored' ]] || fail "${family} ${version} client could not import the MariaDB-generated dump"
  fi

  assert_secret_redacted "$backup_log" "$DB_PASSWORD"
  assert_secret_redacted "$restore_log" "$DB_PASSWORD"

  docker rm -f "$container" >/dev/null
  containers=("${containers[@]/$container}")
  docker volume rm -f "$repository" >/dev/null
  volumes=("${volumes[@]/$repository}")
}

run_rclone_sqlite() {
  local case_id='rclone-sqlite'
  case_enabled "$case_id" || return 0

  local data="${PREFIX}-rclone-sqlite-data"
  local repository="${PREFIX}-rclone-sqlite-repo"
  local backup_log="$LOG_DIR/${case_id}-backup.log"
  local restore_log="$LOG_DIR/${case_id}-restore.log"

  echo '==> SQLite over the rclone backend'
  create_volume "$data"
  create_volume "$repository"

  docker run --rm --volume "$data:/data" "$IMAGE" sh -c \
    "sqlite3 /data/app.sqlite3 \"PRAGMA journal_mode=WAL;
     CREATE TABLE items (name text NOT NULL);
     INSERT INTO items VALUES ('stored');\"" >/dev/null

  docker run --rm --volume "$data:/data" --volume "$repository:/repository" \
    --env APP_NAME=matrix \
    --env DATABASE_ADAPTER=sqlite \
    --env SQLITE_DATABASE_PATH=/data/app.sqlite3 \
    --env RESTIC_REPOSITORY=rclone:matrix:/repository \
    --env "RESTIC_PASSWORD=$RESTIC_PASSWORD" \
    --env RESTIC_INIT_IF_MISSING=true \
    --env RESTIC_FORGET_AFTER_BACKUP=false \
    --env RCLONE_CONFIG_MATRIX_TYPE=local \
    "$IMAGE" kamal-backup backup --force 2>&1 | tee "$backup_log"

  docker run --rm --volume "$data:/data" "$IMAGE" sqlite3 /data/app.sqlite3 \
    "UPDATE items SET name = 'changed'; CREATE TABLE target_only (id integer);" >/dev/null

  docker run --rm --volume "$data:/data" --volume "$repository:/repository" \
    --env APP_NAME=matrix \
    --env DATABASE_ADAPTER=sqlite \
    --env SQLITE_DATABASE_PATH=/data/app.sqlite3 \
    --env RESTIC_REPOSITORY=rclone:matrix:/repository \
    --env "RESTIC_PASSWORD=$RESTIC_PASSWORD" \
    --env RCLONE_CONFIG_MATRIX_TYPE=local \
    "$IMAGE" kamal-backup restore production latest --confirm-production-restore 2>&1 | tee "$restore_log"

  local restored
  restored=$(docker run --rm --volume "$data:/data" "$IMAGE" sqlite3 /data/app.sqlite3 \
    "SELECT name || ':' || (SELECT COUNT(*) FROM sqlite_master WHERE name = 'target_only') || ':' || (SELECT quick_check FROM pragma_quick_check) FROM items;" )
  [[ "$restored" == 'stored:0:ok' ]] || fail "SQLite over rclone was not restored exactly: $restored"

  docker run --rm --volume "$repository:/repository" \
    --env RCLONE_CONFIG_MATRIX_TYPE=local "$IMAGE" \
    rclone lsf matrix:/repository >/dev/null
  assert_secret_redacted "$backup_log" "$RESTIC_PASSWORD"
  assert_secret_redacted "$restore_log" "$RESTIC_PASSWORD"

  docker volume rm -f "$data" >/dev/null
  volumes=("${volumes[@]/$data}")
  docker volume rm -f "$repository" >/dev/null
  volumes=("${volumes[@]/$repository}")
}

docker image inspect "$IMAGE" >/dev/null 2>&1 || fail "build $IMAGE before running the database matrix"
docker network create "$NETWORK" >/dev/null

for postgres_major in 14 15 16 17 18; do
  run_postgres "$postgres_major"
done

run_mysql mysql 8.0 mysql:8.0 mysql
run_mysql mysql 8.4 mysql:8.4 mysql
run_mysql mariadb 10.11 mariadb:10.11 mariadb
run_mysql mariadb 11.4 mariadb:11.4 mariadb
run_mysql mariadb 11.8 mariadb:11.8 mariadb
run_rclone_sqlite

echo 'Database compatibility matrix passed.'
