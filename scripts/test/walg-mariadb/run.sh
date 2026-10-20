#!/bin/bash
# The mariadb-managed template's scripts, run as HivePaaS runs them: in the
# template's own images, with the template's WAL-G artifact, against an S3 store
# (SeaweedFS). Each version is a set of throwaway containers, removed afterwards.
#
#   scripts/test/walg-mariadb/run.sh [11.8] [11.4]     both when none is given
#   ONLY=replicas scripts/test/walg-mariadb/run.sh 11.8   one of the tests that
#                                                       stand alone
#
# Needs docker, python3 with PyYAML, jq, curl and sha256sum. The containers are
# plain ones on a network of their own: nothing is deployed to a swarm.
set -Eeuo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../.." && pwd)
template=$repo/templates/mariadb-managed.yaml
s3_image=chrislusf/seaweedfs:4.47
run=walgmtest-$$
work=$(mktemp -d)
cache=${XDG_CACHE_HOME:-$HOME/.cache}/hivepaas-app-templates
failures=0
root_password=RootPass0123456789
# The archive loop's period: short, so that the checks on it are.
archive_timeout=10

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
      grep -v error >/dev/null; then
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

# The environment the engine gives an app archiving to PREFIX, and the
# template's own.
archive_env() {
  printf '%s\n' -e WALG_COMPRESSION_METHOD=zstd -e WALG_LIBSODIUM_KEY_TRANSFORM=hex \
    -e HIVEPAAS_WALG_SECRETS_DIR=/run/secrets/walg -e "HIVEPAAS_ARCHIVE_TIMEOUT=$archive_timeout" \
    -e "WALG_S3_PREFIX=s3://backups/$1" -e "AWS_ENDPOINT=http://$run-s3:8333" -e AWS_REGION=us-east-1 \
    -e AWS_S3_FORCE_PATH_STYLE=true -e MARIADB_DATABASE=app -e MARIADB_USER=app \
    -e MARIADB_PASSWORD=app-password-1 -e "MARIADB_ROOT_PASSWORD=$root_password" \
    -e MARIADB_MYSQL_LOCALHOST_USER=1 -e MARIADB_MYSQL_LOCALHOST_GRANTS=ALL
}

server_args=(mariadbd --datadir=/var/lib/mysql/data --log-bin=mariadb-bin --binlog-format=ROW --server-id=1
  --log-slave-updates --binlog-expire-logs-seconds=172800)

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
  # DB_VOLUME is a volume another database had: its name, to make it this one's.
  local volume=${DB_VOLUME:-$run-$name}
  docker volume create --label "$run" --label "$run-db" "$volume" >/dev/null
  # --init as HivePaaS runs it: docker's init is PID 1, and reaps what is detached.
  docker run -d --init --label "$run" --label "$run-db" --name "$run-$name" --network "$run" \
    -v "$volume:/var/lib/mysql" -v "$work/bin:/opt/hivepaas/bin:ro" -v "$secrets:/run/secrets/walg:ro" \
    "${env[@]}" "${opts[@]}" "$image" "$@" >/dev/null
}

root_sql() { # root_sql NAME SQL: as root, its password in an option file in the container
  docker exec "$run-$1" sh -c "umask 077; printf '[client]\nuser=root\npassword=\"%s\"\n' \"\$MARIADB_ROOT_PASSWORD\" \
    > /dev/shm/root.cnf; mariadb --defaults-extra-file=/dev/shm/root.cnf -e \"$2\"; rc=\$?; rm -f /dev/shm/root.cnf; exit \$rc"
}

sql_in() { # sql_in NAME QUERY: as the scripts reach the server, on the app's database
  docker exec -u mysql "$run-$1" mariadb -umysql -N -B app -e "$2"
}

# wait_ready NAME: the server is up for good, listening on its port - not the
# image's temporary one, nor a restore's, which listen on none.
wait_ready() {
  for _ in $(seq 120); do
    if docker logs "$run-$1" 2>&1 | grep -E "ready for connections|port: 3306" | grep "port: 3306" >/dev/null &&
      sql_in "$1" "select 1" >/dev/null 2>&1; then
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
json_ok() { jq -e "$1" >/dev/null <<<"$2"; } # json_ok FILTER JSON

archived_logs() { # archived_logs NAME: the binary logs in NAME's archive
  docker exec "$run-$1" /opt/hivepaas/bin/walg-run binlog-list --json 2>/dev/null |
    jq -r '.[].name' 2>/dev/null | sort || true
}
active_log() { sql_in "$1" "show master status" | cut -f1; }
server_logs() { sql_in "$1" "show binary logs" | cut -f1; }

# archived_within NAME FILE SECONDS: the binary log FILE is archived in time.
archived_within() {
  for _ in $(seq "$3"); do
    if archived_logs "$1" | grep -x "$2" >/dev/null; then return 0; fi
    sleep 1
  done
  return 1
}

# caught_up NAME SECONDS: what was just written is archived in time, no flush
# asked for: the log it is in is closed and pushed by the loop.
caught_up() {
  archived_within "$1" "$(active_log "$1")" "${2:-60}"
}

# purged_only_archived NAME: every log the server no longer has is archived.
purged_only_archived() {
  local oldest number archived
  oldest=$(server_logs "$1" | head -n 1)
  archived=$(archived_logs "$1")
  for number in $(seq 1 $((10#${oldest##*.} - 1))); do
    if ! grep -x "${oldest%.*}.$(printf '%06d' "$number")" <<<"$archived" >/dev/null; then
      echo "${oldest%.*}.$(printf '%06d' "$number") is neither on the server nor archived" > "$work/job.log"
      return 1
    fi
  done
}

# --- one database's archive --------------------------------------------------

test_archive() {
  say "archiving, health, base backups and restore points"
  # Through walg-entrypoint, as HivePaaS starts every managed database.
  start_db src "walg/src-$version" "$work/secrets-src" --tmpfs /tiny:size=65536 \
    --entrypoint /opt/hivepaas/bin/walg-entrypoint -- "${server_args[@]}"
  if ! wait_ready src; then
    fail "the database starts"
    return 1
  fi
  check "it runs the archive loop" bash -c "docker exec $run-src sh -c 'cat /proc/[0-9]*/cmdline' 2>/dev/null |
    tr '\0' ' ' | grep 'walg-archive loop' >/dev/null"
  check "its scripts' account may grant, from its initialization" bash -c \
    "docker exec -u mysql $run-src mariadb -umysql -N -e 'show grants' | grep 'WITH GRANT OPTION' >/dev/null"
  # A database made before that: the base backups and restores below need the
  # grant given back, for the GRANT in the logs.
  root_sql src "REVOKE GRANT OPTION ON *.* FROM 'mysql'@'localhost'"
  sql_in src "create table t (id int primary key, at timestamp(6) not null default current_timestamp(6))"
  sql_in src "insert into t (id) select seq from seq_1_to_10"
  check "a write is archived within the archive timeout + 15s, unasked" caught_up src $((archive_timeout + 15))
  check "the server keeps only logs that are archived" purged_only_archived src
  local before after
  before=$(active_log src)
  sleep $((archive_timeout * 5 / 2))
  after=$(active_log src)
  check "an idle database adds no binary log ($before, then $after)" test "$before" = "$after"

  job_env=()
  check "walg-health: healthy" job src walg-health
  check "walg-health: prints JSON" json_ok '.state == "ok" and .failedCount == 0' "$(tail -n 1 "$work/job.log")"
  check "walg-health: tells when it last archived" test -n "$(output LAST_ARCHIVED_AT)"
  check "walg-health: and what waits" grep -qE '^[0-9]+$' <<<"$(output PENDING_BYTES)"

  check "walg-nightly backup: a base backup" job src walg-nightly backup
  first=$(output BACKUP_NAME)
  check "walg-nightly backup: warns of nothing but xtrabackup_checkpoints" bash -c \
    "! grep -E '^(WARNING|ERROR)' $work/job.log | grep -v xtrabackup_checkpoints"
  check "walg-nightly backup: names it" grep -qE '^stream_[0-9]{8}T[0-9]{6}Z$' <<<"$first"
  check "walg-nightly backup: lists what is kept" grep -q "^$first@" <<<"$(output BACKUPS)"
  backup_at_10=$first
  sql_in src "insert into t (id) select seq from seq_11_to_20"
  root_sql src "CREATE USER 'reader'@'%' IDENTIFIED BY 'reader-password-1'; GRANT SELECT ON app.* TO 'reader'@'%'"
  sleep 2
  time_at_20=$(sql_in src "select date_format(utc_timestamp(), '%Y-%m-%dT%H:%i:%sZ')")
  sleep 2
  sql_in src "insert into t (id) select seq from seq_21_to_30"
  check "walg-mark: makes a point once its log is archived" job src walg-mark before-31 60
  point_position=$(sed -n 's/^POSITION=//p' "$work/job.log")
  point_gtid=$(sed -n 's/^GTID=//p' "$work/job.log")
  time_at_30=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  check "walg-mark: prints its position" grep -qE '^mariadb-bin\.[0-9]{6}:[0-9]+$' <<<"$point_position"
  check "walg-mark: and its GTID" grep -qE '^GTID=[0-9]+-[0-9]+-[0-9]+' "$work/job.log"
  check "walg-mark: refuses what is not a name" bash -c \
    "docker exec $run-src /opt/hivepaas/bin/walg-mark 'a;b' 5 >/dev/null 2>&1; test \$? = 2"
  sql_in src "insert into t (id) select seq from seq_31_to_40"
  check "the latest log is archived" caught_up src

  job src walg-nightly backup >/dev/null || true
  second=$(output BACKUP_NAME)

  docker stop "$run-s3" >/dev/null
  sql_in src "insert into t (id) select seq from seq_1000_to_1100"
  local unarchived
  unarchived=$(active_log src)
  check "walg-mark: refused when its log is not archived in time" bash -c \
    "docker exec $run-src /opt/hivepaas/bin/walg-mark late 5 >/dev/null 2>&1; test \$? = 75"
  for _ in $(seq 60); do
    if ! job src walg-health; then break; fi
    sleep 1
  done
  job src walg-health && code=0 || code=$?
  check "walg-health: fails while archiving fails" test "$code" = 1
  check "walg-health: says so" grep -q "Archiving is failing: the last pass failed (binlog-push failed" "$work/job.log"
  check "walg-health: counts the failures" test "$(output FAILED_COUNT)" -gt 0
  docker start "$run-s3" >/dev/null
  # The mark closed the log the writes are in: the one open now has none, and
  # stays open.
  check "archiving catches up" archived_within src "$unarchived" 120
  sql_in src "delete from t where id >= 1000"
  check "the latest log is archived again" caught_up src
  check "walg-health: healthy again" job src walg-health
  check "the server still keeps only logs that are archived" purged_only_archived src

  # A base backup while the logs rotate under it: a restore of it replays from
  # the offset it recorded, in the log it recorded.
  sql_in src "create table r (id int auto_increment primary key)"
  (for _ in $(seq 60); do sql_in src "insert into r values (); flush binary logs" >/dev/null 2>&1 || true; done) &
  local writer=$!
  job src walg-nightly backup >/dev/null || true
  third=$(output BACKUP_NAME)
  wait "$writer"
  check "a base backup taken while the logs rotate" test -n "$third"
  sql_in src "insert into r values ()"
  check "and the logs after it archived" caught_up src
  rotated_rows=$(sql_in src "select count(*) from r")

  check "three base backups are kept" test "$(output BACKUPS | wc -w)" = 3
  check "walg-nightly retain: nothing to delete without a boundary" job src walg-nightly retain
  check "walg-nightly retain: all three still kept" test "$(output BACKUPS | wc -w)" = 3
  check "walg-nightly retain: the binary logs follow one another" grep -q "follow one another" "$work/job.log"
  job src walg-nightly retain 'stream_1; rm -rf /' && code=0 || code=$?
  check "walg-nightly retain: refuses what is not a backup's name" test "$code" = 2
}

test_restore_test() {
  say "the restore test"
  job_env=(-e HIVEPAAS_RESTORE_CHECK_QUERY="select count(*) from t")
  check "walg-restore-test: restores to its own point" job src walg-restore-test
  check "walg-restore-test: says which" grep -qE '^mariadb-bin\.[0-9]{6}:[0-9]+$' <<<"$(output RESTORED_TO)"
  check "walg-restore-test: and how long it took" grep -qE '^[0-9]+$' <<<"$(output DURATION_SECONDS)"
  check "walg-restore-test: ran the check" grep -qx 40 "$work/job.log"
  check "walg-restore-test: leaves no copy behind" bash -c \
    "! docker exec $run-src test -e /var/lib/mysql/hivepaas-restore-test"
  check "walg-restore-test: and no server" bash -c \
    "! docker exec $run-src test -S /run/mysqld/hivepaas-restore-test.sock"
  job_env=(-e HIVEPAAS_RESTORE_CHECK_QUERY="select * from no_such_table")
  job src walg-restore-test && code=0 || code=$?
  check "walg-restore-test: fails on a check that fails" test "$code" != 0
  check "walg-restore-test: saying why" grep -q "no_such_table" "$work/job.log"
  job_env=(-e HIVEPAAS_RESTORE_SCRATCH_DIR=/tiny)
  job src walg-restore-test && code=0 || code=$?
  check "walg-restore-test: refuses without the room" test "$code" = 1
  check "walg-restore-test: says so" grep -q "Not enough room" "$work/job.log"
  job_env=()

  say "the restore test in a verifier"
  start_db verifier "walg/src-$version" "$work/secrets-src" --entrypoint docker-entrypoint.sh \
    -v "$run-verify-$version:/var/lib/hivepaas-verify" -- sleep infinity
  job_env=(-e "HIVEPAAS_RESTORE_SOURCE_HOST=$run-src" -e HIVEPAAS_RESTORE_SCRATCH_DIR=/var/lib/hivepaas-verify
    -e HIVEPAAS_RESTORE_CHECK_QUERY="select count(*) from t")
  check "walg-restore-test: a verifier restores the live database's point" job verifier walg-restore-test
  check "walg-restore-test: says which" grep -qE '^mariadb-bin\.[0-9]{6}:[0-9]+$' <<<"$(output RESTORED_TO)"
  check "walg-restore-test: the root password is in no file left behind" bash -c \
    "! docker exec $run-verifier grep -rqs $root_password /var/lib/hivepaas-verify /tmp"
  job_env=()
  docker rm -fv "$run-verifier" >/dev/null
}

# --- restores into a new app -------------------------------------------------

# restore NAME KIND: a new app restored from src to a target of KIND. The target
# is given as the engine gives it.
# restore NAME KIND: a new app restored from src - or RESTORE_SOURCE - to a
# target of KIND, as the engine gives it.
restore() {
  local name=$1 kind=$2 code source=${RESTORE_SOURCE:-src}
  local -a target
  case $kind in
    latest | gap) target=(-e HIVEPAAS_RESTORE_TARGET_BACKUP=LATEST) ;;
    point-gtid) target=(-e "HIVEPAAS_RESTORE_TARGET_BEFORE=$time_at_30" -e "HIVEPAAS_RESTORE_STOP_GTID=$point_gtid") ;;
    time) target=(-e "HIVEPAAS_RESTORE_TARGET_BEFORE=$time_at_20" -e "HIVEPAAS_RESTORE_STOP_TIME=$time_at_20") ;;
    point) target=(-e "HIVEPAAS_RESTORE_TARGET_BEFORE=$time_at_30"
      -e "HIVEPAAS_RESTORE_STOP_POSITION=$point_position") ;;
    backup) target=(-e "HIVEPAAS_RESTORE_TARGET_BACKUP=$backup_at_10" -e HIVEPAAS_RESTORE_REPLAY=none) ;;
    oldest) target=(-e "HIVEPAAS_RESTORE_TARGET_BACKUP=$second") ;;
    missing) target=(-e "HIVEPAAS_RESTORE_TARGET_BEFORE=$time_at_30"
      -e "HIVEPAAS_RESTORE_STOP_POSITION=mariadb-bin.999999:4") ;;
  esac
  rm -rf "$work/secrets-$name"
  secrets "$work/secrets-$name" "$own_key"
  cp "$work/secrets-src"/WALG_* "$work/secrets-$name/restore/"
  start_db "$name" "walg/$name-$version" "$work/secrets-$name" \
    -e HIVEPAAS_RESTORE_SECRETS_DIR=/run/secrets/walg/restore \
    -e "HIVEPAAS_RESTORE_WALG_S3_PREFIX=s3://backups/walg/$source-$version" \
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
  if [ "$kind" = gap ]; then
    check "a log gone from the middle fails the restore" test "$code" = 1
    check "naming where the logs break" grep -q "binary logs break at" "$work/status.log"
    docker rm -fv "$run-$name" >/dev/null
    return
  fi
  if [ "$kind" = missing ]; then
    check "a point the archive does not have fails the restore" test "$code" = 1
    check "saying so" grep -q "The archive has no mariadb-bin.999999" "$work/status.log"
    check "having replayed nothing" bash -c \
      "! docker exec $run-$name grep '^Replaying' /var/lib/mysql/hivepaas-restore.log"
    check "health: healthy, so that it is not restarted" docker exec "$run-$name" \
      /opt/hivepaas/bin/walg-entrypoint health
    check "and the database idles, so that it can be asked" test "$(docker inspect -f '{{.State.Running}}' \
      "$run-$name")" = true
    docker restart "$run-$name" >/dev/null
    sleep 3
    check "restarted, it still says why" bash -c \
      "docker exec $run-$name /opt/hivepaas/bin/walg-entrypoint status >/dev/null 2>&1; test \$? = 1"
    docker rm -fv "$run-$name" >/dev/null
    return
  fi
  check "$kind: restored and serving" test "$code" = 0
  if [ "$code" = 0 ] && wait_ready "$name"; then
    : > "$work/job.log"
    restored_rows=$(sql_in "$name" "select count(*) from t" 2>/dev/null)
    sql_in "$name" "insert into t (id) values (5000)"
    if ! caught_up "$name"; then
      {
        docker logs "$run-$name" 2>&1 | grep -E "walg-archive|walg-entrypoint" | tail -n 10
        docker exec "$run-$name" sh -c 'cat /var/lib/mysql/hivepaas-archive.state; ls -la /var/lib/mysql'
        sql_in "$name" "show binary logs"
      } > "$work/job.log" 2>&1
      fail "$kind: archives to its own prefix"
    else
      pass "$kind: archives to its own prefix"
    fi
    restored_r=$(sql_in "$name" "select count(*) from r" 2>/dev/null || echo none)
    if [ "$kind" != backup ] && [ "$source" = src ]; then
      check "$kind: the GRANT in the logs replayed" bash -c \
        "docker exec -u mysql $run-$name mariadb -umysql -N -e \"show grants for 'reader'@'%'\" | grep 'SELECT ON' >/dev/null"
    fi
  else
    restored_rows=none restored_r=none
  fi
  docker rm -fv "$run-$name" >/dev/null
}

test_restores() {
  say "restore into a new app, to each target"
  restore restored-latest latest
  check "latest: holds the 40 rows" test "$restored_rows" = 40
  check "latest: and the $rotated_rows written while its base backup was taken" test "$restored_r" = "$rotated_rows"
  restore restored-time time
  check "time: holds the 20 rows written before it" test "$restored_rows" = 20
  restore restored-point point
  check "point: holds the 30 rows written before it" test "$restored_rows" = 30
  restore restored-backup backup
  check "backup: holds the 10 rows of the base backup" test "$restored_rows" = 10
  restore restored-missing missing
  restore restored-point-gtid point-gtid
  check "point by GTID: holds the 30 rows written before it" test "$restored_rows" = 30

  # The state of a restore before, on the volume, is not this one's.
  restore restored-reused time
  DB_VOLUME=$run-restored-reused restore restored-reused-again latest
  check "latest, into a volume restored to a time before: holds the 40 rows" test "$restored_rows" = 40
}

test_passthrough() {
  say "walg-entrypoint for a database not being restored"
  rm -rf "$work/secrets-plain"
  secrets "$work/secrets-plain" "$own_key"
  start_db plain "walg/plain-$version" "$work/secrets-plain" --entrypoint /opt/hivepaas/bin/walg-entrypoint \
    -- "${server_args[@]}"
  check "it starts as the image's own does" wait_ready plain
  check "status: up and serving" docker exec "$run-plain" /opt/hivepaas/bin/walg-entrypoint status
  check "health: healthy" docker exec "$run-plain" /opt/hivepaas/bin/walg-entrypoint health
  check "its data directory is a directory of the volume" docker exec "$run-plain" test -d /var/lib/mysql/data/mysql
  check "its state is beside it, the loop's" bash -c \
    "test \"\$(docker exec $run-plain stat -c %U /var/lib/mysql/hivepaas-archive.state)\" = mysql"
  docker restart "$run-plain" >/dev/null
  check "restarted, it starts again" wait_ready plain

  # A second container on its volume, as a rollout's next task can be before the
  # last one has stopped: one server at a time.
  local code
  check "a process of its own holds the data lock" bash -c "docker exec $run-plain sh -c \
    'ls -l /proc/\$(pgrep -f ^hivepaas-data-lock)/fd' | grep hivepaas-server.lock >/dev/null"
  twin twin-late -e HIVEPAAS_DATA_LOCK_TIMEOUT=3
  code=$(timeout 60 docker wait "$run-twin-late" 2>/dev/null || echo running)
  docker logs "$run-twin-late" > "$work/job.log" 2>&1
  check "a second server beside it gives up after its wait" test "$code" = 1
  check "saying so" grep -q "another server still runs on this volume" "$work/job.log"
  : > "$work/job.log"
  twin twin
  sleep 5
  docker logs "$run-twin" > "$work/job.log" 2>&1
  check "a second server waits for the first" grep -q "waiting for it to stop" "$work/job.log"
  : > "$work/job.log"
  check "and starts none meanwhile" bash -c "! docker exec $run-twin pidof mariadbd >/dev/null"
  docker stop "$run-plain" >/dev/null
  check "it starts once the first has stopped" wait_ready twin
  docker rm -fv "$run-twin" "$run-twin-late" "$run-plain" >/dev/null
}

# twin NAME [docker options...]: a second database on plain's volume.
twin() {
  local name=$1
  shift
  local -a env
  mapfile -t env < <(archive_env "walg/plain-$version")
  docker run -d --init --label "$run" --label "$run-db" --name "$run-$name" --network "$run" \
    -v "$run-plain:/var/lib/mysql" -v "$work/bin:/opt/hivepaas/bin:ro" -v "$work/secrets-plain:/run/secrets/walg:ro" \
    "${env[@]}" "$@" --entrypoint /opt/hivepaas/bin/walg-entrypoint "$image" "${server_args[@]}" >/dev/null
}

test_fresh_start() {
  say "an empty data directory is initialized over an empty archive only"
  local before code
  before=$(archived_logs src | wc -l)
  # src's archive, as a database whose volume is lost - or a shared one that is not - sees it.
  start_db lost "walg/src-$version" "$work/secrets-src" --entrypoint /opt/hivepaas/bin/walg-entrypoint -- \
    "${server_args[@]}"
  for _ in $(seq 60); do
    docker logs "$run-lost" 2>&1 | grep "is not initialized afresh" >/dev/null && break
    sleep 1
  done
  docker logs "$run-lost" > "$work/job.log" 2>&1
  check "over an archive with history, it is not initialized" grep -q "is not initialized afresh" "$work/job.log"
  check "it names the archive" grep -q "walg/src-$version holds this database's history" "$work/job.log"
  : > "$work/job.log"
  check "and initializes nothing" bash -c "! docker exec $run-lost test -e /var/lib/mysql/data/mysql"
  check "health: healthy while it idles" docker exec "$run-lost" /opt/hivepaas/bin/walg-entrypoint health
  job_env=()
  if job lost walg-health; then
    fail "walg-health: fails"
  else
    pass "walg-health: fails"
  fi
  check "walg-health: says why" grep -q "The database is not started: The data directory is empty" "$work/job.log"
  : > "$work/job.log"
  check "the archive is as it was" test "$(archived_logs src | wc -l)" = "$before"
  docker rm -fv "$run-lost" >/dev/null

  # An archive it cannot read: the start fails, and nothing is initialized.
  start_db unread "walg/src-$version" "$work/secrets-src" -e "AWS_ENDPOINT=http://$run-nowhere:8333" \
    -e HIVEPAAS_ARCHIVE_CHECK_TIMEOUT=5 --entrypoint /opt/hivepaas/bin/walg-entrypoint -- "${server_args[@]}"
  code=$(timeout 60 docker wait "$run-unread" 2>/dev/null || echo running)
  docker logs "$run-unread" > "$work/job.log" 2>&1
  check "over an archive it cannot read, the start fails" test "$code" = 1
  check "saying so" grep -q "the archive could not be read" "$work/job.log"
  : > "$work/job.log"
  check "and initializes nothing" bash -c "docker run --rm --entrypoint sh -v $run-unread:/v $image -c \
    'test ! -e /v/data/mysql'"
  docker rm -fv "$run-unread" >/dev/null

  # An archive that holds nothing: a new database, initialized as any is.
  start_db fresh "walg/fresh-$version" "$work/secrets-src" --entrypoint /opt/hivepaas/bin/walg-entrypoint -- \
    "${server_args[@]}"
  check "over an empty archive, a new database starts" wait_ready fresh
  check "with no refusal beside its data" bash -c "! docker exec $run-fresh test -e /var/lib/mysql/hivepaas-refused"
  docker rm -fv "$run-fresh" >/dev/null
}

# no_secret_in FILE: none of the keys, nor the root password, is in FILE.
no_secret_in() {
  local secret
  for secret in test-secret-key "$(cat "$work/secrets-src/WALG_LIBSODIUM_KEY")" "$root_password"; do
    if grep -F "$secret" "$1" >/dev/null; then
      echo "a secret is in a process's arguments" > "$work/job.log"
      return 1
    fi
  done
}

# sample NAME FILE: every process's arguments in NAME, over and over, into FILE,
# until $work/stop-sampling exists.
sample() {
  rm -f "$work/stop-sampling"
  while [ ! -e "$work/stop-sampling" ]; do
    docker exec "$run-$1" sh -c 'for f in /proc/[0-9]*/cmdline; do tr "\0" " " < "$f"; echo; done' 2>/dev/null || true
  done > "$2"
}

test_secrets() {
  say "no secret on any process's arguments"
  sample src "$work/cmdline-backup" &
  local sampler=$!
  job src walg-nightly backup >/dev/null || true
  touch "$work/stop-sampling"
  wait "$sampler"
  check "the sample saw the backup" grep -q "mariadb-backup --backup" "$work/cmdline-backup"
  check "during a backup" no_secret_in "$work/cmdline-backup"

  rm -rf "$work/secrets-secret"
  secrets "$work/secrets-secret" "$own_key"
  cp "$work/secrets-src"/WALG_* "$work/secrets-secret/restore/"
  start_db restored-secret "walg/restored-secret-$version" "$work/secrets-secret" \
    -e HIVEPAAS_RESTORE_SECRETS_DIR=/run/secrets/walg/restore \
    -e "HIVEPAAS_RESTORE_WALG_S3_PREFIX=s3://backups/walg/src-$version" \
    -e "HIVEPAAS_RESTORE_AWS_ENDPOINT=http://$run-s3:8333" -e HIVEPAAS_RESTORE_AWS_REGION=us-east-1 \
    -e HIVEPAAS_RESTORE_AWS_S3_FORCE_PATH_STYLE=true -e HIVEPAAS_RESTORE_TARGET_BACKUP=LATEST \
    --entrypoint /opt/hivepaas/bin/walg-entrypoint -- "${server_args[@]}"
  sample restored-secret "$work/cmdline-restore" &
  sampler=$!
  wait_ready restored-secret || true
  touch "$work/stop-sampling"
  wait "$sampler"
  check "the sample saw the restore" grep -qE "wal-g (backup-fetch|binlog-fetch)|mariadb-binlog" \
    "$work/cmdline-restore"
  check "during a restore and its replay" no_secret_in "$work/cmdline-restore"
  docker rm -fv "$run-restored-secret" >/dev/null
}

test_retention() {
  say "retention, before the backup the engine keeps from"
  local start oldest
  start=$(docker exec "$run-src" /opt/hivepaas/bin/walg-run backup-list --detail --json |
    jq -r --arg b "$second" '.[] | select(.backup_name == $b) | .binlog_start')
  check "walg-nightly retain: deletes before $second" job src walg-nightly retain "$second"
  check "walg-nightly retain: keeps $second and after" test "$(output BACKUPS | wc -w)" = 3
  check "walg-nightly retain: the oldest is gone" bash -c "! grep '$backup_at_10@' <<<'$(output BACKUPS)'"
  check "walg-nightly retain: and the chain still follows" grep -q "follow one another" "$work/job.log"
  oldest=$(archived_logs src | head -n 1)
  # binlog_start is the last log archived when the backup started: it goes too
  # when it was archived a second or more before.
  check "the binary logs before $start are gone ($oldest)" bash -c "[[ ! $oldest < $start ]]"
  # What the oldest backup kept needs is all there: it restores to the latest,
  # every write before this one archived already.
  latest_rows=$(sql_in src "select count(*) from t")
  latest_r=$(sql_in src "select count(*) from r")
  restore restored-oldest oldest
  check "oldest kept: restores to the latest ($latest_rows rows)" test "$restored_rows" = "$latest_rows"
  check "oldest kept: and the $latest_r of r" test "$restored_r" = "$latest_r"

  # A log gone from the middle of the chain: the nightly check says so.
  local gone code
  gone=$(archived_logs src | tail -n 3 | head -n 1)
  docker exec "$run-src" /opt/hivepaas/bin/walg-run st rm "binlog_005/$gone.zst" >/dev/null 2>&1
  job src walg-nightly retain && code=0 || code=$?
  check "walg-nightly retain: fails on a log gone from the chain ($gone)" test "$code" = 1
  check "walg-nightly retain: naming it" grep -q "the archive lacks $gone" "$work/job.log"
}

# A server whose binary logs change their name - as a promoted member's are its
# own - its archive holding both: restores replay across them, by GTID, and the
# chain check follows each.
test_basenames() {
  say "binary logs of two names in one archive"
  local volume=$run-renamed gone gtid code
  start_db renamed "walg/renamed-$version" "$work/secrets-src" --entrypoint /opt/hivepaas/bin/walg-entrypoint \
    -- "${server_args[@]}"
  wait_ready renamed || { fail "it starts"; return; }
  sql_in renamed "create table t (id int primary key)"
  sql_in renamed "insert into t select seq from seq_1_to_10"
  job renamed walg-nightly backup >/dev/null || true
  sql_in renamed "insert into t select seq from seq_11_to_20"
  check "its logs are archived" caught_up renamed
  gtid=$(sql_in renamed "select @@gtid_binlog_pos")
  # Stopped, the server keeps its GTID state beside its logs, by their name: the
  # state given to the new name goes on from it, as a promoted member's does.
  docker stop -t 60 "$run-renamed" >/dev/null
  docker rm "$run-renamed" >/dev/null
  docker run --rm -v "$volume:/var/lib/mysql" --entrypoint cp "$image" -p /var/lib/mysql/data/mariadb-bin.state \
    /var/lib/mysql/data/mariadb-bin-b.state
  DB_VOLUME=$volume start_db renamed-b "walg/renamed-$version" "$work/secrets-src" \
    --entrypoint /opt/hivepaas/bin/walg-entrypoint -- "${server_args[@]/--log-bin=mariadb-bin/--log-bin=mariadb-bin-b}"
  wait_ready renamed-b || { fail "it starts again"; return; }
  check "it writes logs of another name" grep -q '^mariadb-bin-b' <<<"$(active_log renamed-b)"
  check "and goes on from the GTID state of the first ($gtid)" test "$(sql_in renamed-b "select @@gtid_binlog_pos")" = "$gtid"
  local n
  for n in 21 31 41; do
    sql_in renamed-b "insert into t select seq from seq_${n}_to_$((n + 9))"
    check "rows $n to $((n + 9)) archived, in $(active_log renamed-b)" caught_up renamed-b
  done
  job_env=()
  check "walg-nightly retain: the chain follows, each name's" job renamed-b walg-nightly retain
  check "naming both" grep -q "mariadb-bin mariadb-bin-b\|mariadb-bin-b mariadb-bin" "$work/job.log"
  RESTORE_SOURCE=renamed restore restored-renamed latest
  check "latest, across both names: the 50 rows" test "$restored_rows" = 50

  gone=$(archived_logs renamed-b | grep '^mariadb-bin-b' | sed -n 2p)
  docker exec "$run-renamed-b" /opt/hivepaas/bin/walg-run st rm "binlog_005/$gone.zst" >/dev/null 2>&1
  job renamed-b walg-nightly retain && code=0 || code=$?
  check "walg-nightly retain: fails on $gone gone" test "$code" = 1
  check "naming it" grep -q "lacks $gone" "$work/job.log"
  RESTORE_SOURCE=renamed restore restored-gap gap
  docker rm -fv "$run-renamed-b" >/dev/null
}

# --- replicas -----------------------------------------------------------------

# start_replica NAME ID PREFIX: a replica of prim, as the engine gives one:
# the primary's settings, with the standby's variables, its server id and log
# name, and the replication password as a file.
start_replica() {
  local name=$1 id=$2 prefix=${3:-walg/prim-$version}
  start_db "$name" "$prefix" "$work/secrets-src" -e "HIVEPAAS_STANDBY_HOST=$run-${WRITER:-prim}" \
    -e "HIVEPAAS_STANDBY_NAME=$run-$name" -e HIVEPAAS_STANDBY_PASSWORD_FILE=/run/hivepaas-replication/password \
    -e "HIVEPAAS_SERVER_ID=$id" -e "HIVEPAAS_LOG_BIN=mariadb-bin-$name" -v "$work/repl:/run/hivepaas-replication:ro" \
    --entrypoint /opt/hivepaas/bin/walg-entrypoint -- "${server_args[@]}"
}

# writing: rows written to prim's t, two a second, until stop_writing.
writing() {
  touch "$work/writing"
  (
    n=100000
    while [ -f "$work/writing" ]; do
      n=$((n + 1))
      sql_in prim "insert into t (id) values ($n)" >/dev/null 2>&1 || true
      sleep 0.5
    done
  ) &
  writer_pid=$!
}
stop_writing() {
  rm -f "$work/writing"
  wait "$writer_pid" 2>/dev/null || true
}

# same_rows NAME SECONDS: the replica holds the writer's rows of t, in time:
# prim's, or WRITER's.
same_rows() {
  local want
  want=$(sql_in "${WRITER:-prim}" "select count(*), max(id) from t")
  for _ in $(seq "${2:-60}"); do
    if [ "$(sql_in "$1" "select count(*), max(id) from t" 2>/dev/null)" = "$want" ]; then return 0; fi
    sleep 1
  done
  echo "$1: $(sql_in "$1" "select count(*), max(id) from t" 2>&1), ${WRITER:-prim}: $want" > "$work/job.log"
  docker logs "$run-$1" 2>&1 | grep -E "walg-|ERROR" | tail -n 10 >> "$work/job.log"
  return 1
}

test_replicas() {
  say "replicas: seeded from the archive under writes, streaming, caught up, backed up on"
  local password code backup
  password=$(head -c 30 /dev/urandom | od -An -tx1 | tr -d ' \n' | cut -c1-40)
  mkdir -p "$work/repl"
  rm -f "$work/repl/password"
  printf '%s' "$password" > "$work/repl/password"
  chmod 444 "$work/repl/password"
  start_db prim "walg/prim-$version" "$work/secrets-src" --entrypoint /opt/hivepaas/bin/walg-entrypoint \
    -- "${server_args[@]}"
  wait_ready prim || { fail "the primary starts"; return; }
  sql_in prim "create table t (id int primary key, at timestamp(6) not null default current_timestamp(6))"
  sql_in prim "insert into t (id) select seq from seq_1_to_10"
  job_env=()
  check "the primary's first base backup" job prim walg-nightly backup

  docker exec -i "$run-prim" /opt/hivepaas/bin/walg-replication <<<"$password" > "$work/job.log" 2>&1 &&
    code=0 || code=$?
  check "walg-replication: lets replicas in" test "$code" = 0
  check "walg-replication: again, as it is" bash -c \
    "docker exec -i $run-prim /opt/hivepaas/bin/walg-replication <<<'$password' >/dev/null"
  check "walg-replication: refuses a password that is not one" bash -c \
    "! docker exec -i $run-prim /opt/hivepaas/bin/walg-replication <<<'short' >/dev/null 2>&1"
  check "walg-replication: keeps the password for walg-health, the mysql user's alone, beside the data" \
    test "$(docker exec "$run-prim" stat -c '%U %a' /var/lib/mysql/hivepaas-replication.cnf)" = "mysql 600"

  writing
  start_replica r1 2
  start_replica r2 3
  wait_ready r1 || fail "replica 1 starts"
  wait_ready r2 || fail "replica 2 starts"
  check "replica 1 was seeded from the archive" docker exec "$run-r1" grep -q "^Seeding the replica from stream_" \
    /var/lib/mysql/hivepaas-restore.log
  sleep 5
  stop_writing
  check "replica 1 holds the primary's rows, written while it was seeded" same_rows r1
  check "replica 2 too" same_rows r2
  check "a replica is read-only to the app" bash -c \
    "! docker exec $run-r1 mariadb -uapp -papp-password-1 app -e 'insert into t (id) values (1)' 2>/dev/null"
  check "a replica writes binary logs of its own name" grep -q '^mariadb-bin-r1\.' <<<"$(active_log r1)"
  check "with the primary's GTIDs" test "$(sql_in r1 "select @@gtid_binlog_pos")" = \
    "$(sql_in prim "select @@gtid_binlog_pos")"
  check "the primary's archive loop archives what was written" caught_up prim
  check "a replica pushes none of its logs" bash -c "! grep -q mariadb-bin-r <<<'$(archived_logs prim)'"
  check "walg-health: lists the replicas" job prim walg-health
  check "walg-health: both streaming" bash -c "grep -q '$run-r1@streaming@[0-9]*@[0-9]*' <<<'$(output REPLICAS)' &&
    grep -q '$run-r2@streaming@' <<<'$(output REPLICAS)'"
  check "the password is on no process's arguments" bash -c "! docker exec $run-r1 sh -c 'cat /proc/[0-9]*/cmdline' |
    tr '\0' ' ' | grep -q '$password' && ! docker exec $run-prim sh -c 'cat /proc/[0-9]*/cmdline' | tr '\0' ' ' |
    grep -q '$password'"

  # A replica behind what the primary keeps: stopped while the primary writes
  # and archives - and purges what it archived.
  docker stop "$run-r2" >/dev/null
  writing
  sleep $((archive_timeout * 3))
  stop_writing
  check "the primary archived on" caught_up prim
  docker start "$run-r2" >/dev/null
  wait_ready r2 || fail "replica 2 starts again"
  check "replica 2, behind what the primary keeps, catches up from the archive" same_rows r2 90
  check "saying so" bash -c "docker logs $run-r2 2>&1 | grep -q 'catching up from the archive'"
  check "and streams again" bash -c "sleep 3; [ \"\$(docker exec -u mysql $run-r2 mariadb -umysql -E -e 'show slave status' |
    sed -n 's/^ *Slave_IO_Running: //p')\" = Yes ]"
  check "not seeded again" test "$(docker exec "$run-r2" grep -c '^Seeding' /var/lib/mysql/hivepaas-restore.log)" = 1

  # A base backup taken on a replica restores, by its GTID, over the primary's logs.
  check "walg-nightly backup on a replica" job r1 walg-nightly backup
  backup=$(output BACKUP_NAME)
  check "in the cluster's archive, its latest ($backup)" test "$(docker exec "$run-prim" /opt/hivepaas/bin/walg-run \
    backup-list --json 2>/dev/null | jq -r 'sort_by(.time) | last | .backup_name')" = "$backup"
  sql_in prim "insert into t (id) select seq from seq_11_to_15"
  check "the primary archives the rows after it" caught_up prim
  RESTORE_SOURCE=prim restore restored-replica latest
  check "latest, from the replica's backup: the primary's rows" test "$restored_rows" = \
    "$(sql_in prim "select count(*) from t")"
  check "walg-nightly retain on the primary: the chain still follows" job prim walg-nightly retain

  # A replica the archive cannot seed idles, saying why.
  start_replica r9 9 "walg/none-$version"
  for _ in $(seq 60); do
    docker exec "$run-r9" /opt/hivepaas/bin/walg-entrypoint status > "$work/status.log" 2>&1 && code=0 || code=$?
    if [ "$code" != 75 ]; then break; fi
    sleep 1
  done
  check "a replica the archive cannot seed: status fails" test "$code" = 1
  check "saying why" grep -q "no base backup to seed" "$work/status.log"
  check "healthy, so that it is not restarted" docker exec "$run-r9" /opt/hivepaas/bin/walg-entrypoint health
  check "and runs no server" bash -c "! docker exec $run-r9 sh -c 'cat /proc/[0-9]*/comm' | grep -qx mariadbd"
  docker rm -fv "$run-r1" "$run-r2" "$run-r9" "$run-prim" >/dev/null
  docker volume rm "$run-r1" "$run-r2" "$run-r9" "$run-prim" >/dev/null
}

# stop_archiving NAME: its archive loop stopped, so that what it writes from now
# is archived by none - as by a primary that dies.
stop_archiving() {
  docker exec "$run-$1" sh -c 'for p in /proc/[0-9]*; do
    if tr "\0" " " < "$p/cmdline" 2>/dev/null | grep -q "walg-archiv[e] loop"; then kill "${p#/proc/}"; fi; done'
}

follows_r1() { WRITER=r1 same_rows r2 90; }

test_promotion() {
  say "promotion: a replica over its fenced primary, the primary's last writes unarchived"
  local password code before rows
  password=$(head -c 30 /dev/urandom | od -An -tx1 | tr -d ' \n' | cut -c1-40)
  mkdir -p "$work/repl"
  rm -f "$work/repl/password"
  printf '%s' "$password" > "$work/repl/password"
  chmod 444 "$work/repl/password"
  start_db prim "walg/prom-$version" "$work/secrets-src" --entrypoint /opt/hivepaas/bin/walg-entrypoint \
    -- "${server_args[@]}"
  wait_ready prim || { fail "the primary starts"; return; }
  sql_in prim "create table t (id int primary key, at timestamp(6) not null default current_timestamp(6))"
  sql_in prim "insert into t (id) select seq from seq_1_to_10"
  job_env=()
  job prim walg-nightly backup >/dev/null || fail "the primary's base backup"
  docker exec -i "$run-prim" /opt/hivepaas/bin/walg-replication <<<"$password" >/dev/null ||
    fail "replicas let in"
  start_replica r1 2 "walg/prom-$version"
  start_replica r2 3 "walg/prom-$version"
  wait_ready r1 || fail "replica 1 starts"
  wait_ready r2 || fail "replica 2 starts"
  sql_in prim "insert into t (id) select seq from seq_11_to_20"
  check "the primary archives its rows" caught_up prim
  before=$(archived_logs prim | grep -c .)

  stop_archiving prim
  sql_in prim "insert into t (id) select seq from seq_21_to_30"
  check "replica 1 has the primary's last rows" same_rows r1
  check "replica 2 too" same_rows r2
  sleep $((archive_timeout * 2))
  check "which the primary never archived" test "$(archived_logs prim | grep -c .)" = "$before"
  docker stop "$run-prim" >/dev/null

  docker exec "$run-r1" /opt/hivepaas/bin/walg-entrypoint promote > "$work/job.log" 2>&1 && code=0 || code=$?
  check "walg-entrypoint promote: promotes replica 1" test "$code" = 0
  check "walg-entrypoint promote: archives its logs" grep -q "Its binary logs are archived" "$work/job.log"
  check "it writes" sql_in r1 "insert into t (id) select seq from seq_31_to_40"
  check "replicates from none" test -z "$(docker exec -u mysql "$run-r1" mariadb -umysql -N -e 'show slave status')"
  check "its own logs are in the cluster's archive" bash -c "grep -q '^mariadb-bin-r1\.' <<<'$(archived_logs r1)'"
  check "it archives on, as a primary" caught_up r1
  docker exec "$run-r1" /opt/hivepaas/bin/walg-entrypoint promote > "$work/job.log" 2>&1 && code=0 || code=$?
  check "walg-entrypoint promote: again, as it is" test "$code" = 0
  check "its new writes are the cluster's next GTIDs, under its own server id" grep -qE '(^|,)0-2-[0-9]+' \
    <<<"$(sql_in r1 "select @@gtid_binlog_pos")"

  # Replica 2 follows it, its standby variables pointed at it: restarted.
  docker rm -f "$run-r2" >/dev/null
  WRITER=r1 DB_VOLUME=$run-r2 start_replica r2 3 "walg/prom-$version"
  wait_ready r2 || fail "replica 2 starts again"
  check "replica 2 follows the promoted member" follows_r1
  check "not seeded again" test "$(docker exec "$run-r2" grep -c '^Seeding' /var/lib/mysql/hivepaas-restore.log)" = 1
  check "walg-health on the promoted member lists replica 2" job r1 walg-health
  check "streaming" grep -q "$run-r2@streaming@" <<<"$(output REPLICAS)"

  # A restore across the promotion: the old primary's base backup, its logs, and
  # the promoted member's, which hold the rows the old primary never archived.
  rows=$(sql_in r1 "select count(*) from t")
  RESTORE_SOURCE=prom restore restored-promoted latest
  check "latest, across the promotion: the $rows rows" test "$restored_rows" = "$rows"
  check "walg-nightly retain on the promoted member: the chain of both names follows" job r1 walg-nightly retain

  # The old primary, fenced, never starts its server.
  docker rm "$run-prim" >/dev/null
  DB_VOLUME=$run-prim start_db prim "walg/prom-$version" "$work/secrets-src" -e "HIVEPAAS_FENCED=r1 was promoted" \
    --entrypoint /opt/hivepaas/bin/walg-entrypoint -- "${server_args[@]}"
  sleep 5
  check "a fenced member idles" test "$(docker inspect -f '{{.State.Running}}' "$run-prim")" = true
  check "healthy, so that it is not restarted" docker exec "$run-prim" /opt/hivepaas/bin/walg-entrypoint health
  check "and runs no server" bash -c "! docker exec $run-prim sh -c 'cat /proc/[0-9]*/comm' | grep -qx mariadbd"
  docker exec "$run-prim" /opt/hivepaas/bin/walg-entrypoint promote > "$work/job.log" 2>&1 && code=0 || code=$?
  check "walg-entrypoint promote where no server answers: certainly nothing promoted (3)" test "$code" = 3

  # The promoted member restarted, its standby variables still there: the
  # marker keeps it the primary.
  docker restart "$run-r1" >/dev/null
  wait_ready r1 || fail "the promoted member starts again"
  check "restarted, it is still the primary, writing" sql_in r1 "insert into t (id) values (41)"
  check "under its own log name" grep -q '^mariadb-bin-r1\.' <<<"$(active_log r1)"
  docker rm -fv "$run-r1" "$run-r2" "$run-prim" >/dev/null
  docker volume rm "$run-r1" "$run-r2" "$run-prim" >/dev/null
}

# --- each version ------------------------------------------------------------

run_version() {
  version=$1
  image=$(python3 -c "import sys,yaml; d=yaml.safe_load(open(sys.argv[1])); \
print(next(v['image'] for v in d['versions'] if v['name']==sys.argv[2]))" "$template" "$version")
  say "MariaDB $version ($image)"
  rm -rf "$work/secrets-src"
  secrets "$work/secrets-src" "$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  own_key=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')
  docker volume create --label "$run" --label "$run-db" "$run-verify-$version" >/dev/null
  if [ -n "${ONLY:-}" ]; then
    "test_$ONLY"
  elif test_archive; then
    test_restore_test
    test_restores
    test_basenames
    test_replicas
    test_promotion
    test_passthrough
    test_fresh_start
    test_secrets
    test_retention
  fi
  # What this version made goes, its volumes too: the next one starts from nothing.
  docker ps -aq --filter "label=$run-db" | xargs -r docker rm -fv >/dev/null
  docker volume ls -q --filter "label=$run-db" | xargs -r docker volume rm >/dev/null
}

versions=("$@")
if [ ${#versions[@]} = 0 ]; then versions=(11.8 11.4); fi
prepare_bin
start_s3
for version in "${versions[@]}"; do run_version "$version"; done
if [ "$failures" -gt 0 ]; then
  printf '\n%d check(s) failed\n' "$failures"
  exit 1
fi
printf '\nAll checks passed\n'
