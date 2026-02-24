#!/bin/bash
set -euo pipefail
OUT="dist/dockyard.sh"
mkdir -p dist
# First file provides the shebang
cat src/00_header.sh > "$OUT"
for f in $(ls src/[0-9]*.sh | sort); do
    [ "$f" = "src/00_header.sh" ] && continue
    # Strip shebang from first line only (not from heredoc content)
    awk 'NR==1 && /^#!/ {next} {print}' "$f" >> "$OUT"
    printf '\n' >> "$OUT"
done
chmod +x "$OUT"
echo "Built: $OUT ($(wc -l < "$OUT") lines)"
