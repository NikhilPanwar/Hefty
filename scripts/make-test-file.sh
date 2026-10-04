#!/bin/sh
# Generates a large SQL-dump-like test file without needing much RAM.
# Usage: scripts/make-test-file.sh out.sql 10   (size in GB, default 5)
set -e
OUT=${1:-test.sql}
GB=${2:-5}
TARGET=$((GB * 1024 * 1024 * 1024))
# ~1 MB block of INSERT lines, then append copies until the target size.
BLOCK=$(mktemp)
i=0
while [ $i -lt 9000 ]; do
  echo "INSERT INTO users (id, name, email, created_at) VALUES ($i, 'User $i', 'user$i@example.com', '2024-01-01 00:00:00'); -- row $i"
  i=$((i + 1))
done > "$BLOCK"
: > "$OUT"
while [ "$(stat -f%z "$OUT" 2>/dev/null || stat -c%s "$OUT")" -lt "$TARGET" ]; do
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32; do
    cat "$BLOCK"
  done >> "$OUT"
done
rm -f "$BLOCK"
ls -lh "$OUT"
