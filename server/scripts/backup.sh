#!/usr/bin/env bash
set -euo pipefail

umask 077
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
server_dir="$(cd "$script_dir/.." && pwd)"
backup_dir="${1:-$server_dir/backups}"
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
output_file="$backup_dir/budget-$timestamp.sql.gz.age"

command -v docker >/dev/null || { echo "docker is required" >&2; exit 1; }
command -v age >/dev/null || { echo "age is required (https://age-encryption.org)" >&2; exit 1; }
mkdir -p "$backup_dir"

echo "Creating an encrypted backup at $output_file"
echo "You will be prompted for a backup passphrase by age."
docker compose --project-directory "$server_dir" exec -T database \
  pg_dump --clean --if-exists --no-owner --no-privileges -U budget -d budget \
  | gzip -9 \
  | age --passphrase --output "$output_file"

echo "Backup complete: $output_file"
echo "Test restoring this file regularly and store its passphrase separately."
