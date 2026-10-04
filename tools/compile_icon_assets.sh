#!/usr/bin/env bash
# Optional, pending real actool validation; does not alter/install the app.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
if ! xcrun --find actool >/dev/null 2>&1; then
  printf '%s\n' '缺少actool：需要完整Xcode。源资源已保留；不修改现有应用。' >&2
  exit 2
fi
OUTPUT_DIR="$ROOT_DIR/.staging/icon-assets"
mkdir -p "$OUTPUT_DIR"
xcrun actool "$ROOT_DIR/Assets/Alfred.xcassets" \
  --compile "$OUTPUT_DIR" --platform macosx --minimum-deployment-target 12.0 \
  --app-icon AppIcon --output-partial-info-plist "$OUTPUT_DIR/icon-info.plist"
