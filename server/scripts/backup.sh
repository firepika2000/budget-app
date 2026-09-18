#!/usr/bin/env bash
set -euo pipefail

umask 077
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
server_dir="$(cd "$script_dir/.." && pwd)"
project_name=""
if [[ "${1:-}" == "--project-name" ]]; then
  [[ -n "${2:-}" ]] || { echo "--project-name requires a value" >&2; exit 2; }
  project_name="$2"
  shift 2
fi
backup_dir="${1:-$server_dir/backups}"
[[ $# -le 1 ]] || { echo "Usage: $0 [--project-name NAME] [backup-directory]" >&2; exit 2; }
compose=(docker compose --project-directory "$server_dir")
if [[ -n "$project_name" ]]; then
  [[ "$project_name" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || { echo "Invalid Docker Compose project name" >&2; exit 2; }
  compose+=(--project-name "$project_name")
fi
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
output_file="$backup_dir/budget-$timestamp.tar.gz.age"

command -v docker >/dev/null || { echo "docker is required" >&2; exit 1; }
command -v age >/dev/null || { echo "age is required (https://age-encryption.org)" >&2; exit 1; }
command -v python3 >/dev/null || { echo "python3 is required for complete backup integrity validation" >&2; exit 1; }
mkdir -p "$backup_dir"
work_dir="$(mktemp -d)"
archive_dir="$(mktemp -d "$backup_dir/.budget-staging.XXXXXX")"
trap 'rm -rf "$work_dir" "$archive_dir"' EXIT

echo "Creating an encrypted backup at $output_file"
echo "You will be prompted for a backup passphrase by age."
"${compose[@]}" exec -T database \
  pg_dump --clean --if-exists --no-owner --no-privileges -U budget -d budget \
  > "$work_dir/database.sql"
database_revision="$("${compose[@]}" exec -T database psql -At -U budget -d budget -c 'SELECT version_num FROM alembic_version')"
[[ -n "$database_revision" ]] || { echo "Unable to determine database migration revision" >&2; exit 1; }
printf 'format_version=1\ncreated_at=%s\ndatabase_revision=%s\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$database_revision" > "$work_dir/BACKUP-METADATA"
mkdir -p "$work_dir/attachments"
"${compose[@]}" cp api:/var/lib/budget-app/attachments/. "$work_dir/attachments/"
"${compose[@]}" exec -T api sh -c \
  'if [ -n "${BUDGET_APP_ATTACHMENT_ENCRYPTION_KEY:-}" ]; then printf "BUDGET_APP_ATTACHMENT_ENCRYPTION_KEY=%s\\n" "$BUDGET_APP_ATTACHMENT_ENCRYPTION_KEY"; else printf "BUDGET_APP_JWT_SECRET=%s\\n" "$BUDGET_APP_JWT_SECRET"; fi' \
  > "$work_dir/attachment-key-recovery.env"
python3 "$script_dir/backup_archive.py" create-manifest "$work_dir"
tar -C "$work_dir" -czf - BACKUP-METADATA database.sql attachments attachment-key-recovery.env MANIFEST.sha256 \
  | age --passphrase --output "$archive_dir/complete.age"
# Same-filesystem publication is atomic and refuses to overwrite an existing backup. A failed
# tar/encryption operation leaves only private staging, removed by the exit trap.
ln "$archive_dir/complete.age" "$output_file"

echo "Backup complete: $output_file"
echo "Test restoring this file regularly and store its passphrase separately."
