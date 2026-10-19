#!/bin/bash
# The mariadb-managed template's scripts, run as HivePaaS runs them: in the
# template's own images, with the template's WAL-G artifact, against an S3 store
# (SeaweedFS). Each version is a set of throwaway containers, removed afterwards.
#
#   scripts/test/walg-mariadb/run.sh [11.8] [11.4]     both when none is given
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
  docker volume create --label "$run" --label "$run-db" "$run-$name" >/dev/null
  # --init as HivePaaS runs it: docker's init is PID 1, and reaps what is detached.
  docker run -d --init --label "$run" --label "$run-db" --name "$run-$name" --network "$run" \
    -v "$run-$name:/var/lib/mysql" -v "$work/bin:/opt/hivepaas/bin:ro" -v "$secrets:/run/secrets/walg:ro" \
    "${env[@]}" "${opts[@]}" "$image" "$@" >/dev/null
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
  sleep 2
  time_at_20=$(sql_in src "select date_format(utc_timestamp(), '%Y-%m-%dT%H:%i:%sZ')")
  sleep 2
  sql_in src "insert into t (id) select seq from seq_21_to_30"
  check "walg-mark: makes a point once its log is archived" job src walg-mark before-31 60
  point_position=$(sed -n 's/^POSITION=//p' "$work/job.log")
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
restore() {
  local name=$1 kind=$2 code
  local -a target
  case $kind in
    latest) target=(-e HIVEPAAS_RESTORE_TARGET_BACKUP=LATEST) ;;
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
    -e "HIVEPAAS_RESTORE_WALG_S3_PREFIX=s3://backups/walg/src-$version" \
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
    check "$kind: archives to its own prefix" caught_up "$name"
    restored_r=$(sql_in "$name" "select count(*) from r" 2>/dev/null || echo none)
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
  docker rm -fv "$run-plain" >/dev/null
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
  if test_archive; then
    test_restore_test
    test_restores
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
