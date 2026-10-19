#!/bin/sh
# Encrypted PostgreSQL backups to S3.
#
# Commands:
#   run               (default) backup now, then every BACKUP_INTERVAL_MINUTES
#   backup            single backup and exit
#   list              list restore points in S3
#   restore [SEL]     choose a restore point and restore it; SEL = number | latest | S3 file name
#                     (without SEL: interactive choice, needs `docker exec -it`)
#
# Environment:
#   POSTGRES_USER POSTGRES_PASSWORD POSTGRES_DB POSTGRES_HOST [POSTGRES_PORT=5432]
#   S3_BUCKET S3_ACCESS_KEY_ID S3_SECRET_ACCESS_KEY [S3_REGION=us-east-1]
#   [S3_ENDPOINT]  for MinIO / R2 / Selectel etc.
#   [S3_PREFIX=postgres-backups]  folder in the bucket (nested like a/b/c is fine);
#                                 created automatically if it does not exist
#   BACKUP_INTERVAL_MINUTES   backup frequency (only for `run`)
#   BACKUP_ENCRYPTION_PASSWORD
#   [RESTORE_YES=1] skip the confirmation prompt on restore

set -eu

log() { printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

need() {
  for v in "$@"; do
    eval "val=\${$v:-}"
    [ -n "$val" ] || die "environment variable $v is not set"
  done
}

need_pg()  { need POSTGRES_USER POSTGRES_PASSWORD POSTGRES_DB POSTGRES_HOST; }
need_s3()  { need S3_BUCKET S3_ACCESS_KEY_ID S3_SECRET_ACCESS_KEY; }
need_enc() { need BACKUP_ENCRYPTION_PASSWORD; }

PGPORT_="${POSTGRES_PORT:-5432}"
PREFIX="${S3_PREFIX:-postgres-backups}"
PREFIX="${PREFIX#/}"; PREFIX="${PREFIX%/}"
S3_URI="s3://${S3_BUCKET:-}/${PREFIX}"

export AWS_ACCESS_KEY_ID="${S3_ACCESS_KEY_ID:-}"
export AWS_SECRET_ACCESS_KEY="${S3_SECRET_ACCESS_KEY:-}"
export AWS_DEFAULT_REGION="${S3_REGION:-us-east-1}"
export AWS_PAGER=""
export PGPASSWORD="${POSTGRES_PASSWORD:-}"

s3() {
  if [ -n "${S3_ENDPOINT:-}" ]; then
    aws --endpoint-url "$S3_ENDPOINT" s3 "$@"
  else
    aws s3 "$@"
  fi
}

s3api() {
  if [ -n "${S3_ENDPOINT:-}" ]; then
    aws --endpoint-url "$S3_ENDPOINT" s3api "$@"
  else
    aws s3api "$@"
  fi
}

# Creates the S3_PREFIX "directory" (and every parent level) as empty "dir/" marker objects,
# so S3 implementations that refuse to write into a missing folder do not fail.
ensure_prefix() {
  [ -n "$PREFIX" ] || return 0
  path=""
  oldifs="$IFS"; IFS=/
  # shellcheck disable=SC2086
  set -- $PREFIX
  IFS="$oldifs"
  for part in "$@"; do
    [ -n "$part" ] || continue
    path="${path}${part}/"
    if ! s3api head-object --bucket "$S3_BUCKET" --key "$path" >/dev/null 2>&1; then
      s3api put-object --bucket "$S3_BUCKET" --key "$path" --content-length 0 >/dev/null \
        || die "cannot create folder '${path}' in bucket ${S3_BUCKET}"
      log "created S3 folder: s3://${S3_BUCKET}/${path}"
    fi
  done
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
chmod 700 "$WORK"

# The passphrase lives only in a 0600 file inside $WORK (never on the command line).
passfile() {
  [ -f "$WORK/pass" ] || { umask 077; printf '%s' "$BACKUP_ENCRYPTION_PASSWORD" > "$WORK/pass"; }
  echo "$WORK/pass"
}

encrypt() { # in out
  gpg --batch --yes --quiet --pinentry-mode loopback --passphrase-file "$(passfile)" \
      --symmetric --cipher-algo AES256 --s2k-mode 3 --s2k-count 65011712 \
      --compress-algo none -o "$2" "$1"
}

decrypt() { # in out
  gpg --batch --yes --quiet --pinentry-mode loopback --passphrase-file "$(passfile)" \
      --decrypt -o "$2" "$1"
}

do_backup() {
  need_pg; need_s3; need_enc
  ts="$(date -u '+%Y-%m-%dT%H-%M-%SZ')"
  name="${POSTGRES_DB}_${ts}.dump.gpg"
  ensure_prefix
  log "backup of '${POSTGRES_DB}' on ${POSTGRES_HOST}:${PGPORT_} started"

  rm -f "$WORK/db.dump" "$WORK/db.dump.gpg"
  pg_dump -h "$POSTGRES_HOST" -p "$PGPORT_" -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
          -Fc -Z 6 -f "$WORK/db.dump" || { log "pg_dump failed"; return 1; }
  encrypt "$WORK/db.dump" "$WORK/db.dump.gpg" || { log "encryption failed"; return 1; }
  rm -f "$WORK/db.dump"
  s3 cp --only-show-errors "$WORK/db.dump.gpg" "${S3_URI}/${name}" || { log "S3 upload failed"; return 1; }
  size="$(wc -c < "$WORK/db.dump.gpg" | tr -d ' ')"
  rm -f "$WORK/db.dump.gpg"
  log "backup uploaded: ${S3_URI}/${name} (${size} bytes)"
}

# Fills $WORK/list with file names, newest first (names contain a UTC timestamp).
fetch_list() {
  need_s3
  # `aws s3 ls` exits 1 for an empty/missing folder; real errors are told apart by the stderr text
  s3 ls "${S3_URI}/" > "$WORK/ls.raw" 2> "$WORK/ls.err" || {
    [ ! -s "$WORK/ls.err" ] || die "cannot list ${S3_URI}/: $(cat "$WORK/ls.err")"
    : > "$WORK/ls.raw"
  }
  awk '{print $4}' "$WORK/ls.raw" | grep '\.dump\.gpg$' | sort -r > "$WORK/list" || true
  [ -s "$WORK/list" ] || die "no backups found in ${S3_URI}/"
}

do_list() {
  fetch_list
  # shellcheck disable=SC2162
  n=0
  while read name; do
    n=$((n + 1))
    printf '%3d) %s\n' "$n" "$name"
  done < "$WORK/list"
}

do_restore() {
  need_pg; need_s3; need_enc
  fetch_list
  sel="${1:-}"
  total="$(wc -l < "$WORK/list" | tr -d ' ')"

  if [ -z "$sel" ]; then
    [ -t 0 ] || die "no terminal: pass a number / latest / file name, or use 'docker exec -it'"
    echo "Available restore points (newest first):" >&2
    do_list >&2
    printf 'Choose number [1-%s] (q = quit): ' "$total" >&2
    read sel
    [ "$sel" != q ] || { log "cancelled"; return 0; }
  fi

  case "$sel" in
    latest) file="$(sed -n 1p "$WORK/list")" ;;
    ''|*[!0-9]*) file="${sel##*/}"; grep -qxF "$file" "$WORK/list" || die "file '$file' not found in S3" ;;
    *) { [ "$sel" -ge 1 ] && [ "$sel" -le "$total" ]; } || die "number must be between 1 and $total"
       file="$(sed -n "${sel}p" "$WORK/list")" ;;
  esac

  log "selected: $file"
  if [ "${RESTORE_YES:-}" != 1 ]; then
    [ -t 0 ] || die "no terminal for confirmation: set RESTORE_YES=1"
    printf "This will OVERWRITE objects in '%s' on %s. Type 'yes' to continue: " "$POSTGRES_DB" "$POSTGRES_HOST" >&2
    read ans
    [ "$ans" = yes ] || { log "cancelled"; return 0; }
  fi

  s3 cp --only-show-errors "${S3_URI}/${file}" "$WORK/r.dump.gpg" || die "download failed"
  decrypt "$WORK/r.dump.gpg" "$WORK/r.dump" || die "decryption failed (wrong BACKUP_ENCRYPTION_PASSWORD or corrupted file)"
  rm -f "$WORK/r.dump.gpg"

  log "restoring into '${POSTGRES_DB}'..."
  # --clean --if-exists replaces existing objects; --single-transaction rolls back on error
  pg_restore -h "$POSTGRES_HOST" -p "$PGPORT_" -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
             --clean --if-exists --no-owner --no-privileges --single-transaction \
             --exit-on-error "$WORK/r.dump" || die "pg_restore failed (database left unchanged)"
  log "restore finished"
}

do_run() {
  need_pg; need_s3; need_enc; need BACKUP_INTERVAL_MINUTES
  case "$BACKUP_INTERVAL_MINUTES" in
    ''|*[!0-9]*|0) die "BACKUP_INTERVAL_MINUTES must be a positive integer" ;;
  esac
  interval=$((BACKUP_INTERVAL_MINUTES * 60))
  trap 'log "stopping"; exit 0' TERM INT

  log "starting: backup every ${BACKUP_INTERVAL_MINUTES} min to ${S3_URI}/"
  while :; do
    start="$(date +%s)"
    do_backup || log "backup failed, will retry at the next interval"
    left=$((interval - ($(date +%s) - start)))
    [ "$left" -gt 0 ] || left=1
    sleep "$left" &
    wait $! || true
  done
}

cmd="${1:-run}"
[ $# -eq 0 ] || shift
case "$cmd" in
  run)     do_run ;;
  backup)  do_backup ;;
  list)    do_list ;;
  restore) do_restore "${1:-}" ;;
  *)       die "unknown command '$cmd' (run | backup | list | restore [N|latest|file])" ;;
esac
