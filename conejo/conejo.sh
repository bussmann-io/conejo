#!/bin/bash
set -Eeuo pipefail
umask 0077

FORGEJO=/usr/local/bin/forgejo
STATE=$GITEA_WORK_DIR/conejo
SNAPSHOT=$STATE/pre-upgrade
TEMP=$GITEA_TEMP/conejo
HEALTHY=$TEMP/healthy
EMPTY_SHA256=e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855

log() { printf '%s [conejo] %s\n' "$(date -u +%FT%TZ)" "$*"; }
warn() { log "WARNING: $*"; }
die() {
  log "FATAL: $*"
  exit 1
}

require() {
  local purpose=$1 name
  shift
  for name; do
    [ -n "${!name:-}" ] || die "$name is not set, and $purpose needs it"
  done
}

ini() {
  awk -v section="$1" -v key="$2" '
    /^[[:space:]]*\[.*\][[:space:]]*$/ {
      current = $0
      gsub(/^[[:space:]]*\[|\][[:space:]]*$/, "", current)
      next
    }
    current == section {
      name = $0
      sub(/[[:space:]]*=.*/, "", name)
      sub(/^[[:space:]]*/, "", name)
      if (name == key) {
        value = $0
        sub(/^[^=]*=[[:space:]]*/, "", value)
        print value
        exit
      }
    }
  ' "$GITEA_APP_INI"
}

s3() {
  local key_id=$1 secret=$2 key=$3 payload_sha256=$4
  shift 4
  curl -sS --fail-with-body --retry 3 --retry-delay 15 \
    --connect-timeout 30 --speed-limit 1024 --speed-time 120 \
    --aws-sigv4 "aws:amz:$CONEJO_BACKUP_REGION:s3" \
    -H "x-amz-content-sha256: $payload_sha256" "$@" \
    -K - "${CONEJO_BACKUP_URL%/}/$key" <<<"user = \"$key_id:$secret\""
}

upload() {
  local file=$1 key=$2 sha256 md5
  sha256=$(sha256sum "$file" | cut -d' ' -f1)
  md5=$(printf '%b' "$(md5sum "$file" | cut -d' ' -f1 | sed 's/../\\x&/g')" | base64)
  if ! s3 "$CONEJO_BACKUP_ACCESS_KEY_ID" "$CONEJO_BACKUP_SECRET_ACCESS_KEY" "$key" "$sha256" \
    -T "$file" -o "$TEMP/s3-response" -H "Content-MD5: $md5" -H 'Content-Type: application/octet-stream'; then
    log "backup: uploading $key failed: $(head -c 500 "$TEMP/s3-response" 2>/dev/null)"
    return 1
  fi
  log "backup: uploaded $key ($(du -h "$file" | cut -f1))"
}

download() {
  s3 "$CONEJO_RESTORE_ACCESS_KEY_ID" "$CONEJO_RESTORE_SECRET_ACCESS_KEY" "$1" "$EMPTY_SHA256" -o "$2"
}

gpg_passphrase() {
  GNUPGHOME=$TEMP/gnupg gpg --batch --yes --no-tty --quiet --pinentry-mode loopback \
    --passphrase-fd 3 "$@" 3<<<"$CONEJO_BACKUP_PASSPHRASE"
}

restore() {
  require "restoring a backup" CONEJO_BACKUP_URL CONEJO_BACKUP_REGION CONEJO_BACKUP_PASSPHRASE \
    CONEJO_RESTORE_ACCESS_KEY_ID CONEJO_RESTORE_SECRET_ACCESS_KEY
  local dir=$STATE/restore part target relative
  rm -rf "$dir" && mkdir -p "$dir/dump"
  log "restore: downloading $CONEJO_RESTORE_FROM"
  download "$CONEJO_RESTORE_FROM" "$dir/backup.gpg" ||
    die "restore: downloading $CONEJO_RESTORE_FROM failed: $(head -c 500 "$dir/backup.gpg" 2>/dev/null)"
  gpg_passphrase --decrypt -o "$dir/backup.tar.gz" "$dir/backup.gpg" ||
    die "restore: decrypting failed, check CONEJO_BACKUP_PASSPHRASE"
  rm -f "$dir/backup.gpg"
  tar -xzf "$dir/backup.tar.gz" -C "$dir/dump" || die "restore: unpacking the backup failed"
  rm -f "$dir/backup.tar.gz"
  [ -f "$dir/dump/forgejo-db.sql" ] || die "restore: $CONEJO_RESTORE_FROM is not a Forgejo dump"

  sqlite3 "$dir/forgejo.db" <"$dir/dump/forgejo-db.sql" || die "restore: rebuilding the database failed"
  [ "$(sqlite3 "$dir/forgejo.db" 'PRAGMA integrity_check;')" = ok ] ||
    die "restore: the rebuilt database failed its integrity check"

  relative=${DB#"$DATA"/}
  rm -f "$dir/dump/data/$relative" "$dir/dump/data/$relative-wal" "$dir/dump/data/$relative-shm" "$dir/dump/data/$relative-journal"
  for part in "data:$DATA" "repos:$REPOS" "custom:$GITEA_CUSTOM"; do
    target=${part#*:}
    part=${part%%:*}
    [ -d "$dir/dump/$part" ] || continue
    mkdir -p "$target" || die "restore: creating $target failed"
    cp -a "$dir/dump/$part/." "$target/" || die "restore: copying $part failed"
  done
  mkdir -p "$(dirname "$DB")"
  mv "$dir/forgejo.db" "$DB"
  log "restore: done, $(sqlite3 "$DB" 'SELECT count(*) FROM user;') users"
  rm -rf "$dir"
}

protect_upgrade() {
  [ -f "$DB" ] || return 0
  local last from to
  last=$(cat "$STATE/version" 2>/dev/null || echo unknown)
  if [ -f "$STATE/pending" ]; then
    read -r from to <"$STATE/pending" || true
    if [ "$version" = "${from:-}" ]; then
      [ -f "$SNAPSHOT/$(basename "$DB")" ] || die "upgrade marker without a database copy in $SNAPSHOT"
      log "Forgejo $to never became healthy: restoring the database from before the upgrade"
      rm -f "$DB" "$DB-wal" "$DB-shm" "$DB-journal"
      cp -p "$SNAPSHOT"/* "$(dirname "$DB")/"
      sync
      rm -rf "$STATE/pending" "$SNAPSHOT"
      last=$version
    fi
  fi
  if [ "$last" != "$version" ] && [ ! -f "$STATE/pending" ]; then
    rm -rf "$SNAPSHOT" && mkdir -p "$SNAPSHOT"
    for file in "$DB" "$DB-wal" "$DB-shm"; do
      [ ! -e "$file" ] || cp -p "$file" "$SNAPSHOT/"
    done
    sync
    printf '%s %s\n' "$last" "$version" >"$STATE/pending"
    log "version change $last -> $version: database copied to $SNAPSHOT"
  fi
}

ensure_admin() {
  [ -n "${CONEJO_ADMIN_USERNAME:-}${CONEJO_ADMIN_PASSWORD:-}" ] || return 0
  require "the admin account" CONEJO_ADMIN_USERNAME CONEJO_ADMIN_PASSWORD
  local output users
  users=$("$FORGEJO" admin user list 2>&1) || die "admin: listing the users failed: $users"
  if awk -v name="$CONEJO_ADMIN_USERNAME" 'NR > 1 && $2 == name { found = 1 } END { exit !found }' <<<"$users"; then
    output=$("$FORGEJO" admin user change-password --username "$CONEJO_ADMIN_USERNAME" \
      --password "$CONEJO_ADMIN_PASSWORD" --must-change-password=false 2>&1) ||
      die "admin: setting the password of $CONEJO_ADMIN_USERNAME failed: $output"
    log "admin: set the password of $CONEJO_ADMIN_USERNAME"
  else
    require "creating the admin account" CONEJO_ADMIN_EMAIL
    output=$("$FORGEJO" admin user create --admin --username "$CONEJO_ADMIN_USERNAME" --email "$CONEJO_ADMIN_EMAIL" \
      --password "$CONEJO_ADMIN_PASSWORD" --must-change-password=false 2>&1) ||
      die "admin: creating $CONEJO_ADMIN_USERNAME failed: $output"
    log "admin: created $CONEJO_ADMIN_USERNAME"
  fi
  warn "CONEJO_ADMIN_* sets the password of $CONEJO_ADMIN_USERNAME on every start. Remove it once you can sign in."
}

register_runner() {
  [ -n "${CONEJO_RUNNER_SECRET:-}" ] || return 0
  local output args=(--secret-file "$TEMP/runner-secret" --keep-labels)
  [ -z "${CONEJO_RUNNER_NAME:-}" ] || args+=(--name "$CONEJO_RUNNER_NAME")
  printf '%s' "$CONEJO_RUNNER_SECRET" >"$TEMP/runner-secret"
  if output=$("$FORGEJO" forgejo-cli actions register "${args[@]}" 2>&1); then
    log "runner: registered for every repository"
  else
    warn "runner: registration failed: $output"
  fi
  rm -f "$TEMP/runner-secret"
}

watch_health() {
  until curl -fsS -m 5 -o /dev/null "http://127.0.0.1:$HTTP_PORT/api/healthz" 2>/dev/null; do sleep 5; done
  : >"$HEALTHY"
  printf '%s\n' "$version" >"$STATE/version"
  if [ -f "$STATE/pending" ]; then
    rm -rf "$STATE/pending" "$SNAPSHOT"
    log "Forgejo $version is healthy: upgrade confirmed"
  else
    log "Forgejo $version is healthy"
  fi
}

backup_once() {
  local dir=$STATE/backup stamp hour day weekday month month_number file
  read -r stamp hour day weekday month month_number < <(date -u '+%Y%m%d%H %H %Y%m%d %a %Y%m %m')
  rm -rf "$dir/dump" && mkdir -p "$dir/dump" || return 1
  file=$dir/dump/forgejo.tar.gz
  log "backup: dumping"
  nice -n 10 "$FORGEJO" dump --quiet --type tar.gz --file "$file" --tempdir "$dir/dump" \
    --skip-index --skip-repo-archives --skip-log || {
    log "backup: dump failed"
    return 1
  }
  gpg_passphrase --symmetric --cipher-algo AES256 --compress-algo none -o "$file.gpg" "$file" || {
    log "backup: encryption failed"
    return 1
  }
  rm -f "$file"
  upload "$file.gpg" "hourly/forgejo-$hour.tar.gz.gpg" || return 1
  printf '%s\n' "$stamp" >"$dir/hourly"
  if [ "$(cat "$dir/daily" 2>/dev/null)" != "$day" ]; then
    upload "$file.gpg" "daily/forgejo-${weekday,,}.tar.gz.gpg" || return 1
    printf '%s\n' "$day" >"$dir/daily"
  fi
  if [ "$(cat "$dir/monthly" 2>/dev/null)" != "$month" ]; then
    upload "$file.gpg" "monthly/forgejo-$month_number.tar.gz.gpg" || return 1
    printf '%s\n' "$month" >"$dir/monthly"
  fi
  rm -rf "$dir/dump"
}

ping_monitor() {
  [ -n "${CONEJO_BACKUP_PING_URL:-}" ] || return 0
  curl -fsS -m 10 --retry 3 -o /dev/null "$CONEJO_BACKUP_PING_URL$1" || warn "backup: pinging CONEJO_BACKUP_PING_URL failed"
}

backup_loop() {
  until [ -f "$HEALTHY" ]; do sleep 5; done
  while :; do
    if [ "$(date -u +%Y%m%d%H)" != "$(cat "$STATE/backup/hourly" 2>/dev/null)" ]; then
      if backup_once; then
        ping_monitor ""
      else
        log "backup: ERROR, the backup failed, retrying in 5 minutes"
        ping_monitor /fail
      fi
    fi
    sleep 300
  done
}

[ "$(ini database DB_TYPE)" = sqlite3 ] || die "conejo only supports FORGEJO__database__DB_TYPE=sqlite3"
[ -n "$(ini security SECRET_KEY)$(ini security SECRET_KEY_URI)" ] ||
  die "FORGEJO__security__SECRET_KEY is not set, so Forgejo would encrypt secrets with a public default key"
DB=$(ini database PATH)
DATA=$(ini server APP_DATA_PATH)
REPOS=$(ini repository ROOT)
LFS=$(ini lfs PATH)
HTTP_PORT=$(ini server HTTP_PORT)
version=$(/app/gitea/gitea --version | sed -n 's/.*(release name \([^)]*\)).*/\1/p')
[ -n "$version" ] || die "could not read the Forgejo version"

expect_data=${CONEJO_EXPECT_DATA:-true}
case $expect_data in
  true | false) ;;
  *) die "CONEJO_EXPECT_DATA must be true or false, not '$expect_data'" ;;
esac
if [ -n "${CONEJO_BACKUP_ACCESS_KEY_ID:-}" ]; then
  require "backups" CONEJO_BACKUP_URL CONEJO_BACKUP_REGION CONEJO_BACKUP_SECRET_ACCESS_KEY CONEJO_BACKUP_PASSPHRASE
else
  warn "backups are off, and Bunny volumes have no snapshots: set CONEJO_BACKUP_ACCESS_KEY_ID and the other CONEJO_BACKUP_* variables"
fi
if [ -n "${CONEJO_RUNNER_SECRET:-}" ] && ! [[ $CONEJO_RUNNER_SECRET =~ ^[0-9a-f]{40}$ ]]; then
  die "CONEJO_RUNNER_SECRET must be 40 lowercase hex characters"
fi

mkdir -p "$STATE" || die "the volume at $GITEA_WORK_DIR is not writable"
rm -rf "$TEMP" && mkdir -p "$TEMP/gnupg"
log "Forgejo $version starting"

if [ -f "$DB" ]; then
  [ -z "${CONEJO_RESTORE_FROM:-}" ] ||
    warn "CONEJO_RESTORE_FROM is set, but $DB exists, so nothing was restored. Remove CONEJO_RESTORE_FROM."
  [ "$expect_data" = true ] ||
    warn "CONEJO_EXPECT_DATA=false turns off the empty volume check. Set it to true now that the instance exists."
elif [ -n "${CONEJO_RESTORE_FROM:-}" ]; then
  restore
elif [ "$expect_data" = true ]; then
  die "no database at $DB: the volume looks empty or replaced. Restore a backup with CONEJO_RESTORE_FROM, or set CONEJO_EXPECT_DATA=false for a new instance."
else
  log "no database yet: starting a new instance"
fi

mkdir -p "$REPOS" "$LFS"
protect_upgrade
"$FORGEJO" migrate || die "forgejo migrate failed"
ensure_admin
register_runner

watch_health &
if [ -n "${CONEJO_BACKUP_ACCESS_KEY_ID:-}" ]; then
  backup_loop &
fi

log "starting forgejo web"
exec /usr/bin/dumb-init -- "$FORGEJO" web
