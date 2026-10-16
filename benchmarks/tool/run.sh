#!/usr/bin/env bash
# Runs all benchmarks in JIT and AOT mode and saves the results.
#   tool/run.sh            # everything
#   tool/run.sh json,ffi   # selected groups
#
# AOT: package sqlite3 >= 3 uses build hooks (native assets), which
# `dart compile exe` does not support — we use `dart build cli`, which produces
# the bundle build/cli/<os_arch>/bundle/{bin/run_all,lib/libsqlite3.so}.
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
echo "results: results/jit.md results/aot.md"
