#!/bin/bash
set -euo pipefail
OUT="dist/dockyard.sh"
mkdir -p dist
# First file provides the shebang
cat src/00_header.sh > "$OUT"
for f in $(ls src/[0-9]*.sh | sort); do
    [ "$f" = "src/00_header.sh" ] && continue
    # Strip shebang lines from non-header files
    grep -v '^#!' "$f" >> "$OUT"
    printf '\n' >> "$OUT"
done
chmod +x "$OUT"
echo "Built: $OUT ($(wc -l < "$OUT") lines)"
