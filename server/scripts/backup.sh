#!/usr/bin/env bash
set -euo pipefail

umask 077
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
server_dir="$(cd "$script_dir/.." && pwd)"
backup_dir="${1:-$server_dir/backups}"
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
output_file="$backup_dir/budget-$timestamp.tar.gz.age"

command -v docker >/dev/null || { echo "docker is required" >&2; exit 1; }
command -v age >/dev/null || { echo "age is required (https://age-encryption.org)" >&2; exit 1; }
mkdir -p "$backup_dir"
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

echo "Creating an encrypted backup at $output_file"
echo "You will be prompted for a backup passphrase by age."
docker compose --project-directory "$server_dir" exec -T database \
  pg_dump --clean --if-exists --no-owner --no-privileges -U budget -d budget \
  > "$work_dir/database.sql"
mkdir -p "$work_dir/attachments"
docker compose --project-directory "$server_dir" cp api:/var/lib/budget-app/attachments/. "$work_dir/attachments/"
docker compose --project-directory "$server_dir" exec -T api sh -c \
  'if [ -n "${BUDGET_APP_ATTACHMENT_ENCRYPTION_KEY:-}" ]; then printf "BUDGET_APP_ATTACHMENT_ENCRYPTION_KEY=%s\\n" "$BUDGET_APP_ATTACHMENT_ENCRYPTION_KEY"; else printf "BUDGET_APP_JWT_SECRET=%s\\n" "$BUDGET_APP_JWT_SECRET"; fi' \
  > "$work_dir/attachment-key-recovery.env"
(cd "$work_dir" && shasum -a 256 database.sql attachment-key-recovery.env attachments/* 2>/dev/null > MANIFEST.sha256 || shasum -a 256 database.sql attachment-key-recovery.env > MANIFEST.sha256)
tar -C "$work_dir" -czf - database.sql attachments attachment-key-recovery.env MANIFEST.sha256 \
  | age --passphrase --output "$output_file"

echo "Backup complete: $output_file"
echo "Test restoring this file regularly and store its passphrase separately."
