#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
server_dir="$(cd "$script_dir/.." && pwd)"

if [[ "${1:-}" != "--yes" || -z "${2:-}" ]]; then
  echo "Usage: $0 --yes /path/to/budget-backup.tar.gz.age" >&2
  echo "WARNING: restore replaces the current Budget App database contents." >&2
  exit 2
fi

backup_file="$2"
[[ -f "$backup_file" ]] || { echo "Backup not found: $backup_file" >&2; exit 1; }
command -v docker >/dev/null || { echo "docker is required" >&2; exit 1; }
command -v age >/dev/null || { echo "age is required (https://age-encryption.org)" >&2; exit 1; }
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

echo "Restoring $backup_file into the Budget App database."
echo "You will be prompted for the backup passphrase by age."
age --decrypt "$backup_file" | tar -C "$work_dir" -xzf -
(cd "$work_dir" && shasum -a 256 -c MANIFEST.sha256)
docker compose --project-directory "$server_dir" exec -T database \
  psql --set ON_ERROR_STOP=on -U budget -d budget < "$work_dir/database.sql"
docker compose --project-directory "$server_dir" exec -T api sh -c 'find /var/lib/budget-app/attachments -mindepth 1 -maxdepth 1 -type f -delete'
docker compose --project-directory "$server_dir" cp "$work_dir/attachments/." api:/var/lib/budget-app/attachments/

echo "Restore complete. Restarting the API."
docker compose --project-directory "$server_dir" restart api
echo "Attachment encryption recovery material is inside the encrypted archive. Compare attachment-key-recovery.env with deployment secrets before restart."
