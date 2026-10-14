#!/usr/bin/env bash
# Uruchamia wszystkie benchmarki w trybie JIT i AOT i zapisuje wyniki.
#   tool/run.sh            # wszystko
#   tool/run.sh json,ffi   # wybrane grupy
#
# AOT: pakiet sqlite3 >= 3 używa build hooks (native assets), których
# `dart compile exe` nie wspiera — używamy `dart build cli`, który tworzy
# bundle build/cli/<os_arch>/bundle/{bin/run_all,lib/libsqlite3.so}.
set -euo pipefail
cd "$(dirname "$0")/.."
ONLY="${1:-}"
ARGS=()
if [[ -n "$ONLY" ]]; then ARGS+=(--only "$ONLY"); fi
[[ -f native/libfastmath.so ]] || bash tool/build_native.sh
mkdir -p build results
echo "### JIT"
dart run bin/run_all.dart "${ARGS[@]}" --json results/jit.json --md results/jit.md
echo
echo "### AOT (dart build cli)"
dart build cli -o build/aot --verbosity=error
AOT_BIN=$(find build/aot -type f -path '*/bin/run_all' | head -1)
"$AOT_BIN" "${ARGS[@]}" --json results/aot.json --md results/aot.md
echo
echo "wyniki: results/jit.md results/aot.md"
