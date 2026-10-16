#!/usr/bin/env bash
# Builds the C library used by the FFI benchmark.
set -euo pipefail
cd "$(dirname "$0")/.."
cc -O2 -shared -fPIC -o native/libfastmath.so native/fastmath.c
echo "built native/libfastmath.so"
