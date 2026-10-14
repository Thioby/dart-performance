#!/usr/bin/env bash
# Buduje bibliotekę C używaną przez benchmark FFI.
set -euo pipefail
cd "$(dirname "$0")/.."
cc -O2 -shared -fPIC -o native/libfastmath.so native/fastmath.c
echo "built native/libfastmath.so"
