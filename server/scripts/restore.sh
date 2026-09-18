#!/usr/bin/env bash
set -euo pipefail
umask 077

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
server_dir="$(cd "$script_dir/.." && pwd)"

if [[ "${1:-}" != "--yes" || "${2:-}" != "--project-name" || -z "${3:-}" || -z "${4:-}" || -n "${5:-}" ]]; then
  echo "Usage: $0 --yes --project-name NAME /path/to/budget-backup.tar.gz.age" >&2
  echo "WARNING: restore replaces the current Budget App database contents." >&2
  echo "The explicit Docker Compose project name is required to prevent restoring into an implicit target." >&2
  exit 2
fi

project_name="$3"
backup_file="$4"
[[ "$project_name" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || { echo "Invalid Docker Compose project name" >&2; exit 2; }
[[ -f "$backup_file" ]] || { echo "Backup not found: $backup_file" >&2; exit 1; }
command -v docker >/dev/null || { echo "docker is required" >&2; exit 1; }
command -v age >/dev/null || { echo "age is required (https://age-encryption.org)" >&2; exit 1; }
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

echo "Restoring $backup_file into the Budget App database."
echo "Target Docker Compose project: $project_name"
echo "You will be prompted for the backup passphrase by age."
age --decrypt "$backup_file" | tar -C "$work_dir" -xzf -
(cd "$work_dir" && [[ -f BACKUP-METADATA && -f database.sql && -f attachment-key-recovery.env && -d attachments ]] ) || {
  echo "Backup is incomplete: metadata, database, attachment key recovery, or attachment objects are missing" >&2
  exit 1
}
(cd "$work_dir" && shasum -a 256 -c MANIFEST.sha256)
format_version="$(sed -n 's/^format_version=//p' "$work_dir/BACKUP-METADATA")"
[[ "$format_version" == "1" ]] || {
  echo "Unsupported backup format version: ${format_version:-missing}" >&2
  exit 1
}
compose=(docker compose --project-directory "$server_dir" --project-name "$project_name")
# Never source recovery material or print secrets. A readable archive is not enough:
# replacing objects with ciphertext for another key would make attachments unreadable.
backup_key="$(<"$work_dir/attachment-key-recovery.env")"
if [[ ! "$backup_key" =~ ^BUDGET_APP_(ATTACHMENT_ENCRYPTION_KEY|JWT_SECRET)=.+$ || "$backup_key" == *$'\n'* ]]; then
  echo "Backup attachment key recovery material is invalid; no destination data changed" >&2
  exit 1
fi
destination_key="$("${compose[@]}" exec -T api sh -c \
  'if [ -n "${BUDGET_APP_ATTACHMENT_ENCRYPTION_KEY:-}" ]; then printf "BUDGET_APP_ATTACHMENT_ENCRYPTION_KEY=%s\\n" "$BUDGET_APP_ATTACHMENT_ENCRYPTION_KEY"; else printf "BUDGET_APP_JWT_SECRET=%s\\n" "$BUDGET_APP_JWT_SECRET"; fi')"
if [[ "$destination_key" != "$backup_key" ]]; then
  echo "Destination attachment key does not match backup; no destination data changed" >&2
  echo "Configure the explicit recovery deployment with the backup attachment encryption secret, then retry." >&2
  exit 1
fi
unset backup_key destination_key
"${compose[@]}" exec -T database \
  psql --single-transaction --set ON_ERROR_STOP=on -U budget -d budget < "$work_dir/database.sql"
"${compose[@]}" exec -T api sh -c 'find /var/lib/budget-app/attachments -mindepth 1 -maxdepth 1 -type f -delete'
"${compose[@]}" cp "$work_dir/attachments/." api:/var/lib/budget-app/attachments/

echo "Restore complete. Restarting the API."
"${compose[@]}" restart api
echo "The destination attachment encryption configuration matched the verified backup before restore."
