#!/bin/bash
# Print (and optionally write) a SHA-256 checksum for a Brim build artifact.
#
#   ./scripts/checksum-artifact.sh build/Brim.dmg
#   ./scripts/checksum-artifact.sh build/Brim.dmg --write   # -> build/Brim.dmg.sha256
set -euo pipefail

cd "$(dirname "$0")/.."
[[ $# -ge 1 ]] || { echo "usage: $0 <file> [--write]" >&2; exit 2; }
FILE="$1"
[[ -f "$FILE" ]] || { echo "error: missing $FILE" >&2; exit 1; }

# Only the file name goes in the line, so `shasum -c` works next to the downloaded file.
SUM="$(cd "$(dirname "$FILE")" && shasum -a 256 "$(basename "$FILE")")"
echo "$SUM"
if [[ "${2:-}" == "--write" ]]; then
    echo "$SUM" > "${FILE}.sha256"
    echo "Wrote ${FILE}.sha256"
fi
