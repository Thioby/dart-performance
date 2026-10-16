// Small C library for the FFI benchmark (isLeaf vs non-leaf, asTypedList).
// Built by tool/build_native.sh: gcc -O2 -shared -fPIC -o native/libfastmath.so native/fastmath.c
#include <stdint.h>
#include <stddef.h>

int64_t add_i64(int64_t a, int64_t b) { return a + b; }

double dot_f64(const double *a, const double *b, int64_t n) {
    double s = 0.0;
    for (int64_t i = 0; i < n; i++) s += a[i] * b[i];
    return s;
}

// Fills the buffer with values; returns the sum (so the result is not dead).
int64_t fill_u8(uint8_t *buf, int64_t n, uint8_t v) {
    int64_t s = 0;
    for (int64_t i = 0; i < n; i++) { buf[i] = (uint8_t)(v + i); s += buf[i]; }
    return s;
}
