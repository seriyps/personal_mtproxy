#!/usr/bin/env bash
set -euo pipefail

dets_file=/var/lib/personal_mtproxy/proxies.dets
backup_dir=/var/lib/personal_mtproxy
backup_prefix="$(basename "$dets_file")."
keep_backups=10

if [[ ! -f "$dets_file" ]]; then
  echo "DETS file not found: $dets_file" >&2
  exit 1
fi

timestamp=$(date -u +%Y%m%dT%H%M%SZ)
backup_path="$backup_dir/${backup_prefix}$timestamp.bak"

cp -p -- "$dets_file" "$backup_path"
echo "Created backup: $backup_path"

mapfile -t old_backups < <(
  find "$backup_dir" -maxdepth 1 -type f -name "${backup_prefix}*.bak" -printf '%f\n' |
    sort -r |
    tail -n +$((keep_backups + 1))
)

for backup in "${old_backups[@]}"; do
  rm -f -- "$backup_dir/$backup"
  echo "Removed old backup: $backup_dir/$backup"
done
