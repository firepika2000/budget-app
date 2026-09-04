#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
server_dir="$(cd "$script_dir/.." && pwd)"

if [[ "${1:-}" != "--yes" || -z "${2:-}" ]]; then
  echo "Usage: $0 --yes /path/to/budget-backup.sql.gz.age" >&2
  echo "WARNING: restore replaces the current Budget App database contents." >&2
  exit 2
fi

backup_file="$2"
[[ -f "$backup_file" ]] || { echo "Backup not found: $backup_file" >&2; exit 1; }
command -v docker >/dev/null || { echo "docker is required" >&2; exit 1; }
command -v age >/dev/null || { echo "age is required (https://age-encryption.org)" >&2; exit 1; }

echo "Restoring $backup_file into the Budget App database."
echo "You will be prompted for the backup passphrase by age."
age --decrypt "$backup_file" \
  | gzip --decompress \
  | docker compose --project-directory "$server_dir" exec -T database \
      psql --set ON_ERROR_STOP=on -U budget -d budget

echo "Restore complete. Restarting the API."
docker compose --project-directory "$server_dir" restart api
