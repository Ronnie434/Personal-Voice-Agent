#!/bin/bash
# Inside-out signing for the spike. Usage:
#   spike/sign.sh "<identity>" <host-entitlements> <python-entitlements> [--timestamp]
set -euo pipefail
cd "$(dirname "$0")/.."
ID=$1; HOST_ENT=$2; PY_ENT=$3; TS=${4:---timestamp=none}
APP=build/spike/Friday.app; RES=$APP/Contents/Resources
find "$APP" -name _CodeSignature -prune -exec rm -rf {} + 2>/dev/null || true
# Every Mach-O that is not a main executable: libraries and extension modules.
find "$RES" -type f \( -name '*.so' -o -name '*.dylib' \) -print0 |
  xargs -0 -n 50 codesign --force --options runtime $TS -s "$ID" 2>&1 | grep -v 'replacing existing' || true
codesign --force --options runtime $TS -s "$ID" --entitlements "$PY_ENT" \
  -i com.ronnie434.Friday.spike.python "$RES/python/bin/python3.12"
codesign --force --options runtime $TS -s "$ID" --entitlements "$HOST_ENT" "$APP"
codesign --verify --deep --strict "$APP" && echo "verify ok"
