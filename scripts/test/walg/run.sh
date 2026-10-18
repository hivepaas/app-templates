#!/bin/bash
# The postgres-managed template's scripts, run as HivePaaS runs them: in the
# template's own images, with the template's WAL-G artifact, against an S3 store
# (SeaweedFS). Each major is a set of throwaway containers, removed afterwards.
#
#   scripts/test/walg/run.sh [17] [18]     both when none is given
#
# Needs docker, python3 with PyYAML, jq, curl and sha256sum. The containers are
# plain ones on a network of their own: nothing is deployed to a swarm.
set -Eeuo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../.." && pwd)
template=$repo/templates/postgres-managed.yaml
s3_image=chrislusf/seaweedfs:4.47
run=walgtest-$$
work=$(mktemp -d)
cache=${XDG_CACHE_HOME:-$HOME/.cache}/hivepaas-app-templates
failures=0

cleanup() {
  docker ps -aq --filter "label=$run" | xargs -r docker rm -fv >/dev/null 2>&1 || true
  docker volume ls -q --filter "label=$run" | xargs -r docker volume rm >/dev/null 2>&1 || true
  docker network rm "$run" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT
trap 'echo "run.sh: line $LINENO failed: $BASH_COMMAND" >&2' ERR

say() { printf '\n== %s\n' "$*"; }
pass() { printf '   ok   %s\n' "$*"; }
fail() {
  printf '   FAIL %s\n' "$*"
  failures=$((failures + 1))
  if [ -s "$work/job.log" ]; then sed 's/^/        | /' "$work/job.log" | tail -n 15; fi
  : > "$work/job.log"
}
check() { # check DESCRIPTION COMMAND...
  local what=$1
  shift
  if "$@"; then pass "$what"; else fail "$what"; fi
}

# The scripts, as the template ships them, and WAL-G as a node downloads it.
prepare_bin() {
  mkdir -p "$work/bin"
  python3 - "$template" "$work/bin" <<'PY'
import os, sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
for entry in doc["app"]["settings"]["configFiles"].values():
    path = os.path.join(sys.argv[2], os.path.basename(entry["swarmRef"]["file"]["name"]))
    open(path, "w").write(entry["content"])
    os.chmod(path, 0o555)
artifact = next(a for a in doc["artifacts"] if a["name"] == "wal-g")
amd64 = artifact["files"]["amd64"]
print(amd64["url"], amd64["sha256"], file=open(os.path.join(sys.argv[2], ".wal-g"), "w"))
PY
  read -r url sha < "$work/bin/.wal-g"
  rm "$work/bin/.wal-g"
  mkdir -p "$cache"
  if [ ! -f "$cache/wal-g-$sha" ]; then
    curl -fsSL -o "$cache/wal-g-$sha.part" "$url"
    mv "$cache/wal-g-$sha.part" "$cache/wal-g-$sha"
  fi
  echo "$sha  $cache/wal-g-$sha" | sha256sum -c --quiet
  cp "$cache/wal-g-$sha" "$work/bin/wal-g"
  chmod 555 "$work/bin/wal-g"
}

start_s3() {
  docker network create --label "$run" "$run" >/dev/null
  cat > "$work/s3.json" <<'JSON'
{"identities": [{"name": "test", "credentials": [{"accessKey": "AKIATEST", "secretKey": "test-secret-key"}],
  "actions": ["Admin", "Read", "Write", "List", "Tagging"]}]}
JSON
  chmod 644 "$work/s3.json"
  docker run -d --label "$run" --name "$run-s3" --network "$run" -v "$work/s3.json:/etc/s3.json:ro" \
    "$s3_image" server -s3 -s3.config=/etc/s3.json -dir=/data >/dev/null
  for _ in $(seq 60); do
    if docker exec "$run-s3" sh -c 'echo "s3.bucket.create -name backups" | weed shell' 2>/dev/null |
      grep -qv error; then
      break
    fi
    sleep 1
  done
}

# secrets DIR KEY: the archive's keys as HivePaaS mounts them, DIR/restore left
# for a source's.
secrets() {
  mkdir -p "$1/restore"
  printf 'AKIATEST' > "$1/WALG_AWS_ACCESS_KEY_ID"
  printf 'test-secret-key' > "$1/WALG_AWS_SECRET_ACCESS_KEY"
  printf '%s' "$2" > "$1/WALG_LIBSODIUM_KEY"
  chmod 444 "$1"/WALG_*
  chmod 755 "$1" "$1/restore"
}

# The environment the engine gives an app archiving to PREFIX.
archive_env() {
  printf '%s\n' -e WALG_COMPRESSION_METHOD=zstd -e WALG_PREVENT_WAL_OVERWRITE=true \
    -e WALG_LIBSODIUM_KEY_TRANSFORM=hex -e HIVEPAAS_WALG_SECRETS_DIR=/run/secrets/walg \
    -e "WALG_S3_PREFIX=s3://backups/$1" -e "AWS_ENDPOINT=http://$run-s3:8333" -e AWS_REGION=us-east-1 \
    -e AWS_S3_FORCE_PATH_STYLE=true -e POSTGRES_USER=app -e POSTGRES_PASSWORD=app-password-1 -e POSTGRES_DB=app
}

server_args=(postgres -c wal_level=replica -c archive_mode=on -c archive_timeout=10s
  -c "archive_command=/opt/hivepaas/bin/walg-run wal-push %p")

# start_db NAME PREFIX SECRETS [docker options...] -- COMMAND...: a managed
# database, its data on a volume of its own, mounted where the template mounts it.
start_db() {
  local name=$1 prefix=$2 secrets=$3
  shift 3
  local -a env opts=()
  while [ "$1" != -- ]; do
    opts+=("$1")
    shift
  done
  shift
  mapfile -t env < <(archive_env "$prefix")
  docker volume create --label "$run" --label "$run-db" "$run-$name" >/dev/null
  # --init as HivePaaS runs it: docker's init is PID 1, and reaps what is detached.
  docker run -d --init --label "$run" --label "$run-db" --name "$run-$name" --network "$run" \
    -v "$run-$name:$data_mount" -v "$work/bin:/opt/hivepaas/bin:ro" -v "$secrets:/run/secrets/walg:ro" \
    "${env[@]}" "${version_env[@]}" "${opts[@]}" "$image" "$@" >/dev/null
}

psql_in() { # psql_in NAME QUERY
  docker exec "$run-$1" psql -h /var/run/postgresql -U app -d app -XAtq -v ON_ERROR_STOP=1 -c "$2"
}

wait_ready() {
  for _ in $(seq 90); do
    if docker exec "$run-$1" pg_isready -h /var/run/postgresql -U app -d app >/dev/null 2>&1 &&
      psql_in "$1" "select 1" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  docker logs "$run-$1" 2>&1 | tail -n 20
  return 1
}

job() { # job NAME SCRIPT ARGS...: a job's run, its log in $work/job.log, its outputs in $work/out
  local name=$1
  shift
  docker exec "$run-$name" rm -f /tmp/hivepaas-output
  docker exec -e HIVEPAAS_OUTPUT=/tmp/hivepaas-output "${job_env[@]}" "$run-$name" "/opt/hivepaas/bin/$1" "${@:2}" \
    > "$work/job.log" 2>&1
  local code=$?
  docker exec "$run-$name" cat /tmp/hivepaas-output > "$work/out" 2>/dev/null || : > "$work/out"
  return $code
}
output() { sed -n "s/^$1=//p" "$work/out" | tail -n 1; }

archived_unasked() { # archived_unasked NAME SECONDS: what was just written is archived in time, no switch asked for
  local segment
  segment=$(psql_in "$1" "select pg_walfile_name(pg_current_wal_insert_lsn())")
  for _ in $(seq "$2"); do
    [ "$(psql_in "$1" "select coalesce(last_archived_wal, '') >= '$segment' from pg_stat_archiver")" = t ] && return 0
    sleep 1
  done
  return 1
}

switch_and_wait() { # switch_and_wait NAME: until the current WAL is archived
  local segment
  segment=$(psql_in "$1" "select pg_walfile_name(pg_switch_wal())")
  # Up to three minutes: an archiver that failed waits a minute before it tries again.
  for _ in $(seq 180); do
    if [[ ! "$(psql_in "$1" "select coalesce(last_archived_wal, '') from pg_stat_archiver")" < "$segment" ]]; then
      return 0
    fi
    sleep 1
  done
  return 1
}

# --- what nothing but the script decides -----------------------------------

test_fetch_exit_codes() {
  say "walg-fetch: 0 and 74 pass, anything else stops recovery"
  rm -rf "$work/fake"
  mkdir -p "$work/fake"
  cp "$work/bin"/walg-* "$work/fake/"
  printf '#!/bin/sh\nexit "$FAKE_EXIT"\n' > "$work/fake/wal-g"
  chmod 555 "$work/fake/wal-g"
  local wanted code
  for pair in 0:0 74:74 1:255 2:255; do
    wanted=${pair#*:}
    code=0
    docker run --rm --label "$run" -e "FAKE_EXIT=${pair%%:*}" -v "$work/fake:/opt/hivepaas/bin:ro" \
      --entrypoint /opt/hivepaas/bin/walg-fetch "$image" 000000010000000000000001 /tmp/x >/dev/null 2>&1 ||
      code=$?
    check "wal-g exiting ${pair%%:*} is $wanted" test "$code" = "$wanted"
  done
}

# --- one database's archive --------------------------------------------------

test_archive() {
  say "archiving, health, base backups, retention and restore points"
  # Through walg-entrypoint, as HivePaaS starts every managed database.
  start_db src "walg/src-$major" "$work/secrets-src" --tmpfs /tiny:size=1m \
    --entrypoint /opt/hivepaas/bin/walg-entrypoint -- "${server_args[@]}"
  if ! wait_ready src; then
    fail "the database starts"
    return 1
  fi
  psql_in src "create table t (id int primary key, at timestamptz not null default clock_timestamp())"
  psql_in src "insert into t (id) select generate_series(1, 10)"
  # Without a checkpoint after the start, PostgreSQL forces no segment switch until
  # its first one, checkpoint_timeout later: archive_timeout would not hold.
  check "a write in its first minute is archived within archive_timeout + 30s, unasked" archived_unasked src 40
  check "its WAL is archived" switch_and_wait src

  job_env=()
  check "walg-health: healthy" job src walg-health
  check "walg-health: prints JSON" jq -e '.state == "ok" and .failedCount == 0' <<<"$(tail -n 1 "$work/job.log")"
  check "walg-health: tells when it last archived" test -n "$(output LAST_ARCHIVED_AT)"

  check "walg-nightly backup: a base backup" job src walg-nightly backup
  first=$(output BACKUP_NAME)
  check "walg-nightly backup: names it" grep -qE '^base_[0-9A-F]{24}$' <<<"$first"
  check "walg-nightly backup: lists what is kept" grep -q "^$first@" <<<"$(output BACKUPS)"
  backup_at_10=$first
  psql_in src "insert into t (id) select generate_series(11, 20)"
  sleep 2
  time_at_20=$(psql_in src "select to_char(clock_timestamp() at time zone 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"')")
  sleep 2
  psql_in src "insert into t (id) select generate_series(21, 30)"
  time_at_30=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  check "walg-mark: makes a point once its WAL is archived" job src walg-mark before-31 60
  point_lsn=$(sed -n 's/^LSN=//p' "$work/job.log")
  check "walg-mark: prints its LSN" grep -qE '^[0-9A-F]+/[0-9A-F]+$' <<<"$point_lsn"
  psql_in src "insert into t (id) select generate_series(31, 40)"
  check "the latest WAL is archived" switch_and_wait src

  job src walg-nightly backup >/dev/null || true
  second=$(output BACKUP_NAME)
  job src walg-nightly backup >/dev/null || true
  check "three base backups are kept" test "$(output BACKUPS | wc -w)" = 3
  check "walg-nightly retain: nothing to delete without a boundary" job src walg-nightly retain
  check "walg-nightly retain: all three still kept" test "$(output BACKUPS | wc -w)" = 3
  job src walg-nightly retain 'base_1; rm -rf /' && code=0 || code=$?
  check "walg-nightly retain: refuses what is not a backup's name" test "$code" = 2

  docker stop "$run-s3" >/dev/null
  psql_in src "insert into t (id) select generate_series(1000, 1100)"
  psql_in src "select pg_switch_wal()" >/dev/null
  check "walg-mark: refused when its WAL is not archived in time" bash -c \
    "docker exec $run-src /opt/hivepaas/bin/walg-mark late 5 >/dev/null 2>&1; test \$? = 75"
  for _ in $(seq 30); do
    if [ "$(psql_in src "select failed_count > 0 from pg_stat_archiver")" = t ]; then break; fi
    sleep 1
  done
  job src walg-health && code=0 || code=$?
  check "walg-health: fails while archiving fails" test "$code" = 1
  check "walg-health: says so" grep -q "Archiving is failing" "$work/job.log"
  docker start "$run-s3" >/dev/null
  check "archiving catches up" switch_and_wait src
  psql_in src "delete from t where id >= 1000"
  check "the latest WAL is archived again" switch_and_wait src
  check "walg-health: healthy again" job src walg-health

  job_env=(-e HIVEPAAS_RESTORE_CHECK_QUERY="select count(*) from t")
  check "walg-restore-test: restores to its own point" job src walg-restore-test
  check "walg-restore-test: says which" grep -q '^hp-test-' <<<"$(output RESTORED_TO)"
  check "walg-restore-test: and how long it took" grep -qE '^[0-9]+$' <<<"$(output DURATION_SECONDS)"
  check "walg-restore-test: leaves no copy behind" bash -c \
    "! docker exec $run-src test -e $data_mount/hivepaas-restore-test"
  job_env=(-e HIVEPAAS_RESTORE_SCRATCH_DIR=/tiny)
  job src walg-restore-test && code=0 || code=$?
  check "walg-restore-test: refuses without the room" test "$code" = 1
  check "walg-restore-test: says so" grep -q "Not enough room" "$work/job.log"
  job_env=()
}

test_verifier() {
  say "the restore test in a verifier"
  start_db verifier "walg/src-$major" "$work/secrets-src" --entrypoint docker-entrypoint.sh \
    -v "$run-verify-$major:/var/lib/hivepaas-verify" -- sleep infinity
  job_env=(-e "HIVEPAAS_RESTORE_SOURCE_HOST=$run-src" -e HIVEPAAS_RESTORE_SCRATCH_DIR=/var/lib/hivepaas-verify)
  check "walg-restore-test: a verifier restores the live database's point" job verifier walg-restore-test
  check "walg-restore-test: says which" grep -q '^hp-test-' <<<"$(output RESTORED_TO)"
  job_env=()
  docker rm -fv "$run-verifier" >/dev/null
}

# --- restores into a new app -------------------------------------------------

# restore NAME KIND COUNT: a new app restored from src to a target of KIND, which
# should hold COUNT rows. The target is given as the engine gives it.
restore() {
  local name=$1 kind=$2 want=$3 code
  local -a target
  case $kind in
    latest) target=(-e HIVEPAAS_RESTORE_TARGET_BACKUP=LATEST) ;;
    time) target=(-e "HIVEPAAS_RESTORE_TARGET_BEFORE=$time_at_20"
      -e "HIVEPAAS_RESTORE_RECOVERY=recovery_target_time=${time_at_20%Z}+00:00") ;;
    point) target=(-e "HIVEPAAS_RESTORE_TARGET_BEFORE=$time_at_30"
      -e "HIVEPAAS_RESTORE_RECOVERY=recovery_target_lsn=$point_lsn recovery_target_inclusive=on") ;;
    backup) target=(-e "HIVEPAAS_RESTORE_TARGET_BACKUP=$backup_at_10"
      -e HIVEPAAS_RESTORE_RECOVERY=recovery_target=immediate) ;;
    replica-backup) target=(-e "HIVEPAAS_RESTORE_TARGET_BACKUP=$replica_backup"
      -e HIVEPAAS_RESTORE_RECOVERY=recovery_target=immediate) ;;
    future) target=(-e "HIVEPAAS_RESTORE_TARGET_BEFORE=$time_at_20"
      -e "HIVEPAAS_RESTORE_RECOVERY=recovery_target_time=$(date -u -d '+1 hour' +%Y-%m-%dT%H:%M:%S+00:00)") ;;
  esac
  rm -rf "$work/secrets-$name"
  secrets "$work/secrets-$name" "$own_key"
  cp "$work/secrets-src"/WALG_* "$work/secrets-$name/restore/"
  start_db "$name" "walg/$name-$major" "$work/secrets-$name" \
    -e HIVEPAAS_RESTORE_SECRETS_DIR=/run/secrets/walg/restore \
    -e "HIVEPAAS_RESTORE_WALG_S3_PREFIX=s3://backups/walg/src-$major" \
    -e "HIVEPAAS_RESTORE_AWS_ENDPOINT=http://$run-s3:8333" -e HIVEPAAS_RESTORE_AWS_REGION=us-east-1 \
    -e HIVEPAAS_RESTORE_AWS_S3_FORCE_PATH_STYLE=true "${target[@]}" \
    --entrypoint /opt/hivepaas/bin/walg-entrypoint -- "${server_args[@]}"
  for _ in $(seq 180); do
    code=0
    docker exec "$run-$name" /opt/hivepaas/bin/walg-entrypoint status > "$work/status.log" 2>&1 || code=$?
    if [ "$code" != 75 ]; then break; fi
    sleep 1
  done
  docker logs "$run-$name" > "$work/job.log" 2>&1
  if [ "$kind" = future ]; then
    check "a target the archive does not reach fails the recovery" test "$code" = 1
    check "with Postgres's own message" grep -q "recovery ended before configured recovery target was reached" \
      "$work/status.log"
    check "and the database idles, so that it can be asked" test "$(docker inspect -f '{{.State.Running}}' \
      "$run-$name")" = true
    return
  fi
  check "$kind: recovered and promoted" test "$code" = 0
  if [ "$code" = 0 ]; then
    : > "$work/job.log"
    check "$kind: holds $want rows" test "$(psql_in "$name" "select count(*) from t" 2>/dev/null)" = "$want"
    psql_in "$name" "insert into t (id) values (5000)"
    check "$kind: archives to its own prefix" switch_and_wait "$name"
  fi
  docker rm -fv "$run-$name" >/dev/null
}

test_restores() {
  say "restore into a new app, to each target"
  restore restored-latest latest 40
  restore restored-time time 20
  restore restored-point point 30
  restore restored-backup backup 10
  restore restored-future future 0
}

test_retention() {
  say "retention, before the backup the engine keeps from"
  check "walg-nightly retain: deletes before $second" job src walg-nightly retain "$second"
  check "walg-nightly retain: keeps $second and after" test "$(output BACKUPS | wc -w)" = 2
  check "walg-nightly retain: the oldest is gone" bash -c "! grep -q '$backup_at_10@' <<<'$(output BACKUPS)'"
  check "walg-nightly retain: and the chain still verifies" grep -q '"status":"OK"' "$work/job.log"
}

test_passthrough() {
  say "walg-entrypoint for a database not being restored"
  rm -rf "$work/secrets-plain"
  secrets "$work/secrets-plain" "$own_key"
  start_db plain "walg/plain-$major" "$work/secrets-plain" --entrypoint /opt/hivepaas/bin/walg-entrypoint \
    -- "${server_args[@]}"
  check "it starts as the image's own does" wait_ready plain
  check "status: up and promoted" docker exec "$run-plain" /opt/hivepaas/bin/walg-entrypoint status
  check "health: healthy" docker exec "$run-plain" /opt/hivepaas/bin/walg-entrypoint health
  docker rm -fv "$run-plain" >/dev/null
}

# replica_follows NAME ID SECONDS: the row ID written on src is on the replica in time.
replica_follows() {
  for _ in $(seq "$3"); do
    [ "$(psql_in "$1" "select count(*) from t where id = $2" 2>/dev/null)" = 1 ] && return 0
    sleep 1
  done
  return 1
}

test_standby() {
  say "a replica, seeded from the archive and streaming from the primary"
  local password=ReplicaPass0123456789 secret
  check "walg-replication: refuses a password that is not one" bash -c \
    "! printf 'short\n' | docker exec -i $run-src /opt/hivepaas/bin/walg-replication >/dev/null 2>&1"
  check "walg-replication: lets replicas in" bash -c \
    "printf '%s\n' $password | docker exec -i $run-src /opt/hivepaas/bin/walg-replication >/dev/null"
  check "walg-replication: runs again as it is" bash -c \
    "printf '%s\n' $password | docker exec -i $run-src /opt/hivepaas/bin/walg-replication >/dev/null"
  check "walg-replication: its pg_hba.conf line is there once" test "$(docker exec "$run-src" sh -c \
    'grep -cx "host replication hivepaas_replica all scram-sha-256" "$(psql -h /var/run/postgresql -U app \
    -d postgres -XAtq -c "show hba_file")"')" = 1
  check "the password is in no process's arguments" bash -c \
    "! docker exec $run-src sh -c 'cat /proc/[0-9]*/cmdline 2>/dev/null' | tr '\0' ' ' | grep -q $password"

  secret=$work/replication-password-$major
  rm -f "$secret"
  printf '%s' "$password" > "$secret"
  chmod 444 "$secret"
  # The primary's archive, keys and server arguments: a standby does not archive.
  start_db replica "walg/src-$major" "$work/secrets-src" -v "$secret:/run/secrets/hivepaas-replication/password:ro" \
    -e "HIVEPAAS_STANDBY_HOST=$run-src" -e HIVEPAAS_STANDBY_NAME=src-r1 \
    -e HIVEPAAS_STANDBY_PASSWORD_FILE=/run/secrets/hivepaas-replication/password \
    --entrypoint /opt/hivepaas/bin/walg-entrypoint -- "${server_args[@]}"
  if ! wait_ready replica; then
    fail "the replica starts"
    return
  fi
  docker logs "$run-replica" > "$work/job.log" 2>&1
  check "it is seeded from the archive" grep -q "Seeding the replica from the archive" "$work/job.log"
  check "it is a standby" test "$(psql_in replica "select pg_is_in_recovery()")" = t
  check "health: healthy" docker exec "$run-replica" /opt/hivepaas/bin/walg-entrypoint health
  : > "$work/job.log"
  psql_in src "insert into t (id) values (7000)"
  check "it follows the primary" replica_follows replica 7000 30
  check "it streams" test "$(psql_in src \
    "select state from pg_stat_replication where application_name = 'src-r1'")" = streaming
  check "its passfile is not on the data volume" bash -c \
    "! docker exec $run-replica grep -rqs $password $data_mount"
  job_env=()
  check "walg-health: healthy" job src walg-health
  check "walg-health: lists the replica, streaming" grep -qE '(^| )src-r1@streaming@[0-9]+@' <<<"$(output REPLICAS)"
  check "it archives nothing" test "$(psql_in replica "select archived_count from pg_stat_archiver")" = 0

  # The nightly backup run on the replica, sparing the primary: a base backup of
  # the standby, in the primary's archive, that a restore starts from.
  local rows
  psql_in src "insert into t (id) values (7002)"
  replica_follows replica 7002 30 || true
  rows=$(psql_in src "select count(*) from t")
  check "walg-nightly backup: on the replica" job replica walg-nightly backup
  replica_backup=$(output BACKUP_NAME)
  check "walg-nightly backup: names it" grep -qE '^base_[0-9A-F]{24}$' <<<"$replica_backup"
  check "walg-nightly backup: lists it among the primary's" grep -q "$replica_backup@" <<<"$(output BACKUPS)"
  check "the replica still archives nothing" test \
    "$(psql_in replica "select archived_count from pg_stat_archiver")" = 0
  psql_in src "insert into t (id) values (7003)"
  # The backup ends in WAL only the primary archives.
  check "the primary archives past it" switch_and_wait src
  restore restored-replica-backup replica-backup "$rows"

  docker restart "$run-replica" >/dev/null
  wait_ready replica || true
  check "restarted, it is still a standby" test "$(psql_in replica "select pg_is_in_recovery()" 2>/dev/null)" = t
  psql_in src "insert into t (id) values (7001)"
  check "and follows the primary again" replica_follows replica 7001 30
  docker rm -fv "$run-replica" >/dev/null

  # A replica it cannot seed idles: it never starts a database of its own.
  start_db replica-unseeded "walg/nothing-here-$major" "$work/secrets-src" \
    -v "$secret:/run/secrets/hivepaas-replication/password:ro" \
    -e "HIVEPAAS_STANDBY_HOST=$run-src" -e HIVEPAAS_STANDBY_PASSWORD_FILE=/run/secrets/hivepaas-replication/password \
    --entrypoint /opt/hivepaas/bin/walg-entrypoint -- "${server_args[@]}"
  for _ in $(seq 30); do
    docker logs "$run-replica-unseeded" 2>&1 | grep -q "idles rather than start empty" && break
    sleep 1
  done
  check "a replica with no base backup to seed from idles" bash -c \
    "docker logs $run-replica-unseeded 2>&1 | grep -q 'idles rather than start empty'"
  check "and starts no database" bash -c \
    "! docker exec $run-replica-unseeded sh -c 'test -s \"\$PGDATA/PG_VERSION\"'"
  docker rm -fv "$run-replica-unseeded" >/dev/null
  psql_in src "delete from t where id >= 7000"
}

test_removed_segment() {
  say "a WAL segment gone from the archive"
  local start segment
  # The first segment after the latest base backup starts: any restore of it
  # replays through it.
  start=$(docker exec "$run-src" /opt/hivepaas/bin/walg-run backup-list --json |
    sed 's/},{/}\n{/g' | sed -n 's/.*"wal_file_name":"\([0-9A-F]\{24\}\)".*/\1/p' | sort | tail -n 1)
  segment=$(docker exec "$run-src" /opt/hivepaas/bin/walg-run st ls wal_005/ 2>/dev/null |
    grep -oE '[0-9A-F]{24}\.[a-z0-9]+' | sort -u | awk -v start="$start" '$0 > start' | sed -n 2p)
  if [ -z "$segment" ]; then
    fail "a segment to remove is listed"
    return
  fi
  docker exec "$run-src" /opt/hivepaas/bin/walg-run st rm "wal_005/$segment" >/dev/null 2>&1
  job_env=()
  job src walg-restore-test && code=0 || code=$?
  check "walg-restore-test: fails on it ($segment)" test "$code" = 1
  check "walg-restore-test: says where it stopped" grep -qi "recovery ended before\|stopped before it reached" \
    "$work/job.log"
}

# --- each major --------------------------------------------------------------

run_major() {
  major=$1
  image=$(python3 -c "import sys,yaml; d=yaml.safe_load(open(sys.argv[1])); \
print(next(v['image'] for v in d['versions'] if v['name']==sys.argv[2]))" "$template" "$major")
  case $major in
    17) data_mount=/var/lib/postgresql/data; version_env=(-e PGDATA=/var/lib/postgresql/data/pgdata) ;;
    *) data_mount=/var/lib/postgresql; version_env=() ;;
  esac
  say "PostgreSQL $major ($image)"
  rm -rf "$work/secrets-src"
  secrets "$work/secrets-src" "$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  own_key=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')
  docker volume create --label "$run" --label "$run-db" "$run-verify-$major" >/dev/null
  test_fetch_exit_codes
  if test_archive; then
    test_verifier
    test_restores
    test_passthrough
    test_standby
    test_retention
    test_removed_segment
  fi
  # What this major made goes, its volumes too: the next one starts from nothing.
  docker ps -aq --filter "label=$run-db" | xargs -r docker rm -fv >/dev/null
  docker volume ls -q --filter "label=$run-db" | xargs -r docker volume rm >/dev/null
}

majors=("$@")
if [ ${#majors[@]} = 0 ]; then majors=(17 18); fi
prepare_bin
start_s3
for major in "${majors[@]}"; do run_major "$major"; done
if [ "$failures" -gt 0 ]; then
  printf '\n%d check(s) failed\n' "$failures"
  exit 1
fi
printf '\nAll checks passed\n'
